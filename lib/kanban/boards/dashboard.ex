defmodule Kanban.Boards.Dashboard do
  @moduledoc """
  Scoped metrics reads for the Boards index cards, the single-board header and
  the all-boards rollups.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.list_boards_with_metrics/2`, `Boards.get_board_metrics/3` and so on
  rather than reaching into this module directly.

  This module owns the scoping. `list_boards_with_metrics/2`,
  `get_board_metrics/3`, `workspace_metrics/2` and `list_workspace_members/2`
  first resolve the caller's boards through `Kanban.Boards.list_boards/1` or
  `Kanban.Boards.get_board/2`, and only then hand the already-scoped board ids
  to `Kanban.Boards.Metrics` for the aggregation.

  Two functions do no scoping of their own and rely on their caller:
  `list_board_members/1` must only be given a board id the caller already
  obtained through a scoped read, and `workspace_metrics_from/1` sums whatever
  boards it is handed.

  Split out of `Kanban.Boards` per the module design guidance in `AGENTS.md`.
  """

  alias Kanban.Boards
  alias Kanban.Boards.Metrics

  @doc """
  Returns the same list as `Kanban.Boards.list_boards/1` but with each board's virtual
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
    boards = Boards.list_boards(user)

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
  but for a single board, scope-filtered through `Kanban.Boards.get_board/2` so a user
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
    case Boards.get_board(board_id, user) do
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

  Scope-filtered through `Kanban.Boards.list_boards/1`, so the sum covers the user's
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
  `Kanban.Boards.list_boards/1`, where it defaults to `nil`) contribute zeros rather
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
  — no N+1 — and queries nothing beyond `Kanban.Boards.list_boards/1` when the user has
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

    case user |> Boards.list_boards() |> Enum.map(& &1.id) do
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
  Returns the members of a single board who may be newly assigned a task:
  `list_board_members/1` without the members whose account is disabled.

  A disabled account keeps its `board_users` row (so it still shows on the
  board's avatar stack and in the assignee filter, where it may still own
  tasks), but `Kanban.Tasks.Assignees` refuses it as a new assignee. Selects
  that offer assignees, such as the board's bulk-action bar, use this list so
  they never offer a choice the server refuses (D385). The disabled state is
  read from the database on every call.
  """
  def list_assignable_board_members(board_id) when is_integer(board_id) do
    [board_id]
    |> Metrics.members_by_board(enabled_only: true)
    |> Map.get(board_id, [])
  end
end
