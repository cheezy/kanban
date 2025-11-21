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
    user_access = Boards.get_user_access(board.id, user.id)
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)
    task = Tasks.get_task!(task_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:column, column)
     |> assign(:task, task)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    if socket.assigns.live_action in [:new_column, :edit_column] and user_access != :owner do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the board owner can manage columns"))
       |> push_patch(to: ~p"/boards/#{board}")}
    else
      columns = Columns.list_columns(board)
      column = Columns.get_column!(column_id)

      {:noreply,
       socket
       |> assign(:page_title, page_title(socket.assigns.live_action))
       |> assign(:board, board)
       |> assign(:user_access, user_access)
       |> assign(:can_modify, user_access in [:owner, :modify])
       |> assign(:column, column)
       |> assign(:column_id, column.id)
       |> assign(:has_columns, length(columns) > 0)
       |> stream(:columns, columns)
       |> load_tasks_for_columns(columns)}
    end
  end

  def handle_params(%{"id" => id, "task_id" => task_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)
    columns = Columns.list_columns(board)
    task = Tasks.get_task!(task_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:task, task)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    if socket.assigns.live_action == :new_column and user_access != :owner do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the board owner can create columns"))
       |> push_patch(to: ~p"/boards/#{board}")}
    else
      columns = Columns.list_columns(board)

      {:noreply,
       socket
       |> assign(:page_title, page_title(socket.assigns.live_action))
       |> assign(:board, board)
       |> assign(:user_access, user_access)
       |> assign(:can_modify, user_access in [:owner, :modify])
       |> assign(:has_columns, length(columns) > 0)
       |> stream(:columns, columns)
       |> load_tasks_for_columns(columns)}
    end
  end

  @impl true
  def handle_event("delete_column", %{"id" => id}, socket) do
    if socket.assigns.user_access != :owner do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the board owner can delete columns"))}
    else
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
  def handle_event(
        "move_task",
        %{
          "task_id" => task_id,
          "old_column_id" => old_column_id,
          "new_column_id" => new_column_id,
          "new_position" => new_position
        },
        socket
      ) do
    require Logger

    task_id = String.to_integer(task_id)
    old_column_id = String.to_integer(old_column_id)
    new_column_id = String.to_integer(new_column_id)

    Logger.info(
      "Move task event: task_id=#{task_id}, old_column=#{old_column_id}, new_column=#{new_column_id}, new_position=#{new_position}"
    )

    task = Tasks.get_task!(task_id)

    # If moving within the same column, just reorder
    if old_column_id == new_column_id do
      handle_task_reorder(socket, old_column_id, task_id, new_position)
    else
      handle_task_move(socket, task, new_column_id, new_position)
    end
  end

  @impl true
  def handle_event("move_column", %{"column_id" => column_id, "column_ids" => column_ids}, socket) do
    if socket.assigns.user_access != :owner do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the board owner can reorder columns"))}
    else
      require Logger

      column_ids = Enum.map(column_ids, &String.to_integer/1)

      Logger.info("Move column event: column_id=#{column_id}, new_order=#{inspect(column_ids)}")

      Columns.reorder_columns(socket.assigns.board, column_ids)

      columns = Columns.list_columns(socket.assigns.board)

      {:noreply,
       socket
       |> push_event("move_column_success", %{})
       |> stream(:columns, columns, reset: true)
       |> load_tasks_for_columns(columns)}
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
    # Reload columns with full reset since we need to update task lists
    # This is necessary when tasks are added/edited via the modal
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp handle_task_reorder(socket, column_id, task_id, new_position) do
    column = Columns.get_column!(column_id)
    tasks = Tasks.list_tasks(column)

    # Get the current order of task IDs
    current_order = Enum.map(tasks, & &1.id)

    # Remove the task from its current position and insert it at the new position
    new_order =
      current_order
      |> List.delete(task_id)
      |> List.insert_at(new_position, task_id)

    # Persist the change to database
    Tasks.reorder_tasks(column, new_order)

    # Send success event FIRST to clear pendingMove flag, then reload tasks
    # Reset the stream so LiveView re-renders columns with updated task counts
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("move_success", %{})
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp handle_task_move(socket, task, new_column_id, new_position) do
    require Logger
    new_column = Columns.get_column!(new_column_id)

    Logger.info(
      "Attempting to move task #{task.id} to column #{new_column_id} at position #{new_position}"
    )

    case Tasks.move_task(task, new_column, new_position) do
      {:ok, _task} ->
        Logger.info("Task move succeeded")
        # Send success event FIRST to clear pendingMove flag, then reload tasks
        # Reset the stream so LiveView re-renders columns with updated task counts
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> push_event("move_success", %{})
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, :wip_limit_reached} ->
        Logger.warning("Task move failed: WIP limit reached")
        # On error, we need to reload to revert the client-side change
        # Send wip_limit_violation event to trigger visual feedback on target column
        socket
        |> put_flash(:error, gettext("Cannot move task: column has reached its WIP limit"))
        |> push_event("wip_limit_violation", %{column_id: new_column_id})
        |> push_event("move_failed", %{})
        |> reload_board_columns()

      {:error, reason} ->
        Logger.error("Task move failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, gettext("Failed to move task"))
        |> push_event("move_failed", %{})
        |> reload_board_columns()
    end
  end

  defp reload_board_columns(socket) do
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
