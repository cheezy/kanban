defmodule KanbanWeb.API.Me.AgentJSON do
  @moduledoc """
  JSON rendering for the app's Agents tab (W2761,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.10, §7.10): `GET
  /api/me/agents` and `GET /api/me/goals/:id/after_goal`.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree.

  An agent's owner is named by id and name only, never by email. A goal's
  after_goal attempt carries no output: no web page shows it (decision 9).
  """

  alias Kanban.Agents.Agent
  alias Kanban.Tasks.AfterGoalAttempt
  alias Kanban.Tasks.Task

  @doc "The roster and the open goals its agents work on."
  def index(%{overview: %{agents: agents, goals: goals}}) do
    %{data: %{agents: Enum.map(agents, &agent/1), goals: Enum.map(goals, &goal/1)}}
  end

  @doc "A goal's last after_goal attempt."
  def after_goal(%{goal: %Task{} = goal}), do: %{data: attempt(goal)}

  @doc "One agent of the roster."
  def agent(%Agent{} = agent) do
    %{
      name: agent.name,
      owner: owner(agent.owner),
      status: agent.status,
      stuck: agent.stuck,
      dormant: agent.dormant,
      last_active_at: utc(agent.last_active_at),
      current_task: current_task(agent.current_task),
      today: agent.today,
      last_7d: agent.last_7d
    }
  end

  @doc "One open goal with an agent on it."
  def goal(%{goal: %Task{} = goal, board_id: board_id, counts: counts, hook_failed: failed}) do
    %{
      id: goal.id,
      identifier: goal.identifier,
      title: goal.title,
      status: goal.status,
      board_id: board_id,
      counts: Map.take(counts, [:total, :completed, :doing, :review, :blocked]),
      hook_failed: failed
    }
  end

  @doc "A goal's last after_goal attempt, read by `Kanban.Tasks.AfterGoalAttempt.last/1`."
  def attempt(%Task{} = goal) do
    last = AfterGoalAttempt.last(goal)

    %{
      goal_id: goal.id,
      identifier: goal.identifier,
      status: last.status,
      exit_code: last.exit_code,
      duration_ms: last.duration_ms,
      reported_at: last.reported_at,
      failed: last.failed
    }
  end

  defp owner(%{id: id, name: name}), do: %{id: id, name: name}
  defp owner(_owner), do: nil

  defp current_task(%{identifier: identifier, title: title}),
    do: %{identifier: identifier, title: title}

  defp current_task(_task), do: nil

  # The roster's times are naive UTC; the app gets them with their zone.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(_at), do: nil
end
