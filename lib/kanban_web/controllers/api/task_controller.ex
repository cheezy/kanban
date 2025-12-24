defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller

  alias Kanban.Columns
  alias Kanban.Tasks

  action_fallback KanbanWeb.API.FallbackController

  def index(conn, params) do
    board = conn.assigns.current_board

    column_id = params["column_id"]

    tasks = if column_id do
      column = Columns.get_column!(column_id)

      if column.board_id != board.id do
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Column does not belong to this board"})
      else
        Tasks.list_tasks(column)
      end
    else
      columns = Columns.list_columns(board)
      Enum.flat_map(columns, &Tasks.list_tasks/1)
    end

    emit_telemetry(conn, :task_listed, %{count: length(tasks)})

    render(conn, :index, tasks: tasks)
  end

  def show(conn, %{"id" => id}) do
    board = conn.assigns.current_board
    task = Tasks.get_task_for_view!(id)

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

  def update(conn, %{"id" => id, "task" => task_params}) do
    board = conn.assigns.current_board
    task = Tasks.get_task_for_view!(id)

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
