defmodule KanbanWeb.API.Me.TargetJSON do
  @moduledoc """
  JSON rendering for the app's Targets list and Target screen (W2763,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.16, §6.17, §7.10): `GET
  /api/me/targets` and `GET /api/me/targets/:id`.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree.

  `status` is an enum (`on_track`, `at_risk`, `missed`, `complete`), never
  translated text, so the app draws its own words. A goal row is the app's
  Goals list row (`KanbanWeb.API.Me.GoalJSON.goal/1`). A stalled agent is
  named by its agent name, never a person's email.
  """

  alias KanbanWeb.API.Me.GoalJSON

  @doc "The person's targets."
  def index(%{targets: targets}), do: %{data: %{targets: Enum.map(targets, &target/1)}}

  @doc "A target, its goal rows and its risk."
  def show(%{detail: detail}) do
    %{
      data: %{
        target: target(detail.target),
        goals: Enum.map(detail.goals, &GoalJSON.goal/1),
        risk: risk(detail.risk)
      }
    }
  end

  @doc "One target row."
  def target(%{target: target} = row) do
    %{
      id: target.id,
      name: target.name,
      status: row.status,
      target_date: target.target_date,
      estimated_completion_date: row.estimated_completion_date,
      goal_count: row.goal_count,
      completed: row.completed,
      total: row.total,
      owner: row.owner
    }
  end

  @doc "A target's risk reason, or `nil` when it has none."
  def risk(nil), do: nil

  def risk(%{slipped: slipped, stalled: stalled}),
    do: %{slipped: slipped(slipped), stalled: Enum.map(stalled, &stalled_goal/1)}

  defp slipped(nil), do: nil

  defp slipped(%{estimate: estimate, target_date: target_date}),
    do: %{estimate: estimate, target_date: target_date}

  defp stalled_goal(%{goal: goal, agents: agents}) do
    %{
      id: goal.id,
      identifier: goal.identifier,
      title: goal.title,
      agents: Enum.map(agents, &Map.take(&1, [:name, :reasons]))
    }
  end
end
