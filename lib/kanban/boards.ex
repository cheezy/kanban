defmodule Kanban.Boards do
  @moduledoc """
  The Boards context.

  Board membership queries live in `Kanban.Boards.Membership` and are delegated
  to below.
  """

  use Gettext, backend: KanbanWeb.Gettext
  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.Membership
  alias Kanban.Boards.Metrics

  @doc """
  Returns the list of boards for a given user with their access level.

  Each board will have a virtual `:user_access` field containing the user's access level.
  Boards are sorted by access level (owner first, modify second, read_only last),
  then by creation date (most recent first) within each access level.

  ## Examples

      iex> list_boards(user)
      [%Board{user_access: :owner}, ...]

  """
  def list_boards(user) do
    Board
    |> join(:inner, [b], bu in BoardUser, on: bu.board_id == b.id)
    |> where([b, bu], bu.user_id == ^user.id)
    |> select([b, bu], %{b | user_access: bu.access})
    |> Repo.all()
    |> Enum.sort_by(&board_sort_key/1, &board_sort_compare/2)
  end

  @doc """
  Returns `true` when the user has access to at least one board.

  Cheaper than `list_boards/1` when only existence matters (e.g. landing-page
  CTAs that branch on "has any boards yet?").
  """
  def user_has_boards?(%User{id: user_id}) do
    BoardUser
    |> where(user_id: ^user_id)
    |> Repo.exists?()
  end

  def user_has_boards?(_), do: false

  ## Membership

  defdelegate board_counts_by_user(), to: Membership

  defp board_sort_key(board) do
    access_priority =
      case board.user_access do
        :owner -> 0
        :modify -> 1
        :read_only -> 2
      end

    {access_priority, NaiveDateTime.to_erl(board.inserted_at)}
  end

  defp board_sort_compare({priority_a, time_a}, {priority_b, time_b}) do
    if priority_a == priority_b do
      time_a >= time_b
    else
      priority_a < priority_b
    end
  end

  @doc """
  Returns the same list as `list_boards/1` but with each board's virtual
  `:metrics` field populated for the Boards index card.

  Each metrics map contains:

    * `:open` — tasks currently in `Backlog`/`Ready` columns
    * `:doing` — tasks currently in the `Doing` column
    * `:review` — tasks currently in the `Review` column
    * `:done` — tasks currently in the `Done` column
    * `:throughput_14d` — total tasks completed in the last 14 days
    * `:pulse_14d` — exactly 14 daily completion counts, oldest first,
      most recent day LAST, zero-filled for days with no completions
    * `:active_agents_14d` — distinct `completed_by_agent` values on
      tasks completed in the last 14 days. NOTE: the task spec asked for
      distinct `claimed_by_agent`, but no per-claim agent name is stored
      anywhere in the schema (`Task` records only `completed_by_agent`,
      stamped at completion time). `completed_by_agent` on completed
      tasks within the window is the closest available proxy and matches
      the intent of "agents who did work recently."
    * `:last_activity_at` — most recent of `max(claimed_at)` and
      `max(completed_at)` across the board, or `nil` if neither has ever
      been set

  Open/Doing/Review/Done are matched by column NAME (Backlog/Ready map to
  Open; Doing/Review/Done map directly). Columns with other names — on
  non-AI-optimized boards with custom column names — are not counted in
  any bucket; their counts simply do not surface in the metrics map.

  All time windows are anchored in UTC; the optional `:now` keyword
  overrides `DateTime.utc_now/0` for deterministic tests.

  The function issues a fixed number of aggregate queries (one per metric
  family, all grouped by `board_id`) so cost stays constant regardless of
  how many boards the user has access to — no N+1.

  ## Examples

      iex> [%Board{metrics: %{open: 3, doing: 1, ...}} | _] =
      ...>   list_boards_with_metrics(user)

  """
  def list_boards_with_metrics(user, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    boards = list_boards(user)

    case Enum.map(boards, & &1.id) do
      [] ->
        []

      board_ids ->
        metrics_by_board = Metrics.build_metrics(board_ids, now)
        members_by_board = Metrics.members_by_board(board_ids)

        Enum.map(boards, fn board ->
          %{
            board
            | metrics: Map.get(metrics_by_board, board.id, Metrics.empty_metrics(now)),
              members: Map.get(members_by_board, board.id, [])
          }
        end)
    end
  end

  @doc """
  Returns the same `:metrics` map shape as `list_boards_with_metrics/2`
  but for a single board, scope-filtered through `get_board/2` so a user
  cannot read metrics for a board they have no access to.

  Returns `{:ok, metrics_map}` when the user has access and the board
  exists, or `{:error, :not_found}` otherwise.

  ## Examples

      iex> get_board_metrics(user, 42)
      {:ok, %{open: 3, doing: 1, ...}}

      iex> get_board_metrics(user, 999_999)
      {:error, :not_found}

  """
  def get_board_metrics(user, board_id, opts \\ []) do
    case get_board(board_id, user) do
      {:ok, board} ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        metrics_by_board = Metrics.build_metrics([board.id], now)
        {:ok, Map.get(metrics_by_board, board.id, Metrics.empty_metrics(now))}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the workspace-wide task counts, summed across every board the
  user can access:

      %{open: n, doing: n, review: n, done: n}

  The keys and their bucketing rules are exactly those of the per-board
  `:metrics` map from `list_boards_with_metrics/2` — `Backlog`/`Ready`
  roll up to `:open`, archived and goal-type tasks are excluded, and
  columns with custom names are counted in no bucket.

  Scope-filtered through `list_boards/1`, so the sum covers the user's
  owner, modify, AND read-only memberships and nothing else. A user with
  no boards gets the zero map.

  The 14-day metrics are deliberately absent. `:active_agents_14d` cannot
  be summed — an agent working on three boards would count three times;
  use `list_workspace_members/2` and count the `:agent` entries instead.
  `:throughput_14d` and `:pulse_14d` are legitimately summable but no
  caller needs them yet.

  ## Examples

      iex> workspace_metrics(user)
      %{open: 12, doing: 3, review: 1, done: 40}

  """
  def workspace_metrics(user, opts \\ []) do
    user
    |> list_boards_with_metrics(opts)
    |> workspace_metrics_from()
  end

  @doc """
  The pure fold behind `workspace_metrics/2`, for callers that already
  hold the output of `list_boards_with_metrics/2` — the Boards index
  LiveView loads it to render the cards, so rolling it up costs no
  additional queries.

  Boards whose virtual `:metrics` field was never populated (the output of
  `list_boards/1`, where it defaults to `nil`) contribute zeros rather
  than raising.

  This function performs NO scope filtering — it sums whatever it is
  given. Only ever hand it boards from a scoped read, exactly as with
  `Kanban.Agents.list_agents_from/2`.

  ## Examples

      iex> user |> list_boards_with_metrics() |> workspace_metrics_from()
      %{open: 12, doing: 3, review: 1, done: 40}

  """
  def workspace_metrics_from(boards) when is_list(boards) do
    Metrics.workspace_totals(boards)
  end

  @doc """
  Returns every person and agent across the boards the user can access,
  deduplicated, as a list of maps ready to pass straight to
  `KanbanWeb.Avatar.avatar_stack/1`:

      [%{kind: :human | :agent, name: String.t(), palette: String.t()}]

  Human entries additionally carry `:user_id` (see `list_board_members/1`);
  `avatar_stack/1` ignores it.

  Deduplication is by identity, not by appearance: humans collapse on
  `:user_id` so two different people who share a display name both
  survive, and agents collapse on their exact name.

  "Agent" means a distinct, non-blank `completed_by_agent` on a task
  completed within the last 14 days — the same predicate and the same
  window as the per-board `:active_agents_14d`
  count, so the two can never disagree. As noted on
  `list_boards_with_metrics/2`, no per-claim agent identity is stored
  anywhere in the schema, so a completion stamp is the closest available
  proxy. Matching is case-sensitive, mirroring that count's SQL
  `DISTINCT`.

  Ordered humans first, then agents, case-insensitively by name within
  each kind (tie-broken by `:user_id`) so the avatar stack's five-visible
  cap shows people before bots and the order is stable across calls.

  Costs a fixed three queries regardless of how many boards the user has
  — no N+1 — and queries nothing beyond `list_boards/1` when the user has
  no boards. The optional `:now` overrides `DateTime.utc_now/0` for
  deterministic tests. The aggregation itself lives in
  `Kanban.Boards.Metrics.workspace_members/2`; this function owns the
  scoping.

  ## Examples

      iex> list_workspace_members(user)
      [%{kind: :human, name: "ada", palette: "human-blue", user_id: 1},
       %{kind: :agent, name: "Claude", palette: "agent-claude"}]

  """
  def list_workspace_members(user, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case user |> list_boards() |> Enum.map(& &1.id) do
      [] -> []
      board_ids -> Metrics.workspace_members(board_ids, now)
    end
  end

  @doc """
  Returns the human members for a single board, shaped as a list of
  `%{kind: :human, name, palette}` maps ready to pass to
  `KanbanWeb.Avatar.avatar_stack/1`. Mirrors the per-board entry from
  `list_boards_with_metrics/2` so the same component code works on
  single-board pages.

  Returns every member and lets the component handle its five-visible
  truncation.

  Each map also carries `:user_id`, which `avatar_stack/1` ignores. It is
  the identity key `list_workspace_members/2` dedups on: two distinct users
  can share a display name, and `KanbanWeb.AvatarPalette.for_human/1` is
  `rem(id, 4)`, so neither name nor palette identifies a person on its own.
  """
  def list_board_members(board_id) when is_integer(board_id) do
    [board_id]
    |> Metrics.members_by_board()
    |> Map.get(board_id, [])
  end

  @doc """
  Gets a single board with authorization check.

  Returns `{:ok, board}` if found and accessible, `{:error, :not_found}` otherwise.

  For read-only boards (read_only: true), non-members can access the board with user_access: nil.
  For private boards (read_only: false), only members can access.

  ## Examples

      iex> get_board(123, user)
      {:ok, %Board{}}

      iex> get_board(456, user)
      {:error, :not_found}

  """
  def get_board(id, user) when is_integer(id) do
    query =
      Board
      |> join(:left, [b], bu in BoardUser, on: bu.board_id == b.id and bu.user_id == ^user.id)
      |> where([b], b.id == ^id)
      |> select([b, bu], %{b | user_access: bu.access})

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %Board{user_access: nil} = board ->
        if board.read_only, do: {:ok, board}, else: {:error, :not_found}

      board ->
        {:ok, board}
    end
  end

  def get_board(id, user) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_board(int_id, user)
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Same as `get_board/2` but raises `Ecto.NoResultsError` if not found.
  """
  def get_board!(id, user) do
    case get_board(id, user) do
      {:ok, board} -> board
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Board
    end
  end

  @doc """
  Gets the access level for a user on a board.

  Returns the access level atom (:owner, :read_only, :modify) or nil if user has no access.

  ## Examples

      iex> get_user_access(board_id, user_id)
      :owner

  """
  def get_user_access(board_id, user_id) do
    case Repo.get_by(BoardUser, board_id: board_id, user_id: user_id) do
      nil -> nil
      board_user -> board_user.access
    end
  end

  @doc """
  Checks if a user has owner access to a board.

  ## Examples

      iex> owner?(board, user)
      true

  """
  def owner?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) == :owner
  end

  @doc """
  Checks if a user can modify a board (owner or modify access).

  ## Examples

      iex> can_modify?(board, user)
      true

  """
  def can_modify?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) in [:owner, :modify]
  end

  @doc """
  Creates a board for the given user with owner access.

  ## Examples

      iex> create_board(user, %{name: "My Board"})
      {:ok, %Board{}}

      iex> create_board(user, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_board(user, attrs \\ %{}) do
    case run_create_board_transaction(user, attrs) do
      {:ok, board} ->
        :telemetry.execute([:kanban, :board, :creation], %{count: 1}, %{
          board_id: board.id,
          user_id: user.id
        })

        {:ok, board}

      error ->
        error
    end
  end

  defp run_create_board_transaction(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:board, Board.changeset(%Board{}, attrs))
    |> Ecto.Multi.insert(:board_user, fn %{board: board} ->
      owner_board_user_changeset(board, user)
    end)
    |> Repo.transaction()
    |> handle_board_transaction_result()
  end

  defp owner_board_user_changeset(board, user) do
    BoardUser.changeset(%BoardUser{}, %{
      board_id: board.id,
      user_id: user.id,
      access: :owner
    })
  end

  defp handle_board_transaction_result({:ok, %{board: board}}), do: {:ok, board}
  defp handle_board_transaction_result({:error, :board, changeset, _}), do: {:error, changeset}

  defp handle_board_transaction_result({:error, :board_user, changeset, _}),
    do: {:error, changeset}

  @doc """
  Creates an AI-optimized board with default columns: Backlog, Ready, Doing, Review, and Done.
  Sets ai_optimized_board to true.

  ## Examples

      iex> create_ai_optimized_board(user, %{name: "AI Board"})
      {:ok, %Board{}}

  """
  def create_ai_optimized_board(user, attrs \\ %{}) do
    result = create_ai_board_transaction(user, attrs)

    case result do
      {:ok, %{board: board}} ->
        setup_ai_board_columns(board, user)

      {:error, :board, changeset, _} ->
        {:error, changeset}

      {:error, :board_user, changeset, _} ->
        {:error, changeset}
    end
  end

  defp create_ai_board_transaction(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:board, fn _ ->
      %Board{}
      |> Board.changeset(attrs)
      |> Ecto.Changeset.change(ai_optimized_board: true)
    end)
    |> Ecto.Multi.insert(:board_user, fn %{board: board} ->
      BoardUser.changeset(%BoardUser{}, %{
        board_id: board.id,
        user_id: user.id,
        access: :owner
      })
    end)
    |> Repo.transaction()
  end

  defp setup_ai_board_columns(board, user) do
    alias Kanban.Columns

    default_columns = [
      %{name: "Backlog", wip_limit: 0},
      %{name: "Ready", wip_limit: 0},
      %{name: "Doing", wip_limit: 0},
      %{name: "Review", wip_limit: 0},
      %{name: "Done", wip_limit: 0}
    ]

    Enum.each(default_columns, fn column_attrs ->
      Columns.create_column(board, column_attrs, user)
    end)

    :telemetry.execute([:kanban, :board, :creation], %{count: 1}, %{
      board_id: board.id,
      user_id: user.id
    })

    board = Repo.preload(board, :columns, force: true)
    {:ok, board}
  end

  @doc """
  Updates a board.

  ## Examples

      iex> update_board(board, %{name: "New Name"})
      {:ok, %Board{}}

      iex> update_board(board, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_board(%Board{} = board, attrs, user) do
    if owner?(board, user) do
      board
      |> Board.owner_changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a board. Owner-only.

  ## Examples

      iex> delete_board(board, user)
      {:ok, %Board{}}

  """
  def delete_board(%Board{} = board, user) do
    if owner?(board, user) do
      Repo.delete(board)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking board changes.

  ## Examples

      iex> change_board(board)
      %Ecto.Changeset{data: %Board{}}

  """
  def change_board(%Board{} = board, attrs \\ %{}) do
    Board.changeset(board, attrs)
  end

  @doc """
  Adds a user to a board with the specified access level.

  ## Examples

      iex> add_user_to_board(board, user, :read_only)
      {:ok, %BoardUser{}}

  """
  def add_user_to_board(%Board{} = board, user, access, current_user)
      when access in [:owner, :read_only, :modify] do
    if owner?(board, current_user) do
      %BoardUser{}
      |> BoardUser.changeset(%{
        board_id: board.id,
        user_id: user.id,
        access: access
      })
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes a user from a board.

  ## Examples

      iex> remove_user_from_board(board, user)
      {:ok, %BoardUser{}}

  """
  def remove_user_from_board(%Board{} = board, user, current_user) do
    if owner?(board, current_user) do
      case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
        nil ->
          {:error, :not_found}

        board_user ->
          # Revoke the removed user's board-scoped API tokens in the same
          # transaction as the membership delete, so a still-valid token cannot
          # outlive the access it depended on (W1430).
          Ecto.Multi.new()
          |> Ecto.Multi.delete(:board_user, board_user)
          |> Ecto.Multi.run(:revoke_tokens, fn _repo, _changes ->
            {:ok, ApiTokens.revoke_user_tokens_for_board(board.id, user.id)}
          end)
          |> run_board_user_multi()
      end
    else
      {:error, :unauthorized}
    end
  end

  # Runs a BoardUser-mutating multi and normalizes the result back to the
  # {:ok, %BoardUser{}} / {:error, reason} shape callers expect.
  defp run_board_user_multi(multi) do
    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{board_user: board_user}} -> {:ok, board_user}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Updates a user's access level for a board.

  ## Examples

      iex> update_user_access(board, user, :modify)
      {:ok, %BoardUser{}}

  """
  def update_user_access(%Board{} = board, user, new_access, current_user)
      when new_access in [:owner, :read_only, :modify] do
    if owner?(board, current_user) do
      case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
        nil ->
          {:error, :not_found}

        board_user ->
          # Downgrading to :read_only revokes the user's board-scoped API tokens
          # in the same transaction, so a token minted while they held :modify
          # can no longer write to the board (W1430). Upgrades/lateral changes
          # leave tokens intact.
          Ecto.Multi.new()
          |> Ecto.Multi.update(
            :board_user,
            BoardUser.changeset(board_user, %{access: new_access})
          )
          |> maybe_revoke_tokens_on_downgrade(board.id, user.id, new_access)
          |> run_board_user_multi()
      end
    else
      {:error, :unauthorized}
    end
  end

  defp maybe_revoke_tokens_on_downgrade(multi, board_id, user_id, :read_only) do
    Ecto.Multi.run(multi, :revoke_tokens, fn _repo, _changes ->
      {:ok, ApiTokens.revoke_user_tokens_for_board(board_id, user_id)}
    end)
  end

  defp maybe_revoke_tokens_on_downgrade(multi, _board_id, _user_id, _access), do: multi

  @doc """
  Lists all users associated with a board along with their access level.

  Users are sorted by access level (owner first, then modify, then read_only),
  and then alphabetically by email within each access level.

  ## Examples

      iex> list_board_users(board)
      [%{user: %User{}, access: :owner}, ...]

  """
  def list_board_users(%Board{id: board_id}) do
    BoardUser
    |> where([bu], bu.board_id == ^board_id)
    |> join(:inner, [bu], u in assoc(bu, :user))
    |> select([bu, u], %{user: u, access: bu.access})
    |> Repo.all()
    |> Enum.sort_by(fn %{user: user, access: access} ->
      access_priority =
        case access do
          :owner -> 0
          :modify -> 1
          :read_only -> 2
        end

      {access_priority, user.email}
    end)
  end

  @doc """
  Updates field visibility settings for a board.
  Only board owners can update field visibility.
  Broadcasts changes to all connected clients.

  ## Examples

      iex> update_field_visibility(board, %{"complexity" => true}, user)
      {:ok, %Board{}}

      iex> update_field_visibility(board, %{"complexity" => true}, non_owner_user)
      {:error, :unauthorized}

  """
  def update_field_visibility(%Board{} = board, field_visibility, user) do
    if owner?(board, user) do
      board
      |> Board.changeset(%{field_visibility: field_visibility})
      |> Repo.update()
      |> case do
        {:ok, updated_board} ->
          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{board.id}",
            {:field_visibility_updated, updated_board.field_visibility}
          )

          {:ok, updated_board}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end
end
