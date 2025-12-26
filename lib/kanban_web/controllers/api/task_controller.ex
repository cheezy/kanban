defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller

  alias Kanban.Columns
  alias Kanban.Tasks

  action_fallback KanbanWeb.API.FallbackController

  def index(conn, params) do
    board = conn.assigns.current_board

    column_id = params["column_id"]

    if column_id do
      column = Columns.get_column!(column_id)

      if column.board_id != board.id do
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Column does not belong to this board"})
      else
        tasks = Tasks.list_tasks(column)
        emit_telemetry(conn, :task_listed, %{count: length(tasks)})
        render(conn, :index, tasks: tasks)
      end
    else
      columns = Columns.list_columns(board)
      tasks = Enum.flat_map(columns, &Tasks.list_tasks/1)
      emit_telemetry(conn, :task_listed, %{count: length(tasks)})
      render(conn, :index, tasks: tasks)
    end
  end

  def show(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      render(conn, :show, task: task)
    end
  end

  def create(conn, %{"task" => task_params}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    column_id = task_params["column_id"] || get_default_column_id(board)
    column = Columns.get_column!(column_id)

    if column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Column does not belong to this board"})
    else
      task_params_with_creator =
        task_params
        |> Map.put("created_by_id", user.id)
        |> Map.delete("column_id")

      case Tasks.create_task(column, task_params_with_creator) do
        {:ok, task} ->
          task = Tasks.get_task_for_view!(task.id)
          emit_telemetry(conn, :task_created, %{task_id: task.id})

          conn
          |> put_status(:created)
          |> put_resp_header("location", ~p"/api/tasks/#{task}")
          |> render(:show, task: task)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  def update(conn, %{"id" => id_or_identifier, "task" => task_params}) do
    board = conn.assigns.current_board
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.update_task(task, task_params) do
        {:ok, task} ->
          task = Tasks.get_task_for_view!(task.id)
          emit_telemetry(conn, :task_updated, %{task_id: task.id})
          render(conn, :show, task: task)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  def next(conn, _params) do
    board = conn.assigns.current_board
    api_token = conn.assigns.api_token
    agent_capabilities = api_token.agent_capabilities || []

    case Tasks.get_next_task(agent_capabilities, board.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No tasks available in Ready column matching your capabilities"})

      task ->
        emit_telemetry(conn, :next_task_fetched, %{task_id: task.id, priority: task.priority})
        render(conn, :show, task: task)
    end
  end

  def claim(conn, params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    agent_capabilities = api_token.agent_capabilities || []
    task_identifier = params["identifier"]

    case Tasks.claim_next_task(agent_capabilities, user, board.id, task_identifier) do
      {:ok, task} ->
        emit_telemetry(conn, :task_claimed, %{
          task_id: task.id,
          priority: task.priority,
          api_token_id: api_token.id,
          specific_task: !!task_identifier
        })

        render(conn, :show, task: task)

      {:error, :no_tasks_available} ->
        error_message =
          if task_identifier do
            "Task '#{task_identifier}' is not available to claim. It may be blocked by dependencies, already claimed, require capabilities you don't have, or not exist on this board."
          else
            "No tasks available to claim matching your capabilities. All tasks in Ready column are either blocked, already claimed, or require capabilities you don't have."
          end

        conn
        |> put_status(:conflict)
        |> json(%{error: error_message})
    end
  end

  def complete(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.complete_task(task, user, params) do
        {:ok, task} ->
          emit_telemetry(conn, :task_completed, %{
            task_id: task.id,
            time_spent_minutes: task.time_spent_minutes
          })

          render(conn, :show, task: task)

        {:error, :invalid_status} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Task must be in progress or blocked to complete"})

        {:error, :not_authorized} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "You can only complete tasks that you are assigned to"})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  def unclaim(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)
    reason = params["reason"]

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.unclaim_task(task, user, reason) do
        {:ok, task} ->
          emit_telemetry(conn, :task_unclaimed, %{task_id: task.id, reason: reason})
          render(conn, :show, task: task)

        {:error, :not_authorized} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "You can only unclaim tasks that you claimed"})

        {:error, :not_claimed} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Task is not currently claimed"})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  defp get_task_by_id_or_identifier!(id_or_identifier, board) do
    case Integer.parse(id_or_identifier) do
      {id, ""} ->
        # It's a numeric ID
        Tasks.get_task_for_view!(id)

      _ ->
        # It's an identifier like "W14"
        columns = Columns.list_columns(board)
        column_ids = Enum.map(columns, & &1.id)

        Tasks.get_task_by_identifier_for_view!(id_or_identifier, column_ids)
    end
  end

  defp get_default_column_id(board) do
    columns = Columns.list_columns(board)

    backlog = Enum.find(columns, fn col -> col.name == "Backlog" end)
    ready = Enum.find(columns, fn col -> col.name == "Ready" end)

    cond do
      backlog -> backlog.id
      ready -> ready.id
      true -> List.first(columns).id
    end
  end

  defp emit_telemetry(conn, event_name, metadata) do
    :telemetry.execute(
      [:kanban, :api, event_name],
      %{count: 1},
      Map.merge(metadata, %{
        board_id: conn.assigns.current_board.id,
        user_id: conn.assigns.current_user.id,
        path: conn.request_path,
        method: conn.method
      })
    )
  end
end
