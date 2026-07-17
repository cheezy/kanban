defmodule Kanban.Agents do
  @moduledoc """
  Derives AI agent state from existing Task records.

  This is a read-only context. It performs no writes and persists no Agent
  or Event records. All derived data comes from existing fields on
  `Kanban.Tasks.Task` — `created_by_agent`, `completed_by_agent`,
  `claimed_at`, `completed_at`, `reviewed_at`, `inserted_at`,
  `review_status`, `status`, and `time_spent_minutes`.

  This module is the public API and the single source of truth for the scoped
  task fetch and the shared per-task primitives. The derivation concerns are
  split into focused sibling modules, each behind a single-responsibility
  boundary, that delegate the shared task set and counters back here:

    * `Kanban.Agents.Roster` — the agent roster (status, stuck/dormant flags,
      per-agent throughput), incl. the stuck/dormant classification rules.
    * `Kanban.Agents.Events` — the activity-event stream synthesis.
    * `Kanban.Agents.Detail` — the per-agent drill-down.
    * `Kanban.Agents.Metrics` — fleet-level aggregate rollups.

  Each is re-exported through the thin wrappers below, so callers continue to
  use the `Kanban.Agents` public API unchanged.

  ## Options

  All public functions accept a keyword list of opts:

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. When provided, results
      are filtered to tasks on boards the scoped user can access via
      `Kanban.Boards.BoardUser` membership. When `nil` (the default), all
      tasks are considered.
    * `:limit` — for `recent_activity/1`, maximum number of events to
      return. Defaults to `50`. Ignored by the other functions.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Agents.Agent
  alias Kanban.Agents.Detail
  alias Kanban.Agents.Event
  alias Kanban.Agents.Events
  alias Kanban.Agents.Metrics
  alias Kanban.Agents.Roster
  alias Kanban.Columns.Column
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @default_event_limit 50

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

  # Board column names that drive an agent's derived status. A task's
  # `:in_progress` status spans both Doing and Review, so status is inferred
  # from the column name instead. These mirror the default column names seeded
  # in `Kanban.Boards`.
  @doing_column "Doing"
  @review_column "Review"

  @doc """
  Returns the list of agents derived from Task records.

  An agent is any distinct non-nil value of `completed_by_agent` or
  `created_by_agent` across the visible Task set. The returned list is
  ordered by most recent activity, newest first, so agents working right
  now surface at the top of the roster. Most recent activity is the latest
  timestamp across an agent's tasks (claimed, completed, reviewed, or
  created). Ties — including agents whose only activity is task creation —
  break alphabetically by name for a stable order.
  """
  @spec list_agents(keyword()) :: [Agent.t()]
  def list_agents(opts \\ []), do: opts |> fetch_tasks() |> Roster.from_tasks()

  @doc """
  Builds the agent roster from an already-fetched task list.

  Same contract as `list_agents/1` but operates on a caller-supplied task set
  so the Agents view can fetch once and share the result across every metric.
  """
  @spec list_agents_from([Task.t()], String.t()) :: [Agent.t()]
  def list_agents_from(tasks, timezone \\ "Etc/UTC"), do: Roster.from_tasks(tasks, timezone)

  @doc """
  Returns a chronological list of derived activity events.

  Events are synthesized from Task timestamps and returned in descending
  order, capped at the `:limit` option (default `#{@default_event_limit}`).
  """
  @spec recent_activity(keyword()) :: [Event.t()]
  def recent_activity(opts \\ []) do
    recent_activity_from(fetch_tasks(opts), Keyword.get(opts, :limit, @default_event_limit))
  end

  @doc """
  Synthesizes the descending activity-event list from an already-fetched task
  list, capped at `limit`. The cap is applied in Elixir (after sorting), never
  pushed into the DB, so the shared task fetch feeds this without a new query.
  """
  @spec recent_activity_from([Task.t()], non_neg_integer()) :: [Event.t()]
  def recent_activity_from(tasks, limit \\ @default_event_limit),
    do: Events.recent_activity_from(tasks, limit)

  @doc """
  Returns aggregate header counters for the Agents view.

  Delegates to `Kanban.Agents.Metrics.header_stats/1`; see there for the
  returned map shape.
  """
  @spec header_stats(keyword()) :: %{
          created_today: non_neg_integer(),
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats(opts \\ []), do: Metrics.header_stats(opts)

  @doc """
  Header counters computed from an already-fetched task list. Same shape as
  `header_stats/1`; lets the Agents view share one fetch across metrics.

  `timezone` is the viewer's IANA zone — the "today" boundary for the counters
  and the today-scoped cycle time are derived in it (defaulting to `"Etc/UTC"`,
  with a UTC fallback for an unknown zone).
  """
  @spec header_stats_from([Task.t()], String.t()) :: %{
          created_today: non_neg_integer(),
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats_from(tasks, timezone \\ "Etc/UTC"),
    do: Metrics.header_stats_from(tasks, timezone)

  @doc """
  Returns fleet-health rollup counts for the scoped agent set.

  Delegates to `Kanban.Agents.Metrics.fleet_health/1`; see there for the
  returned map shape and the dormant-exclusion rule.
  """
  @spec fleet_health(keyword()) :: %{
          working: non_neg_integer(),
          waiting: non_neg_integer(),
          idle: non_neg_integer(),
          stuck: non_neg_integer()
        }
  def fleet_health(opts \\ []), do: Metrics.fleet_health(opts)

  @doc """
  Fleet-health rollup computed from an already-built agent list. Same shape as
  `fleet_health/1`; the caller supplies the roster so it is built only once.
  """
  @spec fleet_health_from([Agent.t()]) :: %{
          working: non_neg_integer(),
          waiting: non_neg_integer(),
          idle: non_neg_integer(),
          stuck: non_neg_integer()
        }
  def fleet_health_from(agents), do: Metrics.fleet_health_from(agents)

  @doc """
  Returns fleet-wide throughput counts and an overall success rate.

  Delegates to `Kanban.Agents.Metrics.throughput_and_success/1`; see there for
  the returned map shape.
  """
  @spec throughput_and_success(keyword()) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success(opts \\ []), do: Metrics.throughput_and_success(opts)

  @doc """
  Throughput counts and success rate computed from an already-fetched task
  list. Same shape as `throughput_and_success/1`. Pass the viewer's `timezone`
  so `completed_today`/`completed_prev_today` are counted on the local day and
  agree with the header's `completed_today`; omitted, it falls back to UTC.
  """
  @spec throughput_and_success_from([Task.t()], String.t()) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success_from(tasks, timezone \\ "Etc/UTC"),
    do: Metrics.throughput_and_success_from(tasks, timezone)

  @doc """
  Returns a per-day throughput time-series and an aggregate cycle-time metric.

  Delegates to `Kanban.Agents.Metrics.throughput_trends/1`; see there for the
  returned map shape and the `:days` window option.
  """
  @spec throughput_trends(keyword()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends(opts \\ []), do: Metrics.throughput_trends(opts)

  @doc """
  Per-day throughput series and cycle-time metric computed from an
  already-fetched task list over a `days`-day window. Same shape as
  `throughput_trends/1`. Pass the viewer's `timezone` to bucket each day on the
  local calendar (so the most-recent bar agrees with the local "Completed
  today" stat); omitted, it falls back to UTC bucketing.
  """
  @spec throughput_trends_from([Task.t()], integer(), String.t()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends_from(tasks, days \\ Metrics.default_trend_days(), timezone \\ "Etc/UTC"),
    do: Metrics.throughput_trends_from(tasks, days, timezone)

  @doc """
  The default throughput-trends window (in days). Delegates to
  `Kanban.Agents.Metrics.default_trend_days/0` so callers (e.g. the Agents
  LiveView) can request the default window while passing a viewer timezone.
  """
  @spec default_trend_days() :: pos_integer()
  defdelegate default_trend_days(), to: Metrics

  @doc """
  Returns a per-agent drill-down for the named agent, or `nil` if unknown.

  Derived from the single scoped Task fetch (no N+1) for the agent's own tasks
  (those it created or completed). The returned map contains:

    * `:name` — the agent name (echoed back)
    * `:current_task` — the agent's active Doing-column task as
      `%{identifier, title}`, or `nil` when it holds none
    * `:claims` — claim history: the tasks this agent claimed, each
      `%{identifier, title, at}` (the `claimed_at` time), newest first
    * `:failures` — tasks whose review was rejected, each
      `%{identifier, title, at}` (the `reviewed_at` time), newest first
    * `:recent_activity` — the agent's most recent derived `Event`s
      (create/claim/complete/review), newest first
    * `:activity_series` — a `[%{date, count}]` daily-completion series
    * `:outcome` — `%{approved, rejected, in_progress, success_rate}`

  Returns `nil` for an unknown agent (one with no visible tasks). `:scope`
  board filtering is respected via the shared task fetch, so no task outside
  the scoped board set is surfaced.

  Accepts either an agent identity `{name, owner_key}` (W1244 — drills into only
  that human's agent) or a bare `name` string (back-compat — pools every
  same-named agent across humans). The `/agents` view passes the identity tuple.
  """
  @spec agent_detail({String.t(), String.t()} | String.t(), keyword()) ::
          %{
            name: String.t(),
            current_task: %{identifier: String.t(), title: String.t()} | nil,
            claims: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            failures: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            recent_activity: [Event.t()],
            activity_series: [%{date: Date.t(), count: non_neg_integer()}],
            outcome: %{
              approved: non_neg_integer(),
              rejected: non_neg_integer(),
              in_progress: non_neg_integer(),
              success_rate: float()
            }
          }
          | nil
  def agent_detail(name_or_identity, opts \\ []),
    do: opts |> fetch_tasks() |> Detail.from_tasks(name_or_identity)

  @doc """
  Per-agent drill-down derived from an already-fetched task list. Same shape as
  `agent_detail/2` (or `nil` for an unknown agent). The task list is assumed to
  be scope-filtered already, so no scope is re-applied here.

  Accepts an identity `{name, owner_key}` (per-human) or a bare `name` (pooled).
  """
  @spec agent_detail_from([Task.t()], {String.t(), String.t()} | String.t()) ::
          %{
            name: String.t(),
            current_task: %{identifier: String.t(), title: String.t()} | nil,
            claims: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            failures: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            recent_activity: [Event.t()],
            activity_series: [%{date: Date.t(), count: non_neg_integer()}],
            outcome: %{
              approved: non_neg_integer(),
              rejected: non_neg_integer(),
              in_progress: non_neg_integer(),
              success_rate: float()
            }
          }
          | nil
  def agent_detail_from(tasks, name_or_identity),
    do: Detail.from_tasks(tasks, name_or_identity)

  # --- Query -----------------------------------------------------------------

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
  # This path keeps loading real preloaded structs; `fetch_tasks/1` now returns
  # shape-compatible projected maps, and the shared helpers accept both, so the
  # Roster derivation stays identical across the two fetches.
  @spec fetch_target_bridged_tasks(keyword()) :: [Task.t()]
  def fetch_target_bridged_tasks(opts) do
    Task
    |> where([t], t.type != ^:goal)
    |> BoardScope.apply_board_scope_with_column_join(Keyword.get(opts, :scope))
    |> join(:inner, [t], parent in assoc(t, :parent), as: :parent)
    |> where([parent: parent], not is_nil(parent.target_id))
    |> Repo.all()
    |> Repo.preload([:column, :created_by, :completed_by])
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

  # --- Shared identity primitives --------------------------------------------
  # Owner/identity resolution reused by the Roster, Events, and Detail modules,
  # exposed as @doc false so they share one definition of the rules.

  @doc false
  # The stable, non-sensitive identity key for an owner map (or nil): the
  # owning user's id as a string, or the `"none"` sentinel. Also used by the
  # Agents LiveView to key event filtering without leaking the owner's email
  # into the DOM. Keep this the single source of the key rule.
  def owner_key_for_owner(%{id: id}), do: Integer.to_string(id)
  def owner_key_for_owner(_), do: "none"

  @doc false
  # The non-sensitive owner map (id/name/email) for a preloaded user association,
  # or nil when unloaded/absent. Shared by Roster (identity resolution) and
  # Events (event owner).
  def to_owner_map(%User{} = user), do: %{id: user.id, name: user.name, email: user.email}

  # The projected fetch (fetch_tasks/1) already carries the owner as a plain
  # `%{id, name, email}` map for a present owner, or nil for an absent one; keep
  # it idempotent so the shared call sites work identically on both fetch shapes.
  def to_owner_map(%{id: id, name: name, email: email}) when not is_nil(id),
    do: %{id: id, name: name, email: email}

  def to_owner_map(_), do: nil

  @doc false
  # The tasks belonging to a single agent identity: a task contributes when it
  # was created OR completed by this agent name AND the corresponding human
  # owner matches the identity's owner_key. This is the fix that stops two
  # same-named agents under different humans from pooling their tasks. Shared by
  # Roster and Detail.
  def filter_by_identity(tasks, {name, owner_key}) do
    Enum.filter(tasks, fn t ->
      (t.created_by_agent == name and owner_key_for_owner(to_owner_map(t.created_by)) == owner_key) or
        (t.completed_by_agent == name and
           owner_key_for_owner(to_owner_map(t.completed_by)) == owner_key)
    end)
  end

  # --- Shared per-task primitives --------------------------------------------
  # Per-task facts (recency, column/status checks, completion counts, success
  # rate) reused by the Roster, Detail, and Metrics modules.

  @doc false
  # Latest activity timestamp for a task (completed/reviewed/claimed, falling
  # back to inserted_at), as a `NaiveDateTime`. The single recency rule used to
  # order the roster and to classify stuck/dormant agents.
  def task_recency(task) do
    [task.completed_at, task.reviewed_at, task.claimed_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_naive/1)
    |> case do
      [] -> task.inserted_at
      stamps -> Enum.max(stamps, NaiveDateTime)
    end
  end

  defp to_naive(%NaiveDateTime{} = ndt), do: ndt
  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)

  @doc false
  # The current-task pill reflects active work only, so it surfaces a
  # Doing-column task. When an agent has work in both Doing and Review, the
  # Doing task wins; when its only open tasks are in Review, there is no pill.
  # Shared by Roster and Detail.
  def current_task(tasks) do
    case Enum.find(tasks, &doing?/1) do
      nil -> nil
      task -> %{identifier: task.identifier, title: task.title}
    end
  end

  @doc false
  # Whether a task sits in the Doing column (an agent holding one is `:working`).
  # Shared by Roster's status/stuck classification.
  def doing?(task), do: in_column?(task, @doing_column)

  @doc false
  # Whether a task sits in the Review column (an agent whose only open work is
  # here is `:waiting`). Shared by Roster's status/stuck classification.
  def in_review?(task), do: in_column?(task, @review_column)

  defp in_column?(task, column_name) do
    case task.column do
      %{name: ^column_name} -> true
      _ -> false
    end
  end

  @doc false
  # Delegated to `Kanban.Timezone`, the single source of truth for the local
  # day-boundary conversion now shared by the agents and metrics surfaces. Kept
  # here so the existing `Agents.local_today/1` and per-task callers keep one
  # entry point.
  defdelegate local_today(timezone), to: Kanban.Timezone

  @doc false
  defdelegate local_date(dt, timezone), to: Kanban.Timezone

  @doc false
  # Count of tasks completed on `date`, where `date` and each task's completion
  # day are both taken in `timezone` (defaults to UTC for back-compat). Used by
  # the roster's per-agent stats and `Kanban.Agents.Metrics`.
  def count_completed_on_day(tasks, date, timezone \\ "Etc/UTC") do
    Enum.count(tasks, &completed_on?(&1, date, timezone))
  end

  @doc false
  # Count of tasks completed within the trailing `days`-day window ending `today`
  # (inclusive), with the window boundary and each task's completion day taken in
  # `timezone` (defaults to UTC for back-compat). Used by the roster's per-agent
  # stats and `Kanban.Agents.Metrics`.
  def count_completed_within(tasks, today, days, timezone \\ "Etc/UTC") do
    earliest = Date.add(today, -(days - 1))

    Enum.count(tasks, fn task ->
      case task.completed_at do
        nil -> false
        %DateTime{} = dt -> Date.compare(local_date(dt, timezone), earliest) != :lt
      end
    end)
  end

  @doc false
  # Approved over (approved + rejected) across the given tasks, or `0.0` when
  # none have been reviewed. Used by the roster's per-agent success rate, the
  # detail outcome breakdown, and `Kanban.Agents.Metrics`.
  def success_rate(tasks) do
    approved = Enum.count(tasks, &(&1.review_status == :approved))
    rejected = Enum.count(tasks, &(&1.review_status == :rejected))

    case approved + rejected do
      0 -> 0.0
      total -> approved / total
    end
  end

  defp completed_on?(%{completed_at: %DateTime{} = dt}, date, timezone),
    do: local_date(dt, timezone) == date

  defp completed_on?(_task, _date, _timezone), do: false
end
