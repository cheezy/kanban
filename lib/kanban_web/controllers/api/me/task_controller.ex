defmodule KanbanWeb.API.Me.TaskController do
  @moduledoc """
  The app's task actions (W2760, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.1, §6.11, §7.10):

    * `GET /api/me/tasks/:id` returns one task, read-only: its title,
      description, acceptance criteria, key files, security considerations
      and its last 20 comments (`Kanban.Tasks.list_recent_comments/2`);
    * `POST /api/me/tasks/:id/comments` adds a comment through the web's
      comment path (`Kanban.Tasks.create_comment/4`), the Reply on a released
      card;
    * `POST /api/me/tasks/:id/move_to_backlog` moves a released task from
      Ready, or an expired claim from Doing, to the end of Backlog
      (`Kanban.Tasks.move_to_backlog/3`);
    * `POST /api/me/tasks` captures a work or defect task into a board's
      Backlog with `created_via: "mobile"` (`Kanban.Tasks.capture_task/3`).

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`.
  Every route is plan-gated with `:mobile_app` (design §10). The checks run
  in this order: the person's plan (403 `plan_required`); the task, or the
  capture's board, which the person must hold access to as on the web (404);
  write access, owner or modify, for a move or a capture (403 `Forbidden`),
  while any member, read-only included, may read and comment as on the web;
  and then the board's plan (403 `plan_required`), so a `plan_required`
  answer never reveals a task or board the person cannot see.

  A changeset error is answered in the device's language (its `locale`,
  resolved by `Kanban.Locales.resolve/1`), so the app can show it as it is;
  the app matches on the field and on `error` codes, never on message text.
  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Boards
  alias Kanban.Decisions
  alias Kanban.Plans
  alias Kanban.Tasks
  alias KanbanWeb.API.Me.CaptureParams
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  @recent_comments 20
  @write_access [:owner, :modify]

  def show(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, task, _board} <- task_for(scope, id, :read) do
      {comments, has_more} = Tasks.list_recent_comments(task, @recent_comments)
      render(conn, :show, task: task, comments: comments, has_more: has_more)
    end
  end

  def comment(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    result =
      with :ok <- check_user(scope),
           {:ok, task, _board} <- task_for(scope, id, :read),
           {:ok, comment} <- create_comment(conn, task) do
        conn
        |> put_status(:created)
        |> render(:comment, comment: %{comment | author: scope.user})
      end

    in_device_locale(result)
  end

  def move_to_backlog(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, task, board} <- task_for(scope, id, :write),
         {:ok, result} <- move_task_to_backlog(conn, board, task) do
      render(conn, :moved, result: result)
    end
  end

  def create(conn, _params) do
    %{current_scope: scope} = conn.assigns

    result =
      with :ok <- check_user(scope),
           {:ok, attrs} <- CaptureParams.cast(conn.body_params),
           {:ok, task} <- capture(scope, attrs) do
        conn
        |> put_status(:created)
        |> render(:show, task: task, comments: [], has_more: false)
      end

    in_device_locale(result)
  end

  defp capture(scope, attrs) do
    with {:ok, board} <- board_for(scope, attrs.board_id),
         do: Tasks.capture_task(scope, board, attrs)
  end

  # The task, then the access the action needs, then the board's plan, in
  # that order, so plan_required never confirms a task the person cannot see.
  defp task_for(scope, id, need) do
    with {:ok, task_id} <- parse_id(id),
         {:ok, task, board} <- Tasks.get_task_for_app(scope, task_id),
         :ok <- require_access(board, need),
         :ok <- check_board(board) do
      {:ok, task, board}
    end
  end

  # A capture's board: one the person holds access to, with write access,
  # then its plan. A public board they are not a member of is not one.
  defp board_for(scope, board_id) do
    with {:ok, %{user_access: access} = board} when not is_nil(access) <-
           Boards.get_board(board_id, scope.user),
         :ok <- require_access(board, :write),
         :ok <- check_board(board) do
      {:ok, board}
    else
      {:ok, _not_a_member} -> {:error, :not_found}
      error -> error
    end
  end

  # Only content is read from the body. A refusal the comment policy makes
  # after the lookup (the person removed from the board in between) is a 404,
  # as is a task deleted in between.
  #
  # A reply and a move to Backlog are a person's actions, counted as the
  # first action on any decision they resolve (Kanban.Decisions.acted_on/3).
  defp create_comment(conn, task) do
    %{current_scope: scope, current_device: device} = conn.assigns
    attrs = %{"content" => Map.get(conn.body_params, "content")}
    act = [action: :reply, via: device.platform, task_id: task.id]

    case Decisions.acted_on(scope, act, fn -> Tasks.create_comment(scope, task, attrs) end) do
      {:error, :unauthorized} -> {:error, :not_found}
      result -> result
    end
  end

  defp move_task_to_backlog(conn, board, task) do
    %{current_scope: scope, current_device: device} = conn.assigns

    act = [
      action: :move,
      via: device.platform,
      board_id: board.id,
      task_ids: [task.id],
      into_ready: false
    ]

    Decisions.acted_on(scope, act, fn -> Tasks.move_to_backlog(scope, board, task) end)
  end

  defp require_access(_board, :read), do: :ok
  defp require_access(%{user_access: access}, :write) when access in @write_access, do: :ok
  defp require_access(_board, :write), do: {:error, :forbidden}

  defp check_user(scope), do: Plans.check_user(scope, :mobile_app, surface: :controller)
  defp check_board(board), do: Plans.check_board(board, :mobile_app, surface: :controller)

  # A changeset is answered in the device's language.
  defp in_device_locale({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:in_device_locale, changeset}}

  defp in_device_locale(result), do: result

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :not_found}
    end
  end
end
