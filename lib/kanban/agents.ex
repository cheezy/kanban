defmodule Kanban.Agents do
  @moduledoc """
  Derives AI agent state from existing Task records.

  This is a read-only context. It performs no writes and persists no Agent
  or Event records. All derived data comes from existing fields on
  `Kanban.Tasks.Task` — `created_by_agent`, `completed_by_agent`,
  `claimed_at`, `completed_at`, `reviewed_at`, `inserted_at`,
  `review_status`, `status`, and `time_spent_minutes`.

  ## Options

  All public functions accept a keyword list of opts:

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. When provided, results
      are filtered to tasks on boards the scoped user can access via
      `Kanban.Boards.BoardUser` membership. When `nil` (the default), all
      tasks are considered.
    * `:limit` — for `recent_activity/1`, maximum number of events to
      return. Defaults to `50`. Ignored by the other functions.

  ## Stuck agents

  An agent is classified as **stuck** when it holds an active task (sitting
  in the Doing or Review column) whose most recent activity is older than
  `@stuck_threshold_minutes` (60 minutes) — that is, it has stalled mid-work
  or has been sitting in review past the threshold.
  Stuck-ness is derived purely from existing Task timestamps (the same
  `task_recency/1` rule used to order the roster) with no schema change, and
  is reported as the independent boolean `Agent.stuck` field, orthogonal to
  `:working` / `:waiting` / `:idle`. The threshold mirrors the 60-minute
  claim-expiry window: a task still held past it is a strong stuck signal.

  ## Dormant agents

  An agent is classified as **dormant** when its most recent activity
  (`Agent.last_active_at`, the same `task_recency/1` rule used to order the
  roster) is older than `@dormant_threshold_days` (14 days). Dormant agents
  remain in `list_agents/1` — flagged via the `Agent.dormant` boolean and
  carrying `last_active_at` — so the UI can surface them separately, but they
  are **excluded from the `fleet_health/1` rollup** so its counts reflect only
  live agents and a long tail of weeks-idle agents does not inflate the idle
  bucket. Derived purely from existing Task timestamps; no schema change.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Agents.Agent
  alias Kanban.Agents.Event
  alias Kanban.Agents.Metrics
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @default_event_limit 50

  # Maximum number of derived events surfaced in a single agent's drill-down
  # (`agent_detail/2`), newest first.
  @agent_detail_activity_limit 20

  # Sentinel recency for an agent with no tasks at all, so it sorts to the
  # bottom of the roster. Agents that have tasks always derive a real
  # timestamp from `task_recency/1` (which falls back to `inserted_at`).
  @epoch_recency ~N[0000-01-01 00:00:00]

  # Board column names that drive an agent's derived status. A task's
  # `:in_progress` status spans both Doing and Review, so status is inferred
  # from the column name instead. These mirror the default column names seeded
  # in `Kanban.Boards`.
  @doing_column "Doing"
  @review_column "Review"

  # An agent holding an active (Doing/Review) task whose most recent activity
  # is older than this many minutes is classified as stuck. Mirrors the
  # 60-minute claim-expiry window — a task still held past it has stalled or
  # is sitting in review too long. See the "Stuck agents" moduledoc section.
  @stuck_threshold_minutes 60

  # An agent whose most recent activity is older than this many days is
  # classified as dormant. Dormant agents stay in `list_agents/1` (so the UI
  # can surface them separately) but are excluded from the `fleet_health/1`
  # rollup so its counts reflect only live agents. See the "Dormant agents"
  # moduledoc section.
  @dormant_threshold_days 14

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
  def list_agents(opts \\ []), do: list_agents_from(fetch_tasks(opts))

  @doc """
  Builds the agent roster from an already-fetched task list.

  Same contract as `list_agents/1` but operates on a caller-supplied task set
  so the Agents view can fetch once and share the result across every metric.
  """
  @spec list_agents_from([Task.t()]) :: [Agent.t()]
  def list_agents_from(tasks) do
    today = Date.utc_today()

    # Sort by identity first (name, then owner_key), then stable-sort by recency
    # descending: because `Enum.sort_by/3` is stable, identities with equal
    # recency keep the name/owner-ascending order as a deterministic tiebreak.
    tasks
    |> distinct_agent_identities()
    |> Enum.sort()
    |> Enum.sort_by(&agent_recency(&1, tasks), {:desc, NaiveDateTime})
    |> Enum.map(&build_agent(&1, tasks, today))
  end

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
  def recent_activity_from(tasks, limit \\ @default_event_limit) do
    tasks
    |> Enum.flat_map(&events_for/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Returns aggregate header counters for the Agents view.

  Delegates to `Kanban.Agents.Metrics.header_stats/1`; see there for the
  returned map shape.
  """
  @spec header_stats(keyword()) :: %{
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats(opts \\ []), do: Metrics.header_stats(opts)

  @doc """
  Header counters computed from an already-fetched task list. Same shape as
  `header_stats/1`; lets the Agents view share one fetch across metrics.
  """
  @spec header_stats_from([Task.t()]) :: %{
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats_from(tasks), do: Metrics.header_stats_from(tasks)

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
  list. Same shape as `throughput_and_success/1`.
  """
  @spec throughput_and_success_from([Task.t()]) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success_from(tasks), do: Metrics.throughput_and_success_from(tasks)

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
  `throughput_trends/1`.
  """
  @spec throughput_trends_from([Task.t()], integer()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends_from(tasks, days \\ Metrics.default_trend_days()),
    do: Metrics.throughput_trends_from(tasks, days)

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
    * `:recent_activity` — up to #{@agent_detail_activity_limit} of the
      agent's derived `Event`s (create/claim/complete/review), newest first

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
            recent_activity: [Event.t()]
          }
          | nil
  def agent_detail(name_or_identity, opts \\ []),
    do: agent_detail_from(fetch_tasks(opts), name_or_identity)

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
            recent_activity: [Event.t()]
          }
          | nil
  def agent_detail_from(tasks, {name, _owner_key} = identity),
    do: build_detail(filter_by_identity(tasks, identity), name)

  def agent_detail_from(tasks, name) when is_binary(name),
    do: build_detail(filter_by_agent_name(tasks, name), name)

  defp build_detail([], _name), do: nil

  defp build_detail(own_tasks, name) do
    %{
      name: name,
      current_task: current_task(own_tasks),
      claims: claim_history(own_tasks, name),
      failures: failures(own_tasks),
      recent_activity: agent_events(own_tasks, name)
    }
  end

  # Name-only task filter — pools every same-named agent regardless of human.
  # Used only by the back-compat bare-name agent_detail path; the roster and
  # selection use filter_by_identity/2 (name + owner) instead.
  defp filter_by_agent_name(tasks, name) do
    Enum.filter(tasks, fn t ->
      t.created_by_agent == name or t.completed_by_agent == name
    end)
  end

  # --- Query helpers ---------------------------------------------------------

  @doc false
  # Exposed (not part of the documented API) so `Kanban.Agents.Metrics` can
  # share the single scoped task fetch. The visible, goal-excluded Task set
  # with `:column`, `:created_by`, and `:completed_by` preloaded.
  def fetch_tasks(opts) do
    Task
    |> where([t], t.type != ^:goal)
    |> BoardScope.apply_board_scope_with_column_join(Keyword.get(opts, :scope))
    |> Repo.all()
    # The column name drives status inference, so preload it (one batched
    # query for the whole list). The scope join above is filter-only and does
    # not select the column. The owner associations resolve the human behind
    # each agent and are likewise batched (one query per association), so no
    # per-task query leaks into the callers.
    |> Repo.preload([:column, :created_by, :completed_by])
  end

  # --- list_agents/1 ---------------------------------------------------------

  # The set of distinct agent identities present in the task set, each a
  # `{name, owner_key}` tuple (W1244). An agent is keyed by name AND owning
  # human, so two operators running a same-named agent are two identities; a
  # name with no resolvable owner collapses under the `"none"` sentinel.
  defp distinct_agent_identities(tasks) do
    tasks
    |> Enum.flat_map(&task_identities/1)
    |> Enum.uniq()
  end

  defp task_identities(task) do
    [task.created_by_agent, task.completed_by_agent]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn name -> {name, owner_key_for_owner(owner_for_task_name(task, name))} end)
  end

  # The human owner for a given agent name on a single task: prefer the creator
  # when this name created the task, fall back to the completer. This keeps a
  # task whose created/completed agent name matches but whose owner resolves on
  # only one side a SINGLE identity (not a phantom "none" split).
  defp owner_for_task_name(task, name) do
    created = task.created_by_agent == name && to_owner_map(task.created_by)
    completed = task.completed_by_agent == name && to_owner_map(task.completed_by)
    (is_map(created) && created) || (is_map(completed) && completed) || nil
  end

  @doc false
  # The stable, non-sensitive identity key for an owner map (or nil): the
  # owning user's id as a string, or the `"none"` sentinel. Exposed so the
  # Agents LiveView can key event filtering on the same value without leaking
  # the owner's email into the DOM. Keep this the single source of the key rule.
  def owner_key_for_owner(%{id: id}), do: Integer.to_string(id)
  def owner_key_for_owner(_), do: "none"

  defp build_agent({name, owner_key} = identity, tasks, today) do
    own_tasks = filter_by_identity(tasks, identity)
    now = now_naive()
    last_active_at = last_active(own_tasks)

    %Agent{
      name: name,
      owner_key: owner_key,
      owner: resolve_owner_for_key(own_tasks, owner_key),
      status: infer_status(own_tasks),
      stuck: stuck?(own_tasks, now),
      last_active_at: last_active_at,
      dormant: dormant?(last_active_at, now),
      current_task: current_task(own_tasks),
      capabilities: []
    }
    |> Map.merge(agent_throughput_fields(own_tasks, today))
  end

  # The per-agent throughput counters, split out of build_agent/3 to keep it
  # under the complexity budget.
  defp agent_throughput_fields(own_tasks, today) do
    %{
      today: count_completed_on_day(own_tasks, today),
      last_7d: count_completed_within(own_tasks, today, 7),
      success_rate: success_rate(own_tasks),
      claim_count: Enum.count(own_tasks, &(not is_nil(&1.claimed_at)))
    }
  end

  # The tasks belonging to a single agent identity: a task contributes when it
  # was created OR completed by this agent name AND the corresponding human
  # owner matches the identity's owner_key. This is the fix that stops two
  # same-named agents under different humans from pooling their tasks.
  defp filter_by_identity(tasks, {name, owner_key}) do
    Enum.filter(tasks, fn t ->
      (t.created_by_agent == name and owner_key_for_owner(to_owner_map(t.created_by)) == owner_key) or
        (t.completed_by_agent == name and
           owner_key_for_owner(to_owner_map(t.completed_by)) == owner_key)
    end)
  end

  # Resolves the human owner map for an identity from its already-identity-scoped
  # tasks. Returns nil for the `"none"` sentinel (no resolvable human).
  defp resolve_owner_for_key(_own_tasks, "none"), do: nil

  defp resolve_owner_for_key(own_tasks, owner_key) do
    Enum.find_value(own_tasks, fn task ->
      owner_for_matching_key(to_owner_map(task.created_by), owner_key) ||
        owner_for_matching_key(to_owner_map(task.completed_by), owner_key)
    end)
  end

  defp owner_for_matching_key(owner, owner_key) do
    if owner && owner_key_for_owner(owner) == owner_key, do: owner
  end

  defp to_owner_map(%User{} = user), do: %{id: user.id, name: user.name, email: user.email}
  defp to_owner_map(_), do: nil

  # Latest activity timestamp across an agent identity's tasks, reusing the same
  # recency rule used to pick an agent's most recent task. Returns a
  # `NaiveDateTime` so the roster can be ordered newest-first.
  defp agent_recency(identity, tasks) do
    case tasks |> filter_by_identity(identity) |> most_recent_task() do
      nil -> @epoch_recency
      task -> task_recency(task)
    end
  end

  # Status is derived from the board column, not the `:in_progress` status,
  # because that status spans both Doing and Review. An agent is `:working`
  # only when it holds a Doing-column task; an agent whose tasks sit in the
  # Review column (and none in Doing) is `:waiting`; everything else is `:idle`.
  defp infer_status(tasks) do
    cond do
      Enum.any?(tasks, &in_column?(&1, @doing_column)) -> :working
      awaiting_review?(tasks) -> :waiting
      true -> :idle
    end
  end

  defp awaiting_review?(tasks) do
    Enum.any?(tasks, &in_column?(&1, @review_column))
  end

  defp in_column?(task, column_name) do
    case task.column do
      %{name: ^column_name} -> true
      _ -> false
    end
  end

  defp most_recent_task([]), do: nil

  defp most_recent_task(tasks) do
    Enum.max_by(tasks, &task_recency/1, NaiveDateTime)
  end

  defp task_recency(task) do
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

  # The agent's most recent activity timestamp, reusing the same recency rule
  # used to order the roster. nil only when the agent has no tasks (which does
  # not occur for a derived agent — it always has at least one task).
  defp last_active(own_tasks) do
    case most_recent_task(own_tasks) do
      nil -> nil
      task -> task_recency(task)
    end
  end

  # An agent is dormant when its most recent activity is older than
  # @dormant_threshold_days. Derived from the same task_recency/1 timestamps as
  # the roster ordering, so no new field. An agent with no activity timestamp
  # is treated as not dormant.
  defp dormant?(nil, _now), do: false

  defp dormant?(last_active_at, now) do
    cutoff = NaiveDateTime.add(now, -@dormant_threshold_days * 24 * 60 * 60, :second)
    NaiveDateTime.compare(last_active_at, cutoff) == :lt
  end

  # The current-task pill reflects active work only, so it surfaces a
  # Doing-column task. When an agent has work in both Doing and Review, the
  # Doing task wins; when its only open tasks are in Review, there is no pill.
  defp current_task(tasks) do
    case Enum.find(tasks, &in_column?(&1, @doing_column)) do
      nil -> nil
      task -> %{identifier: task.identifier, title: task.title}
    end
  end

  # An agent is stuck when any of its active tasks (Doing or Review column)
  # has not progressed within @stuck_threshold_minutes — it has stalled
  # mid-work or is sitting in review past the threshold. Derived from the
  # same task_recency/1 timestamps used to order the roster, so no new field.
  defp stuck?(tasks, now) do
    Enum.any?(tasks, &task_stuck?(&1, now))
  end

  defp task_stuck?(task, now) do
    active_task?(task) and stale?(task, now)
  end

  defp active_task?(task) do
    in_column?(task, @doing_column) or in_column?(task, @review_column)
  end

  defp stale?(task, now) do
    cutoff = NaiveDateTime.add(now, -@stuck_threshold_minutes * 60, :second)
    recency = task_recency(task)
    NaiveDateTime.compare(recency, cutoff) == :lt
  end

  defp now_naive, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @doc false
  # Exposed for `Kanban.Agents.Metrics`. Count of tasks completed on `date`
  # (UTC date of `completed_at`). Also used by the roster's per-agent stats.
  def count_completed_on_day(tasks, date) do
    Enum.count(tasks, &completed_on?(&1, date))
  end

  @doc false
  # Exposed for `Kanban.Agents.Metrics`. Count of tasks completed within the
  # trailing `days`-day window ending today (inclusive). Also used by the
  # roster's per-agent stats.
  def count_completed_within(tasks, today, days) do
    earliest = Date.add(today, -(days - 1))

    Enum.count(tasks, fn task ->
      case task.completed_at do
        nil -> false
        %DateTime{} = dt -> Date.compare(DateTime.to_date(dt), earliest) != :lt
      end
    end)
  end

  @doc false
  # Exposed for `Kanban.Agents.Metrics`. Approved over (approved + rejected)
  # across the given tasks, or `0.0` when none have been reviewed. Also used
  # by the roster's per-agent success rate.
  def success_rate(tasks) do
    approved = Enum.count(tasks, &(&1.review_status == :approved))
    rejected = Enum.count(tasks, &(&1.review_status == :rejected))

    case approved + rejected do
      0 -> 0.0
      total -> approved / total
    end
  end

  defp completed_on?(%{completed_at: %DateTime{} = dt}, date), do: DateTime.to_date(dt) == date
  defp completed_on?(_task, _date), do: false

  # --- recent_activity/1 -----------------------------------------------------

  defp events_for(task) do
    [
      build_event(
        :create,
        task.created_by_agent,
        to_owner_map(task.created_by),
        task,
        task.inserted_at
      ),
      build_event(
        :claim,
        claim_actor(task),
        to_owner_map(claim_owner(task)),
        task,
        task.claimed_at
      ),
      build_event(
        :complete,
        task.completed_by_agent,
        to_owner_map(task.completed_by),
        task,
        task.completed_at
      ),
      build_event(
        :review,
        task.completed_by_agent,
        to_owner_map(task.completed_by),
        task,
        task.reviewed_at
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The agent associated with a claim. In Stride's single-claim model the agent
  # that completes a task is the one that claimed and worked it, so prefer
  # `completed_by_agent`; fall back to the creating agent, then to nil (the feed
  # renders nil as a neutral fallback avatar). This keeps the Claims/All views
  # showing the working agent instead of a blank, without inventing a name.
  defp claim_actor(task), do: task.completed_by_agent || task.created_by_agent

  # The User behind a claim event, mirroring claim_actor's precedence: prefer
  # the completer, fall back to the creator. Uses the same preloaded
  # created_by/completed_by associations as the roster, so no extra query.
  defp claim_owner(task), do: task.completed_by || task.created_by

  defp build_event(_kind, _actor, _owner, _task, nil), do: nil

  defp build_event(kind, actor, owner, task, at) do
    %Event{
      kind: kind,
      actor: actor,
      owner: owner,
      identifier: task.identifier,
      title: task.title,
      at: to_datetime(at),
      cycle_time_minutes: cycle_time_for(kind, task)
    }
  end

  defp cycle_time_for(:complete, %{time_spent_minutes: minutes}) when is_integer(minutes),
    do: minutes

  defp cycle_time_for(_kind, _task), do: nil

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  # --- agent_detail/2 --------------------------------------------------------

  # Tasks this agent claimed (claim actor matches and a claim timestamp
  # exists), newest first. Mirrors claim_actor/1's completer-then-creator
  # precedence so the history reflects the agent that worked the task.
  defp claim_history(tasks, name) do
    tasks
    |> Enum.filter(&(not is_nil(&1.claimed_at) and claim_actor(&1) == name))
    |> Enum.map(&task_ref(&1, &1.claimed_at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # Tasks whose review was rejected, newest first by review time. A rejected
  # task always carries a `reviewed_at` (the review changeset requires it).
  defp failures(tasks) do
    tasks
    |> Enum.filter(&(&1.review_status == :rejected))
    |> Enum.map(&task_ref(&1, &1.reviewed_at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # A lightweight task reference for the drill-down lists: identifier, title,
  # and the relevant timestamp coerced to a DateTime.
  defp task_ref(task, at) do
    %{identifier: task.identifier, title: task.title, at: to_datetime(at)}
  end

  # The agent's own derived events (create/claim/complete/review), newest
  # first, capped at @agent_detail_activity_limit. Reuses events_for/1 so the
  # event shape matches the activity feed exactly.
  defp agent_events(tasks, name) do
    tasks
    |> Enum.flat_map(&events_for/1)
    |> Enum.filter(&(&1.actor == name))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(@agent_detail_activity_limit)
  end
end
