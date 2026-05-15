defmodule Kanban.Boards do
  @moduledoc """
  The Boards context.
  """

  use Gettext, backend: KanbanWeb.Gettext
  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Tasks.Task

  @pulse_window_days 14
  @open_columns ~w(Backlog Ready)
  @doing_column "Doing"
  @review_column "Review"
  @done_column "Done"
  @human_palettes ~w(human-blue human-amber human-green human-pink)

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
        metrics_by_board = build_metrics(board_ids, now)
        members_by_board = members_by_board(board_ids)

        Enum.map(boards, fn board ->
          %{
            board
            | metrics: Map.get(metrics_by_board, board.id, empty_metrics(now)),
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
        metrics_by_board = build_metrics([board.id], now)
        {:ok, Map.get(metrics_by_board, board.id, empty_metrics(now))}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Returns %{board_id => [%{kind: :human, name: string, palette: string}]}
  # built from the users on each board's `board_users` join. Used to render
  # the avatar stack in the Boards index pulse card. The Avatar component
  # accepts at most 5 visible avatars before showing a +N overflow chip,
  # so this query intentionally returns all members and the component
  # handles truncation.
  defp members_by_board(board_ids) do
    BoardUser
    |> join(:inner, [bu], u in User, on: u.id == bu.user_id)
    |> where([bu], bu.board_id in ^board_ids)
    |> select([bu, u], {bu.board_id, u.id, u.name, u.email})
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      {board_id, user_id, name, email} = row

      member = %{
        kind: :human,
        name: member_display_name(name, email),
        palette: human_palette(user_id)
      }

      Map.update(acc, board_id, [member], &(&1 ++ [member]))
    end)
  end

  defp member_display_name(name, email) when is_binary(name) do
    case String.trim(name) do
      "" -> email_local_part(email)
      trimmed -> trimmed
    end
  end

  defp member_display_name(_name, email), do: email_local_part(email)

  defp email_local_part(email) when is_binary(email) do
    email |> String.split("@", parts: 2) |> List.first()
  end

  defp email_local_part(_), do: "?"

  defp human_palette(user_id) when is_integer(user_id) do
    Enum.at(@human_palettes, rem(user_id, length(@human_palettes)))
  end

  defp build_metrics(board_ids, now) do
    today = DateTime.to_date(now)
    cutoff_dt = today |> Date.add(-(@pulse_window_days - 1)) |> DateTime.new!(~T[00:00:00])

    aggregates = %{
      column_counts: column_counts_by_board(board_ids),
      pulse_rows: pulse_rows_by_board(board_ids, cutoff_dt),
      throughput: throughput_by_board(board_ids, cutoff_dt),
      active_agents: active_agents_by_board(board_ids, cutoff_dt),
      last_activity: last_activity_by_board(board_ids),
      pulse_dates: pulse_date_range(today)
    }

    Map.new(board_ids, &{&1, metrics_for_board(&1, aggregates)})
  end

  defp metrics_for_board(board_id, agg) do
    %{
      open: Map.get(agg.column_counts, {board_id, :open}, 0),
      doing: Map.get(agg.column_counts, {board_id, :doing}, 0),
      review: Map.get(agg.column_counts, {board_id, :review}, 0),
      done: Map.get(agg.column_counts, {board_id, :done}, 0),
      throughput_14d: Map.get(agg.throughput, board_id, 0),
      pulse_14d: build_pulse_array(Map.get(agg.pulse_rows, board_id, %{}), agg.pulse_dates),
      active_agents_14d: Map.get(agg.active_agents, board_id, 0),
      last_activity_at: Map.get(agg.last_activity, board_id)
    }
  end

  defp empty_metrics(now) do
    %{
      open: 0,
      doing: 0,
      review: 0,
      done: 0,
      throughput_14d: 0,
      pulse_14d: zero_pulse(now),
      active_agents_14d: 0,
      last_activity_at: nil
    }
  end

  defp zero_pulse(now) do
    now |> DateTime.to_date() |> pulse_date_range() |> Enum.map(fn _ -> 0 end)
  end

  defp pulse_date_range(today) do
    today
    |> Date.add(-(@pulse_window_days - 1))
    |> Date.range(today)
    |> Enum.to_list()
  end

  defp build_pulse_array(counts_by_date, pulse_dates) do
    Enum.map(pulse_dates, fn date -> Map.get(counts_by_date, date, 0) end)
  end

  # Returns %{{board_id, :open | :doing | :review | :done} => count}.
  # Archived tasks (those with a non-nil `archived_at`) and goal-type tasks
  # are excluded so the board card stats reflect actionable work only.
  defp column_counts_by_board(board_ids) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t, _c], is_nil(t.archived_at))
    |> where([t, _c], t.type != :goal)
    |> where(
      [_t, c],
      c.name in ^@open_columns or c.name in [@doing_column, @review_column, @done_column]
    )
    |> group_by([_t, c], [c.board_id, c.name])
    |> select([_t, c], {c.board_id, c.name, count()})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, name, count}, acc ->
      # Backlog and Ready both bucket to :open, so accumulate when two
      # column names roll up to the same bucket on the same board.
      Map.update(acc, {board_id, bucket_for(name)}, count, &(&1 + count))
    end)
  end

  defp bucket_for(name) when name in @open_columns, do: :open
  defp bucket_for(@doing_column), do: :doing
  defp bucket_for(@review_column), do: :review
  defp bucket_for(@done_column), do: :done

  # Returns %{board_id => %{Date => count}}.
  defp pulse_rows_by_board(board_ids, cutoff_dt) do
    board_ids
    |> pulse_query(cutoff_dt)
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, date, count}, acc ->
      Map.update(acc, board_id, %{date => count}, &Map.put(&1, date, count))
    end)
  end

  defp pulse_query(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
    |> group_by([t, c], [c.board_id, fragment("DATE(?)", t.completed_at)])
    |> select([t, c], {c.board_id, fragment("DATE(?)", t.completed_at), count(t.id)})
  end

  # Returns %{board_id => total_count}.
  defp throughput_by_board(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Returns %{board_id => distinct_agent_count}.
  defp active_agents_by_board(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_by_agent))
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, count(t.completed_by_agent, :distinct)})
    |> Repo.all()
    |> Map.new()
  end

  # Returns %{board_id => DateTime}. Picks the later of max(claimed_at)
  # and max(completed_at). Boards with neither timestamp anywhere are
  # absent from the map; the caller defaults them to nil.
  defp last_activity_by_board(board_ids) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, max(t.claimed_at), max(t.completed_at)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, max_claimed, max_completed}, acc ->
      case latest(max_claimed, max_completed) do
        nil -> acc
        dt -> Map.put(acc, board_id, dt)
      end
    end)
  end

  defp latest(nil, nil), do: nil
  defp latest(nil, dt), do: dt
  defp latest(dt, nil), do: dt
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

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
      Columns.create_column(board, column_attrs)
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
        nil -> {:error, :not_found}
        board_user -> Repo.delete(board_user)
      end
    else
      {:error, :unauthorized}
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
          board_user
          |> BoardUser.changeset(%{access: new_access})
          |> Repo.update()
      end
    else
      {:error, :unauthorized}
    end
  end

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
