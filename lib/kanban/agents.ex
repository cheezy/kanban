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
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Agents.Agent
  alias Kanban.Agents.Event
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @default_event_limit 50

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
  def list_agents(opts \\ []) do
    tasks = fetch_tasks(opts)
    today = Date.utc_today()

    # Sort by name first, then stable-sort by recency descending: because
    # `Enum.sort_by/3` is stable, agents with equal recency keep the
    # name-ascending order as a deterministic alphabetical tiebreak.
    tasks
    |> distinct_agent_names()
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
    limit = Keyword.get(opts, :limit, @default_event_limit)

    opts
    |> fetch_tasks()
    |> Enum.flat_map(&events_for/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Returns aggregate header counters for the Agents view.

  The returned map contains:

    * `:claimed_today` — count of tasks whose `claimed_at` falls on the
      current UTC date
    * `:completed_today` — count of tasks whose `completed_at` falls on
      the current UTC date
    * `:approved_today` — count of tasks whose `reviewed_at` falls on the
      current UTC date with `review_status` `:approved`
    * `:avg_cycle_minutes` — average `time_spent_minutes` across completed
      tasks where the value is set, or `0` when no qualifying tasks exist
  """
  @spec header_stats(keyword()) :: %{
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats(opts \\ []) do
    tasks = fetch_tasks(opts)
    today = Date.utc_today()

    %{
      claimed_today: count_on_day(tasks, :claimed_at, today),
      completed_today: count_on_day(tasks, :completed_at, today),
      approved_today: count_approved_on(tasks, today),
      avg_cycle_minutes: avg_cycle_minutes(tasks)
    }
  end

  @doc """
  Returns fleet-health rollup counts for the scoped agent set.

  The returned map carries one count per dimension:

    * `:working` / `:waiting` / `:idle` — number of agents in each derived
      `Agent.status`. These three partition the agent set.
    * `:stuck` — number of agents whose `Agent.stuck` flag is set. Because
      stuck-ness is orthogonal to status (see the "Stuck agents" section),
      this is a cross-cutting count that overlaps the status buckets — a
      stalled `:working` agent is counted in both `:working` and `:stuck`.

  Counts are derived from `list_agents/1`, so the status and stuck rules are
  shared verbatim (no drift) and the `:scope` board filtering is respected.
  An empty agent set returns all zeros.
  """
  @spec fleet_health(keyword()) :: %{
          working: non_neg_integer(),
          waiting: non_neg_integer(),
          idle: non_neg_integer(),
          stuck: non_neg_integer()
        }
  def fleet_health(opts \\ []) do
    agents = list_agents(opts)

    %{
      working: Enum.count(agents, &(&1.status == :working)),
      waiting: Enum.count(agents, &(&1.status == :waiting)),
      idle: Enum.count(agents, &(&1.status == :idle)),
      stuck: Enum.count(agents, & &1.stuck)
    }
  end

  @doc """
  Returns fleet-wide throughput counts and an overall success rate.

  Throughput is the number of tasks whose `completed_at` falls within each
  window, counted once per task. The returned map contains:

    * `:completed_today` — completions on the current UTC date
    * `:completed_7d` — completions within the trailing 7-day window
      (today and the six prior days)
    * `:completed_30d` — completions within the trailing 30-day window
    * `:success_rate` — approved over (approved + rejected) across the
      visible tasks, as a float in `0.0..1.0`; `0.0` when no task has been
      approved or rejected

  Counts are derived directly from the visible Task set — not summed across
  per-agent rollups — so a task touched by two agents is counted once, and
  there is no double-count. `:scope` board filtering is respected. An empty
  task set returns all zeros.
  """
  @spec throughput_and_success(keyword()) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success(opts \\ []) do
    tasks = fetch_tasks(opts)
    today = Date.utc_today()

    %{
      completed_today: count_completed_on_day(tasks, today),
      completed_7d: count_completed_within(tasks, today, 7),
      completed_30d: count_completed_within(tasks, today, 30),
      success_rate: success_rate(tasks)
    }
  end

  # --- Query helpers ---------------------------------------------------------

  defp fetch_tasks(opts) do
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

  defp distinct_agent_names(tasks) do
    tasks
    |> Enum.flat_map(fn t -> [t.created_by_agent, t.completed_by_agent] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_agent(name, tasks, today) do
    own_tasks = filter_by_agent(tasks, name)

    %Agent{
      name: name,
      owner: resolve_owner(name, own_tasks),
      status: infer_status(own_tasks),
      stuck: stuck?(own_tasks, now_naive()),
      current_task: current_task(own_tasks),
      capabilities: [],
      today: count_completed_on_day(own_tasks, today),
      last_7d: count_completed_within(own_tasks, today, 7),
      success_rate: success_rate(own_tasks),
      claim_count: Enum.count(own_tasks, &(not is_nil(&1.claimed_at)))
    }
  end

  defp filter_by_agent(tasks, name) do
    Enum.filter(tasks, fn t ->
      t.created_by_agent == name or t.completed_by_agent == name
    end)
  end

  # Resolves the human owner behind a derived agent. Prefers the User who
  # created a task as this agent; falls back to the User who completed one.
  # Returns nil when neither association resolves to a User.
  defp resolve_owner(name, own_tasks) do
    owner_from(own_tasks, name, :created_by_agent, :created_by) ||
      owner_from(own_tasks, name, :completed_by_agent, :completed_by)
  end

  defp owner_from(tasks, name, agent_field, user_field) do
    Enum.find_value(tasks, fn task ->
      if Map.get(task, agent_field) == name do
        to_owner_map(Map.get(task, user_field))
      end
    end)
  end

  defp to_owner_map(%User{} = user), do: %{id: user.id, name: user.name, email: user.email}
  defp to_owner_map(_), do: nil

  # Latest activity timestamp across an agent's tasks, reusing the same
  # recency rule used to pick an agent's most recent task. Returns a
  # `NaiveDateTime` so the roster can be ordered newest-first.
  defp agent_recency(name, tasks) do
    case tasks |> filter_by_agent(name) |> most_recent_task() do
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

  defp count_completed_on_day(tasks, date) do
    Enum.count(tasks, &completed_on?(&1, date))
  end

  defp count_completed_within(tasks, today, days) do
    earliest = Date.add(today, -(days - 1))

    Enum.count(tasks, fn task ->
      case task.completed_at do
        nil -> false
        %DateTime{} = dt -> Date.compare(DateTime.to_date(dt), earliest) != :lt
      end
    end)
  end

  defp success_rate(tasks) do
    approved = Enum.count(tasks, &(&1.review_status == :approved))
    rejected = Enum.count(tasks, &(&1.review_status == :rejected))

    case approved + rejected do
      0 -> 0.0
      total -> approved / total
    end
  end

  # --- header_stats/1 --------------------------------------------------------

  defp count_on_day(tasks, field, date) do
    Enum.count(tasks, fn task ->
      case Map.get(task, field) do
        nil -> false
        %DateTime{} = dt -> DateTime.to_date(dt) == date
      end
    end)
  end

  defp count_approved_on(tasks, date) do
    Enum.count(tasks, fn task ->
      task.review_status == :approved and not is_nil(task.reviewed_at) and
        DateTime.to_date(task.reviewed_at) == date
    end)
  end

  defp avg_cycle_minutes(tasks) do
    minutes =
      tasks
      |> Enum.filter(&(not is_nil(&1.completed_at) and is_integer(&1.time_spent_minutes)))
      |> Enum.map(& &1.time_spent_minutes)

    case minutes do
      [] -> 0.0
      list -> Enum.sum(list) / length(list)
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
end
