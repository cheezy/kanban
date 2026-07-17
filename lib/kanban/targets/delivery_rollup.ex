defmodule Kanban.Targets.DeliveryRollup do
  @moduledoc """
  Read-only bridge from the agent roster to the delivery targets.

  This is the data foundation for the Phase 2 delivery-centric views: it
  connects each active agent to the delivery target it is contributing toward
  by walking the chain

      agent -> its tasks -> parent goal -> goal's target

  and produces, for every target the caller can access, the derived
  `Kanban.Targets.Status`, the target's member goals, the agents active on it,
  and the goals and agents that have stalled.

  ## What "active on a target" means

  An agent is active on a target when at least one of the agent's tasks (a task
  it created or completed) has a parent goal assigned to that target. A single
  agent can be active on several targets at once — it appears under each.

  ## Agents outside the rollup

  An agent whose tasks never reach a target — because they have no parent goal,
  or the parent goal is not assigned to any target — is not attributed to any
  target.

  The task fetch is bounded to target-bridged tasks (tasks whose parent goal is
  assigned to a target) so the /agents load stays within the database statement
  timeout at production scale (D122). A consequence of that bound is that agents
  whose work never reaches a target are not fetched at all, so `:unrolled_agents`
  is always `[]`. The key is retained in the return shape for API stability; it
  is not currently rendered by any caller.

  ## Stalled goals and agents

  "Stalled" reuses the agent roster's classification wholesale: an agent is
  stalled when it is `stuck` (holding an active task past the stuck threshold)
  OR `dormant` (no activity past the dormancy threshold). A member goal is
  stalled when at least one stalled agent is active on it. The rollup never
  re-implements stuck/dormant detection — it reads the flags
  `Kanban.Agents.Roster` already derived.

  ## Scoping / security

  Every read is board-scoped to `scope`. The task set comes from
  `Kanban.Agents.fetch_tasks/1` (board-scoped, goal-excluded), the targets and
  their member goals come from `Kanban.Targets` (board-scoped), and the
  agent->goal->target bridge is derived purely in memory from that already
  board-scoped data — so no target, goal, agent, or status from an inaccessible
  board can leak into the rollup.

  ## Purity / time injection

  `today` (for status derivation) and `timezone` (for the roster's stuck/dormant
  clock) are injected at this impure boundary — `today` defaults to the local
  day in `timezone`. The pure derivation is deterministic and testable by
  passing an explicit `today`.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Agents.Agent
  alias Kanban.Agents.Roster
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Status
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @typedoc """
  One stalled member goal paired with the stalled agents active on it — the
  per-goal breakdown the at-risk explainer renders under a target.
  """
  @type stalled_detail :: %{goal: Task.t(), agents: [Agent.t()]}

  @typedoc """
  One target's rollup entry: the target, its read-time status, its member
  goals, the agents active on it, and the stalled subset of each.

  `stalled_details` pairs each stalled goal with the stalled agents active on
  that specific goal (a subset of `stalled_agents`), so a consumer can tie a
  named agent stall to the named goal it is stalling without re-deriving the
  agent→goal bridge.
  """
  @type target_rollup :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          goals: [Task.t()],
          agents: [Agent.t()],
          stalled_goals: [Task.t()],
          stalled_agents: [Agent.t()],
          stalled_details: [stalled_detail()]
        }

  @typedoc """
  One target+goal an agent is advancing, with the target's read-time status —
  the annotation the roster card renders and the risk-first roster ordering
  keys on.
  """
  @type agent_annotation :: %{
          target: DeliveryTarget.t(),
          goal: Task.t(),
          status: Status.status()
        }

  @typedoc """
  The full delivery rollup: one entry per accessible target (ordered as
  `Kanban.Targets.list_targets_with_status/2` orders them, soonest date first),
  `unrolled_agents` (always `[]` — see the "Agents outside the rollup" moduledoc
  section; retained for API stability), and `agent_targets` — a map from each
  agent's `{name, owner_key}` identity to the target+goal annotations it is
  advancing (empty list for an agent that reaches no target). Both rendered views
  derive from the same board-scoped data, so a consumer can annotate and order
  the roster without any further query.
  """
  @type t :: %{
          targets: [target_rollup()],
          unrolled_agents: [Agent.t()],
          agent_targets: %{{String.t(), String.t()} => [agent_annotation()]}
        }

  @doc """
  Builds the delivery rollup for `scope`.

  ## Options

    * `:timezone` — IANA zone anchoring the roster's stuck/dormant clock and the
      default `today` (default `"Etc/UTC"`).
    * `:today` — the `Date` used for status derivation (default: the local day
      in `:timezone`). Pass an explicit value to keep derivation deterministic
      in tests.

  Returns `%{targets: [target_rollup()], unrolled_agents: [Agent.t()]}`.
  """
  @spec build(Scope.t() | nil, keyword()) :: t()
  def build(scope, opts \\ []) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    today = Keyword.get(opts, :today, Timezone.local_today(timezone))

    tasks = fetch_bridged_tasks(scope)
    agents = Roster.from_tasks(tasks, timezone)
    bridges = agent_bridges(agents, tasks)
    target_rollups = build_target_rollups(scope, today, agents, bridges)

    %{
      targets: target_rollups,
      unrolled_agents: unrolled_agents(agents, bridges),
      agent_targets: agent_targets(agents, bridges, target_rollups)
    }
  end

  # The board-scoped task set the in-memory bridge needs. Each projected task
  # carries a `parent: %{id, target_id}` map so the bridge can walk task ->
  # parent goal -> target without any further query. `fetch_target_bridged_tasks/1`
  # bounds the fetch to tasks whose parent goal is assigned to a target (D122) —
  # the only tasks that can produce a bridge pair — so the query stays within the
  # database statement timeout at production scale without dropping any
  # attribution. Parent goals share their children's board, so an already
  # board-scoped task set yields only accessible goals.
  #
  # Only the parent goal's `id` and `target_id` are read, and the projected fetch
  # (W1735) resolves them in its join, so no `Repo.preload(:parent)` is needed —
  # the rollup issues one query. The target/status structs the UI renders come
  # from `Kanban.Targets`, a separate path this fetch never touches.
  defp fetch_bridged_tasks(scope) do
    Agents.fetch_target_bridged_tasks(scope: scope)
  end

  # One rollup entry per accessible target. `list_targets_with_status_and_goals/2`
  # returns the target + status AND the member goals in one pass, fetching each
  # target's member goals exactly once — previously the rollup called
  # `list_member_goals/2` a second time per target on top of the fetch inside
  # the status summary (a redundant query per target on every /agents refresh).
  defp build_target_rollups(scope, today, agents, bridges) do
    scope
    |> Targets.list_targets_with_status_and_goals(today)
    |> Enum.map(&target_rollup(&1, agents, bridges))
  end

  defp target_rollup(%{target: target, status: status, goals: goals}, agents, bridges) do
    target_agents = Enum.filter(agents, &active_on_target?(&1, target.id, bridges))
    stalled_agents = Enum.filter(target_agents, &stalled?/1)
    stalled_goals = stalled_goals(goals, stalled_agents, target.id, bridges)

    %{
      target: target,
      status: status,
      goals: goals,
      agents: target_agents,
      stalled_goals: stalled_goals,
      stalled_agents: stalled_agents,
      stalled_details: stalled_details(stalled_goals, stalled_agents, target.id, bridges)
    }
  end

  # The member goals of `target_id` that a stalled agent is active on.
  defp stalled_goals(goals, stalled_agents, target_id, bridges) do
    ids = stalled_goal_ids(stalled_agents, target_id, bridges)
    Enum.filter(goals, &MapSet.member?(ids, &1.id))
  end

  # Each stalled goal paired with the stalled agents active on that goal — the
  # per-goal breakdown the at-risk explainer renders.
  defp stalled_details(stalled_goals, stalled_agents, target_id, bridges) do
    Enum.map(stalled_goals, fn goal ->
      %{
        goal: goal,
        agents: Enum.filter(stalled_agents, &on_goal?(&1, goal.id, target_id, bridges))
      }
    end)
  end

  defp on_goal?(agent, goal_id, target_id, bridges) do
    # `bridges` maps every agent identity to its list of `{goal_id, target_id}`
    # pairs (`[]` when it bridges to nothing). Use `Map.get/3` with an empty-list
    # default rather than `Map.fetch!/2`: a missing key means "no bridges", which
    # is the correct no-op for every consumer here — and it prevents a stray
    # identity divergence (e.g. an association that failed to preload under a DB
    # timeout) from raising a `KeyError` and crashing the whole /agents LiveView.
    bridges
    |> Map.get(identity(agent), [])
    |> Enum.any?(fn {gid, tid} -> gid == goal_id and tid == target_id end)
  end

  # Agents with no bridge at all — every task lacks a parent goal or the parent
  # goal has no target — are returned outside the target rollup.
  defp unrolled_agents(agents, bridges) do
    Enum.filter(agents, fn agent -> Map.get(bridges, identity(agent), []) == [] end)
  end

  # Maps each agent identity to the target+goal annotations it is advancing,
  # resolving the bridge's `{goal_id, target_id}` pairs against the already-built
  # target rollups (so goal/target structs and status come from the same
  # board-scoped derivation — no extra query, no inaccessible data).
  defp agent_targets(agents, bridges, target_rollups) do
    goal_index = goal_index(target_rollups)
    target_index = target_index(target_rollups)

    Map.new(agents, fn agent ->
      id = identity(agent)
      {id, annotations_for(id, bridges, goal_index, target_index)}
    end)
  end

  # goal id -> goal task, across every accessible target's member goals.
  defp goal_index(target_rollups) do
    target_rollups
    |> Enum.flat_map(& &1.goals)
    |> Map.new(&{&1.id, &1})
  end

  # target id -> {target, status}, from the already-built target rollups.
  defp target_index(target_rollups) do
    Map.new(target_rollups, &{&1.target.id, {&1.target, &1.status}})
  end

  defp annotations_for(identity, bridges, goal_index, target_index) do
    bridges
    |> Map.get(identity, [])
    |> Enum.uniq()
    |> Enum.flat_map(&annotation(&1, goal_index, target_index))
  end

  # A single `{goal_id, target_id}` bridge pair resolved to an annotation, or an
  # empty list when either the goal or the target is not in the accessible
  # rollup (defensive — the bridge pairs come from the same scoped data).
  defp annotation({goal_id, target_id}, goal_index, target_index) do
    with %Task{} = goal <- Map.get(goal_index, goal_id),
         {%DeliveryTarget{} = target, status} <- Map.get(target_index, target_id) do
      [%{target: target, goal: goal, status: status}]
    else
      _ -> []
    end
  end

  # Maps each agent identity to the `{goal_id, target_id}` pairs its tasks reach.
  # An agent whose tasks never reach a target maps to `[]`. Built once so the
  # per-target derivation is a pure in-memory lookup.
  defp agent_bridges(agents, tasks) do
    Map.new(agents, fn agent ->
      identity = identity(agent)

      pairs =
        tasks
        |> Agents.filter_by_identity(identity)
        |> Enum.map(&task_bridge/1)
        |> Enum.reject(&is_nil/1)

      {identity, pairs}
    end)
  end

  # The `{goal_id, target_id}` a task reaches, or nil when it has no parent goal
  # or the parent goal is not assigned to a target. Matches the projected
  # `parent: %{id, target_id}` map that fetch_target_bridged_tasks/1 now returns
  # (W1735) — not a `%Task{}` struct.
  defp task_bridge(%{parent: %{id: goal_id, target_id: target_id}})
       when not is_nil(target_id),
       do: {goal_id, target_id}

  defp task_bridge(_task), do: nil

  defp active_on_target?(agent, target_id, bridges) do
    bridges
    |> Map.get(identity(agent), [])
    |> Enum.any?(fn {_goal_id, tid} -> tid == target_id end)
  end

  # The member goal ids of `target_id` that a stalled agent is active on.
  defp stalled_goal_ids(stalled_agents, target_id, bridges) do
    for agent <- stalled_agents,
        {goal_id, tid} <- Map.get(bridges, identity(agent), []),
        tid == target_id,
        into: MapSet.new(),
        do: goal_id
  end

  # An agent is stalled when the roster flagged it stuck or dormant.
  defp stalled?(%Agent{stuck: stuck, dormant: dormant}), do: stuck or dormant

  defp identity(%Agent{name: name, owner_key: owner_key}), do: {name, owner_key}
end
