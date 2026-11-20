defmodule KanbanWeb.API.Me.GoalJSON do
  @moduledoc """
  JSON rendering for the app's Goals list and Goal screen (W2762,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.18, §6.19, §7.10): `GET
  /api/me/goals` and `GET /api/me/goals/:id`.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree.

  A goal's counts carry the same keys as the Agents goal rows
  (`KanbanWeb.API.Me.AgentJSON.goal/1`). A task names its agent, never a
  person's email, and carries no description.
  """

  alias Kanban.Tasks.Task

  @doc "One page of the person's goals."
  def index(%{result: result}) do
    %{
      data: %{
        goals: Enum.map(result.goals, &goal/1),
        filter: result.filter,
        filters: Map.take(result.filters, [:open, :done, :no_target]),
        page: result.page,
        per_page: result.per_page,
        total: result.total,
        next_page: result.next_page
      }
    }
  end

  @doc "A goal and its tasks grouped by column."
  def show(%{detail: detail}) do
    %{
      data: %{
        goal: goal(detail.goal),
        agents: detail.agents,
        archived_done: detail.archived_done,
        groups: Enum.map(detail.groups, &group/1)
      }
    }
  end

  @doc "One goal row."
  def goal(%{goal: %Task{} = goal} = entry) do
    %{
      id: goal.id,
      identifier: goal.identifier,
      title: goal.title,
      status: goal.status,
      board: %{id: entry.board.id, name: entry.board.name},
      target: target(entry.target),
      counts: Map.take(entry.counts, [:total, :completed, :doing, :review, :blocked]),
      waiting_on_you: entry.waiting_on_you,
      hook_failed: entry.hook_failed
    }
  end

  @doc "One column's group of the goal's tasks."
  def group(%{status: status, tasks: tasks}),
    do: %{status: status, tasks: Enum.map(tasks, &task/1)}

  @doc "One task of the goal."
  def task(%{task: %Task{} = task} = entry) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      type: task.type,
      status: task.status,
      needs_review: task.needs_review,
      reviewable: entry.reviewable,
      agent: entry.agent,
      in_column_since: entry.in_column_since
    }
  end

  defp target(%{id: id, name: name}), do: %{id: id, name: name}
  defp target(_target), do: nil
end
