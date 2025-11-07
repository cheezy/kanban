defmodule KanbanWeb.BoardLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id, "column_id" => column_id, "task_id" => task_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)
    task = Tasks.get_task!(task_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:column, column)
     |> assign(:task, task)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:column, column)
     |> assign(:column_id, column.id)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id, "task_id" => task_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)
    task = Tasks.get_task!(task_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:task, task)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  @impl true
  def handle_event("delete_column", %{"id" => id}, socket) do
    column = Columns.get_column!(id)

    case Columns.delete_column(column) do
      {:ok, _column} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Column deleted successfully"))
         |> assign(:has_columns, length(columns) > 0)
         |> stream_delete(:columns, column)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete column"))}
    end
  end

  @impl true
  def handle_event("delete_task", %{"id" => id}, socket) do
    task = Tasks.get_task!(id)

    case Tasks.delete_task(task) do
      {:ok, _task} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted successfully"))
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  @impl true
  def handle_info({KanbanWeb.ColumnLive.FormComponent, {:saved, _column}}, socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  def handle_info({KanbanWeb.TaskLive.FormComponent, {:saved, _task}}, socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp page_title(:show), do: "Show Board"
  defp page_title(:new_column), do: "New Column"
  defp page_title(:edit_column), do: "Edit Column"
  defp page_title(:new_task), do: "New Task"
  defp page_title(:edit_task), do: "Edit Task"

  defp load_tasks_for_columns(socket, columns) do
    # Load tasks for each column and store them in assigns
    tasks_by_column =
      Enum.into(columns, %{}, fn column ->
        {column.id, Tasks.list_tasks(column)}
      end)

    assign(socket, :tasks_by_column, tasks_by_column)
  end
end
