defmodule KanbanWeb.API.Me.TaskJSON do
  @moduledoc """
  JSON rendering for the app's task actions (W2760,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.10): `GET
  /api/me/tasks/:id`, `POST /api/me/tasks/:id/comments`, `POST
  /api/me/tasks/:id/move_to_backlog` and `POST /api/me/tasks`.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. A comment has the shape the agent API gives it
  (`KanbanWeb.API.TaskCommentJSON`), and a moved task the Boards tab's card
  (`KanbanWeb.API.Me.BoardJSON.card/1`).
  """

  alias Kanban.Tasks.Task
  alias KanbanWeb.API.Me.BoardJSON
  alias KanbanWeb.API.TaskCommentJSON
  alias KanbanWeb.API.TaskNestedJSON

  @doc "One task, read-only, with its last comments, oldest first."
  def show(%{task: task, comments: comments, has_more: has_more}),
    do: %{data: detail(task, comments, has_more)}

  @doc "A comment just added."
  def comment(%{comment: comment}), do: %{data: TaskCommentJSON.comment(comment)}

  @doc "The result of a move to Backlog: the task's card, and whether it moved."
  def moved(%{result: %{task: task, moved: moved}}),
    do: %{data: %{moved: moved, task: BoardJSON.card(task)}}

  @doc """
  A task's detail. `task` needs its `:column` loaded; `comments` are
  `Kanban.Tasks.TaskComment` structs with their `:author`.
  """
  def detail(%Task{} = task, comments, has_more) do
    task
    |> Map.take([
      :id,
      :identifier,
      :title,
      :type,
      :priority,
      :status,
      :needs_review,
      :description,
      :acceptance_criteria,
      :created_via,
      :archived_at
    ])
    |> Map.merge(%{
      board_id: task.column.board_id,
      column: %{id: task.column.id, name: task.column.name},
      key_files: TaskNestedJSON.key_files(task),
      security_considerations: task.security_considerations || [],
      comments: Enum.map(comments, &TaskCommentJSON.comment/1),
      has_more_comments: has_more
    })
  end
end
