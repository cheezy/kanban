defmodule KanbanWeb.API.TaskCommentController do
  @moduledoc """
  `GET` and `POST /api/tasks/:id/comments`: read a task's comment thread and
  add to it with an API token.

  Both actions are thin wrappers over `KanbanWeb.API.TaskActions`, which the
  MCP `stride_add_comment` tool also calls, and errors render through
  `KanbanWeb.API.TaskErrors` so the bodies match the rest of the task API. The
  task is looked up on the token's board only, so another board's task is a
  404 on both verbs. The comment's author is always the token's user: the body
  is read for `content` and `agent_name` only.
  """

  use KanbanWeb, :controller

  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskErrors

  def index(conn, %{"id" => id_or_identifier} = params) do
    case TaskActions.list_comments(conn, id_or_identifier, params) do
      {:ok, template, assigns} -> render(conn, template, assigns)
      {:error, reason} -> TaskErrors.render_error(conn, reason)
    end
  end

  def create(conn, %{"id" => id_or_identifier} = params) do
    case TaskActions.add_comment(conn, id_or_identifier, params["content"], params["agent_name"]) do
      {:ok, comment} ->
        conn
        |> put_status(:created)
        |> render(:show, comment: comment)

      {:error, reason} ->
        TaskErrors.render_error(conn, reason)
    end
  end
end
