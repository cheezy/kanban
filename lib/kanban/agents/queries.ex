defmodule Kanban.Agents.Queries do
  @moduledoc """
  The scoped task fetch and projection behind `Kanban.Agents`. Extracted from
  `Kanban.Agents` (W1738) to keep that context under the module-size guideline.

  This module owns the two board-scoped, goal-excluded projected reads —
  `fetch_tasks/1` (the shared roster/events/header set) and
  `fetch_target_bridged_tasks/1` (the delivery-rollup bridge set) — along with
  the window/cap/board query helpers and the in-memory window twins the Agents
  LiveView uses to derive subsets from a single wider fetch (W1734).

  `Kanban.Agents` re-exports these via thin delegates, so callers keep using the
  `Kanban.Agents` public API unchanged. Both fetches return lightweight projected
  maps (never `%Task{}` structs); see `fetch_tasks/1` for the projection contract
  the derivation modules and shared helpers consume.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  # Hard ceiling on the roster/events/header task fetch. Even the `:all_time`
  # window (a no-op time filter) is bounded to this many most-recently-updated
  # rows so the /agents load can never issue an unbounded full-history
  # `Repo.all` (the D122 statement-timeout failure mode, which D122 fixed only
  # for the DeliveryRollup path — not this roster fetch). 5000 is generous
  # enough that no realistic single-workspace live/today aggregate is truncated
  # (the roster's dormant-agent tail is already collapsed into a separate
  # group), while keeping the ordered index scan bounded well under the DB
  # statement timeout. Overridable via the `:max_tasks` opt (used by tests to
  # exercise the cap without seeding thousands of rows).
  @default_task_cap 5000

  # Trailing-window lengths (days back from "today", inclusive) for the optional
  # time-range filter. Mirrors `Kanban.Metrics`' board time-range options so the
  # /agents days selector and the metrics board share the same window semantics.
  @time_range_days %{today: 0, last_7_days: 6, last_30_days: 29, last_90_days: 89}

  @doc false
  # Exposed (not part of the documented API) so the derivation sibling modules
  # share the single scoped task fetch. Returns the visible, goal-excluded task
  # set as lightweight projected maps — NOT `%Task{}` structs — carrying only the
  # small scalar fields the derivation modules read, plus a nested `column` map
  # and `created_by`/`completed_by` as an owner map (or nil), resolved via joins
  # in the one query rather than `Repo.preload`. The heavy JSONB/text columns
  # (changed_files, review_report, explorer_result, description, ...) are never
  # transferred. The reshaped maps are shape-compatible with the preloaded
  # structs `fetch_target_bridged_tasks/1` still returns, so every shared helper
  # and derivation module consumes both without change.
  #
  # Options:
  #   * `:scope`      - `Kanban.Accounts.Scope` for board-membership scoping (as before)
  #   * `:board_id`   - integer board id to restrict the fetch to one board, or
  #                     `nil` (default) for every board the scope allows
  #   * `:time_range` - one of `:today`, `:last_7_days`, `:last_30_days`,
  #                     `:last_90_days`, `:all_time`/`nil` (default) for no window
  #   * `:window_days` - a fixed trailing window in days that takes precedence over
  #                     `:time_range`; for callers (e.g. the Agents throughput
  #                     cards) that need a board-scoped set independent of the page
  #                     time-range selector. Still bounded, so it never reintroduces
  #                     an unbounded per-render fetch.
  #   * `:timezone`   - IANA zone used to anchor the time window (default "Etc/UTC")
  def fetch_tasks(opts) do
    Task
    |> where([t], t.type != ^:goal)
    # One unconditional column join under the :column binding (the scope filter
    # below reuses it via apply_board_scope/2), plus a left join per owner
    # association, so the column name and both owners resolve in this SINGLE
    # query — no Repo.preload and no per-association batch. The select carries
    # only the small scalar fields the derivation modules read.
    |> join(:inner, [t], c in assoc(t, :column), as: :column)
    |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
    |> join(:left, [t], cb in assoc(t, :created_by), as: :created_by)
    |> join(:left, [t], cpb in assoc(t, :completed_by), as: :completed_by)
    |> filter_by_board(Keyword.get(opts, :board_id))
    |> apply_window(opts)
    |> apply_cap(opts)
    |> select([t, column: c, created_by: cb, completed_by: cpb], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      type: t.type,
      status: t.status,
      parent_id: t.parent_id,
      claimed_at: t.claimed_at,
      claim_expires_at: t.claim_expires_at,
      completed_at: t.completed_at,
      reviewed_at: t.reviewed_at,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at,
      created_by_agent: t.created_by_agent,
      completed_by_agent: t.completed_by_agent,
      review_status: t.review_status,
      needs_review: t.needs_review,
      time_spent_minutes: t.time_spent_minutes,
      column_name: c.name,
      created_by_id: cb.id,
      created_by_name: cb.name,
      created_by_email: cb.email,
      completed_by_id: cpb.id,
      completed_by_name: cpb.name,
      completed_by_email: cpb.email
    })
    |> Repo.all()
    |> Enum.map(&reshape_fetched_task/1)
  end

  # Reshapes a projected row back into the struct-like shape the derivation
  # modules and shared helpers already consume: a nested `column` map (matched by
  # in_column?/2) and `created_by`/`completed_by` as an owner map or genuine nil,
  # so to_owner_map/1 and the `completed_by || created_by` fallback in Events keep
  # working. Reconstructing nil for an absent owner is why the projection selects
  # flat owner fields rather than a nested map — a left-joined nested map yields
  # an all-nil map, not nil, which would defeat that `||` fallback.
  defp reshape_fetched_task(row) do
    row
    |> Map.put(:column, %{name: row.column_name})
    |> Map.put(
      :created_by,
      owner_or_nil(row.created_by_id, row.created_by_name, row.created_by_email)
    )
    |> Map.put(
      :completed_by,
      owner_or_nil(row.completed_by_id, row.completed_by_name, row.completed_by_email)
    )
    |> Map.drop([
      :column_name,
      :created_by_id,
      :created_by_name,
      :created_by_email,
      :completed_by_id,
      :completed_by_name,
      :completed_by_email
    ])
  end

  defp owner_or_nil(nil, _name, _email), do: nil
  defp owner_or_nil(id, name, email), do: %{id: id, name: name, email: email}

  @doc false
  # The board-scoped, goal-excluded task set restricted to tasks whose parent
  # goal is assigned to a delivery target — the minimal set the
  # `Kanban.Targets.DeliveryRollup` bridge (agent -> parent goal -> target)
  # needs.
  #
  # Why this exists (D122): `fetch_tasks/1` with no window fetches the ENTIRE
  # board-scoped task history (the `:all_time` no-op branch of `apply_window`).
  # At production row counts that unbounded full-history scan exceeded the
  # database `statement_timeout` and crashed the /agents load from
  # `DeliveryRollup.fetch_bridged_tasks/1`. The rollup never needs history that
  # cannot reach a target, so this bounds the fetch by RELEVANCE rather than by
  # time: every task that can contribute a `{goal_id, target_id}` bridge pair
  # has a parent goal with a non-nil `target_id`, and this returns exactly that
  # set. Nothing the bridge or stall attribution needs is dropped, regardless of
  # how old a task is — unlike a trailing time window, which would silently drop
  # long-dormant-but-still-attributed agents. Agents whose work never reaches a
  # target are intentionally excluded (see `DeliveryRollup`'s moduledoc).
  #
  # Board scoping only needs to filter the child task: a parent goal shares its
  # children's board, so a board-scoped child set implies accessible parents.
  # Like `fetch_tasks/1` (W1733) this projects into lightweight maps rather than
  # loading full `%Task{}` structs and preloading four associations — the parent
  # goal, both owner users, and the column are all joined and projected in the
  # SINGLE query. The reshaped maps carry the same fields as `fetch_tasks/1` plus
  # a `parent: %{id, target_id}` map — the only two goal fields `DeliveryRollup`'s
  # bridge reads (W1735). The heavy JSONB/text columns of both the task and its
  # parent goal are never transferred.
  def fetch_target_bridged_tasks(opts) do
    Task
    |> where([t], t.type != ^:goal)
    |> join(:inner, [t], c in assoc(t, :column), as: :column)
    |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
    |> join(:inner, [t], parent in assoc(t, :parent), as: :parent)
    |> where([parent: parent], not is_nil(parent.target_id))
    |> join(:left, [t], cb in assoc(t, :created_by), as: :created_by)
    |> join(:left, [t], cpb in assoc(t, :completed_by), as: :completed_by)
    |> select([t, column: c, parent: p, created_by: cb, completed_by: cpb], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      type: t.type,
      status: t.status,
      parent_id: t.parent_id,
      claimed_at: t.claimed_at,
      claim_expires_at: t.claim_expires_at,
      completed_at: t.completed_at,
      reviewed_at: t.reviewed_at,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at,
      created_by_agent: t.created_by_agent,
      completed_by_agent: t.completed_by_agent,
      review_status: t.review_status,
      needs_review: t.needs_review,
      time_spent_minutes: t.time_spent_minutes,
      column_name: c.name,
      created_by_id: cb.id,
      created_by_name: cb.name,
      created_by_email: cb.email,
      completed_by_id: cpb.id,
      completed_by_name: cpb.name,
      completed_by_email: cpb.email,
      parent_goal_id: p.id,
      parent_target_id: p.target_id
    })
    |> Repo.all()
    |> Enum.map(&reshape_bridged_task/1)
  end

  # Reshapes a projected bridged-task row: the same struct-like shape as
  # reshape_fetched_task/1 (nested column + owner-map-or-nil) plus a nested
  # `parent: %{id, target_id}` — the two goal fields DeliveryRollup's task_bridge/1
  # reads. The parent target_id is never nil here (the query filters on it).
  defp reshape_bridged_task(row) do
    row
    |> reshape_fetched_task()
    |> Map.put(:parent, %{id: row.parent_goal_id, target_id: row.parent_target_id})
    |> Map.drop([:parent_goal_id, :parent_target_id])
  end

  # Restrict to one board via a column-id subquery. Referencing only the Task
  # binding keeps this composable with BoardScope's joins regardless of their
  # positions; when scope is present a board the user cannot access intersects
  # to the empty set, so no cross-tenant tasks leak.
  defp filter_by_board(query, board_id) when is_integer(board_id) do
    board_columns = from(c in Column, where: c.board_id == ^board_id, select: c.id)
    where(query, [t], t.column_id in subquery(board_columns))
  end

  defp filter_by_board(query, _board_id), do: query

  # Bound the fetch to at most `:max_tasks` (default `@default_task_cap`) rows,
  # ordered by `updated_at` descending so the most-recent activity is always
  # retained. This applies on EVERY path — including the `:all_time`/`nil`
  # window that is otherwise a no-op — so the roster fetch can never scan the
  # entire board history. Ordering by `updated_at` keeps the cap
  # activity-relevant (dropping only the oldest dormant tail) and is served by
  # the `tasks(updated_at)` index. Consumers (`Roster`, `Events`, `Metrics`)
  # re-sort in Elixir, so the DB ordering does not constrain their output shape.
  defp apply_cap(query, opts) do
    cap = Keyword.get(opts, :max_tasks, @default_task_cap)

    query
    |> order_by([t], desc: t.updated_at)
    |> limit(^cap)
  end

  # Apply the trailing-window filter. A fixed `:window_days` takes precedence over
  # the page `:time_range` selector so selector-independent callers (the Agents
  # throughput cards) get a stable, bounded window; absent it, fall back to the
  # selector-driven `:time_range` filter.
  defp apply_window(query, opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case Keyword.get(opts, :window_days) do
      days when is_integer(days) and days >= 0 ->
        filter_by_fixed_window(query, days, timezone)

      _ ->
        filter_by_time_range(query, Keyword.get(opts, :time_range), timezone)
    end
  end

  # Bound the fetch to tasks last touched within the trailing window. `updated_at`
  # is the activity proxy (claim/complete/review all bump it); `:all_time`/`nil`
  # is a true no-op that preserves the historic unbounded behavior.
  defp filter_by_time_range(query, range, _timezone) when range in [nil, :all_time], do: query

  defp filter_by_time_range(query, range, timezone) do
    days_back = Map.get(@time_range_days, range, 29)
    where(query, [t], t.updated_at >= ^window_start_naive(days_back, timezone))
  end

  # A fixed `days_back`-day trailing window, anchored to the local day the same way
  # as the `:time_range` filter, so the two paths share identical boundary math.
  defp filter_by_fixed_window(query, days_back, timezone) do
    where(query, [t], t.updated_at >= ^window_start_naive(days_back, timezone))
  end

  @doc false
  # The local-day start of a `days_back`-day trailing window as a `NaiveDateTime`,
  # to compare against the naive `updated_at` column. Public (@doc false) so the
  # in-memory window filters below and the LiveView derive their boundary from the
  # SAME computation the query path uses — the two can never drift (W1734).
  def window_start_naive(days_back, timezone) do
    timezone
    |> Timezone.local_today()
    |> Date.add(-days_back)
    |> Timezone.start_of_local_day(timezone)
    |> DateTime.to_naive()
  end

  @doc false
  # The trailing-window length (days back from local "today") for a selector time
  # range, or nil for the unbounded `:all_time`/`nil` selector. Lets a caller
  # compare the selector window against a fixed window to pick the wider one
  # before fetching (W1734).
  def time_range_days_back(range) when range in [nil, :all_time], do: nil
  def time_range_days_back(range), do: Map.get(@time_range_days, range, 29)

  @doc false
  # In-memory twin of the query-side `filter_by_fixed_window`: keeps the tasks
  # whose `updated_at` falls within the trailing `days_back`-day window, using the
  # exact same local-day boundary. Used to derive the fixed-window (throughput)
  # subset from a wider single fetch (W1734).
  def within_fixed_window(tasks, days_back, timezone) do
    boundary = window_start_naive(days_back, timezone)
    Enum.filter(tasks, &updated_on_or_after?(&1, boundary))
  end

  @doc false
  # In-memory twin of the query-side `filter_by_time_range`: keeps the tasks
  # within the selector window; `:all_time`/`nil` is a no-op (keeps everything),
  # matching the query path. Used to derive the selector subset from a wider
  # single fetch (W1734).
  def within_time_range(tasks, range, _timezone) when range in [nil, :all_time], do: tasks

  def within_time_range(tasks, range, timezone) do
    within_fixed_window(tasks, Map.get(@time_range_days, range, 29), timezone)
  end

  defp updated_on_or_after?(%{updated_at: %NaiveDateTime{} = at}, boundary),
    do: NaiveDateTime.compare(at, boundary) != :lt

  defp updated_on_or_after?(_, _), do: false
end
