defmodule KanbanWeb.API.Me.BoardJSON do
  @moduledoc """
  JSON rendering for the app's Boards tab (W2759,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.9): `GET /api/me/boards`,
  `GET /api/me/boards/:id/columns/:name` and `POST /api/me/boards/:id/promote`.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. A card carries the counts of a task's acceptance criteria, key files
  and security considerations, never their text.
  """

  alias Kanban.Columns.Column
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.Me.MeJSON

  @doc "Every board the person can see in the app, in `/boards` order."
  def index(%{boards: boards}), do: %{data: Enum.map(boards, &board/1)}

  @doc "One page of a column's cards."
  def column(%{board_id: board_id, column: column, page: page}) do
    %{
      data: %{
        board_id: board_id,
        column: column_ref(column),
        tasks: Enum.map(page.tasks, &card/1),
        page: page.page,
        per_page: page.per_page,
        total: page.total,
        next_page: page.next_page
      }
    }
  end

  @doc "The result of a promote: the moved cards, and the ids already in Ready."
  def promoted(%{result: result}) do
    %{
      data: %{
        promoted: Enum.map(result.promoted, &card/1),
        already_ready: result.already_ready
      }
    }
  end

  @doc "One board of the list, from a `Kanban.Boards.AppBoards` entry."
  def board(entry) do
    %{
      id: entry.board.id,
      name: entry.board.name,
      access: entry.access,
      group: entry.group,
      workspace: workspace(entry.workspace),
      counts: entry.counts,
      idle_agents: entry.idle_agents
    }
  end

  @doc "A Backlog card's fields (design §6.9)."
  def card(%Task{} = task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      type: task.type,
      priority: task.priority,
      status: task.status,
      needs_review: task.needs_review,
      position: task.position,
      label: first_label(task.labels),
      criteria_count: criteria_count(task.acceptance_criteria),
      key_files_count: length(task.key_files || []),
      security_considerations_count: length(task.security_considerations || [])
    }
  end

  defp workspace(nil), do: nil
  defp workspace(workspace), do: MeJSON.workspace(workspace)

  defp column_ref(%Column{} = column), do: %{id: column.id, name: column.name}

  # The first label in the board card's order: by name, ignoring case, then id.
  defp first_label(labels) when is_list(labels) and labels != [] do
    label = Enum.min_by(labels, &{String.downcase(&1.name), &1.id})
    %{id: label.id, name: label.name, color: label.color}
  end

  defp first_label(_labels), do: nil

  # Non-blank lines, the rule the review screen and completion checks count by.
  defp criteria_count(criteria) when is_binary(criteria) do
    criteria |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))
  end

  defp criteria_count(_criteria), do: 0
end
