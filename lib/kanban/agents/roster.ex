defmodule Kanban.Agents.Roster do
  @moduledoc """
  Builds the agent roster — the ordered list of `Agent` structs derived from
  the visible Task set, with each agent's status, stuck/dormant flags, owner,
  current task, and per-agent throughput counters.

  Extracted from `Kanban.Agents` so roster derivation lives behind a single-
  responsibility boundary (mirroring `Kanban.Agents.Metrics`). The shared task
  set, owner/identity resolution, and per-task counters come from
  `Kanban.Agents`; `Kanban.Agents.list_agents/1` and `list_agents_from/1`
  re-export this module so callers use the public API unchanged.

  ## Stuck agents

  An agent is **stuck** when it holds an active task (Doing or Review column)
  whose most recent activity is older than `@stuck_threshold_minutes`
  (60 minutes) — it has stalled mid-work or sat in review past the threshold.
  Reported as the independent `Agent.stuck` boolean, orthogonal to
  `:working` / `:waiting` / `:idle`.

  ## Dormant agents

  An agent is **dormant** when its most recent activity is older than
  `@dormant_threshold_days` (14 days). Dormant agents remain in the roster
  (flagged via `Agent.dormant`) but are excluded from the fleet-health rollup.
  """

  alias Kanban.Agents
  alias Kanban.Agents.Agent

  # Sentinel recency for an agent with no tasks at all, so it sorts to the
  # bottom of the roster. Agents that have tasks always derive a real timestamp.
  @epoch_recency ~N[0000-01-01 00:00:00]

  # An agent holding an active (Doing/Review) task whose most recent activity is
  # older than this many minutes is classified as stuck. Mirrors the 60-minute
  # claim-expiry window.
  @stuck_threshold_minutes 60

  # An agent whose most recent activity is older than this many days is
  # classified as dormant.
  @dormant_threshold_days 14

  @doc """
  Builds the agent roster from an already-fetched task list, ordered by most
  recent activity (newest first), ties broken alphabetically by identity.
  """
  @spec from_tasks([Kanban.Tasks.Task.t()]) :: [Agent.t()]
  def from_tasks(tasks) do
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
    |> Enum.map(fn name ->
      owner = owner_for_task_name(task, name)
      {name, Agents.owner_key_for_owner(owner)}
    end)
  end

  # The human owner for a given agent name on a single task: prefer the creator
  # when this name created the task, fall back to the completer. This keeps a
  # task whose created/completed agent name matches but whose owner resolves on
  # only one side a SINGLE identity (not a phantom "none" split).
  defp owner_for_task_name(task, name) do
    created = task.created_by_agent == name && Agents.to_owner_map(task.created_by)
    completed = task.completed_by_agent == name && Agents.to_owner_map(task.completed_by)
    (is_map(created) && created) || (is_map(completed) && completed) || nil
  end

  defp build_agent({name, owner_key} = identity, tasks, today) do
    own_tasks = Agents.filter_by_identity(tasks, identity)
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
      current_task: Agents.current_task(own_tasks),
      capabilities: []
    }
    |> Map.merge(agent_throughput_fields(own_tasks, today))
  end

  # The per-agent throughput counters, split out of build_agent/3 to keep it
  # under the complexity budget.
  defp agent_throughput_fields(own_tasks, today) do
    %{
      today: Agents.count_completed_on_day(own_tasks, today),
      last_7d: Agents.count_completed_within(own_tasks, today, 7),
      success_rate: Agents.success_rate(own_tasks),
      claim_count: Enum.count(own_tasks, &(not is_nil(&1.claimed_at)))
    }
  end

  # Resolves the human owner map for an identity from its already-identity-scoped
  # tasks. Returns nil for the `"none"` sentinel (no resolvable human).
  defp resolve_owner_for_key(_own_tasks, "none"), do: nil

  defp resolve_owner_for_key(own_tasks, owner_key) do
    Enum.find_value(own_tasks, fn task ->
      owner_for_matching_key(Agents.to_owner_map(task.created_by), owner_key) ||
        owner_for_matching_key(Agents.to_owner_map(task.completed_by), owner_key)
    end)
  end

  defp owner_for_matching_key(owner, owner_key) do
    if owner && Agents.owner_key_for_owner(owner) == owner_key, do: owner
  end

  # Latest activity timestamp across an agent identity's tasks, reusing the same
  # recency rule used to pick an agent's most recent task. Returns a
  # `NaiveDateTime` so the roster can be ordered newest-first.
  defp agent_recency(identity, tasks) do
    case tasks |> Agents.filter_by_identity(identity) |> most_recent_task() do
      nil -> @epoch_recency
      task -> Agents.task_recency(task)
    end
  end

  # Status is derived from the board column, not the `:in_progress` status,
  # because that status spans both Doing and Review. An agent is `:working`
  # only when it holds a Doing-column task; an agent whose tasks sit in the
  # Review column (and none in Doing) is `:waiting`; everything else is `:idle`.
  defp infer_status(tasks) do
    cond do
      Enum.any?(tasks, &Agents.doing?/1) -> :working
      awaiting_review?(tasks) -> :waiting
      true -> :idle
    end
  end

  defp awaiting_review?(tasks) do
    Enum.any?(tasks, &Agents.in_review?/1)
  end

  defp most_recent_task([]), do: nil

  defp most_recent_task(tasks) do
    Enum.max_by(tasks, &Agents.task_recency/1, NaiveDateTime)
  end

  # The agent's most recent activity timestamp, reusing the same recency rule
  # used to order the roster. nil only when the agent has no tasks (which does
  # not occur for a derived agent — it always has at least one task).
  defp last_active(own_tasks) do
    case most_recent_task(own_tasks) do
      nil -> nil
      task -> Agents.task_recency(task)
    end
  end

  # An agent is dormant when its most recent activity is older than
  # @dormant_threshold_days. An agent with no activity timestamp is not dormant.
  defp dormant?(nil, _now), do: false

  defp dormant?(last_active_at, now) do
    cutoff = NaiveDateTime.add(now, -@dormant_threshold_days * 24 * 60 * 60, :second)
    NaiveDateTime.compare(last_active_at, cutoff) == :lt
  end

  # An agent is stuck when any of its active tasks (Doing or Review column) has
  # not progressed within @stuck_threshold_minutes — it has stalled mid-work or
  # is sitting in review past the threshold.
  defp stuck?(tasks, now) do
    Enum.any?(tasks, &task_stuck?(&1, now))
  end

  defp task_stuck?(task, now) do
    active_task?(task) and stale?(task, now)
  end

  defp active_task?(task) do
    Agents.doing?(task) or Agents.in_review?(task)
  end

  defp stale?(task, now) do
    cutoff = NaiveDateTime.add(now, -@stuck_threshold_minutes * 60, :second)
    recency = Agents.task_recency(task)
    NaiveDateTime.compare(recency, cutoff) == :lt
  end

  defp now_naive, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
