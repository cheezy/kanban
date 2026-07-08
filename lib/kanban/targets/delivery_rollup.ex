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
  target. Those agents are returned in `:unrolled_agents` so no work is silently
  dropped from the delivery picture.

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
  alias Kanban.Repo
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
  The full delivery rollup: one entry per accessible target (ordered as
  `Kanban.Targets.list_targets_with_status/2` orders them, soonest date first),
  plus the agents whose work never reaches a target.
  """
  @type t :: %{
          targets: [target_rollup()],
          unrolled_agents: [Agent.t()]
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

    %{
      targets: build_target_rollups(scope, today, agents, bridges),
      unrolled_agents: unrolled_agents(agents, bridges)
    }
  end

  # The board-scoped, goal-excluded task set with each task's parent goal and
  # that goal's target preloaded, so the in-memory bridge can walk
  # task -> parent goal -> target without any further query. Parent goals share
  # their children's board, so preloading from an already board-scoped task set
  # yields only accessible goals/targets.
  defp fetch_bridged_tasks(scope) do
    scope
    |> then(&Agents.fetch_tasks(scope: &1))
    |> Repo.preload(parent: :target)
  end

  # One rollup entry per accessible target, reusing Phase 1 status derivation
  # (`list_targets_with_status/2`) for the target + status and
  # `list_member_goals/2` for the member goals.
  defp build_target_rollups(scope, today, agents, bridges) do
    scope
    |> Targets.list_targets_with_status(today)
    |> Enum.map(&target_rollup(scope, &1, agents, bridges))
  end

  defp target_rollup(scope, %{target: target, status: status}, agents, bridges) do
    goals = Targets.list_member_goals(scope, target)
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
    bridges
    |> Map.fetch!(identity(agent))
    |> Enum.any?(fn {gid, tid} -> gid == goal_id and tid == target_id end)
  end

  # Agents with no bridge at all — every task lacks a parent goal or the parent
  # goal has no target — are returned outside the target rollup.
  defp unrolled_agents(agents, bridges) do
    Enum.filter(agents, fn agent -> Map.fetch!(bridges, identity(agent)) == [] end)
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
  # or the parent goal is not assigned to a target.
  defp task_bridge(%Task{parent: %Task{id: goal_id, target_id: target_id}})
       when not is_nil(target_id),
       do: {goal_id, target_id}

  defp task_bridge(_task), do: nil

  defp active_on_target?(agent, target_id, bridges) do
    bridges
    |> Map.fetch!(identity(agent))
    |> Enum.any?(fn {_goal_id, tid} -> tid == target_id end)
  end

  # The member goal ids of `target_id` that a stalled agent is active on.
  defp stalled_goal_ids(stalled_agents, target_id, bridges) do
    for agent <- stalled_agents,
        {goal_id, tid} <- Map.fetch!(bridges, identity(agent)),
        tid == target_id,
        into: MapSet.new(),
        do: goal_id
  end

  # An agent is stalled when the roster flagged it stuck or dormant.
  defp stalled?(%Agent{stuck: stuck, dormant: dormant}), do: stuck or dormant

  defp identity(%Agent{name: name, owner_key: owner_key}), do: {name, owner_key}
end
