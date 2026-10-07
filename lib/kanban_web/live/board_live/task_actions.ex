defmodule KanbanWeb.BoardLive.TaskActions do
  @moduledoc """
  Task event handlers for `KanbanWeb.BoardLive.Show`, extracted from the
  LiveView to keep it under the module-size guideline: drag-and-drop reorder
  and move, opening the task view, archive, delete, and promoting a goal's
  children to Ready. Socket-in, `{:noreply, socket}`-out. Authorization stays
  in the LiveView's `handle_event/3` clauses (via
  `KanbanWeb.BoardLive.Authorization`); these run only once it has passed.
  Flash strings are asserted in tests and shown to users — do not reword.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, stream: 3, stream: 4]

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.Show

  @doc false
  def handle_task_reorder(socket, column_id, task_id, new_position) do
    # IDs here were already board-scoped by authorize_move_task; the scoped
    # lookup is defense-in-depth in case this helper is ever called directly.
    case Columns.get_column_for_board(column_id, socket.assigns.board.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}

      column ->
        do_handle_task_reorder(socket, column, task_id, new_position)
    end
  end

  defp do_handle_task_reorder(socket, column, task_id, new_position) do
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
     |> BoardState.load_tasks_for_columns(columns)}
  end

  @doc false
  def handle_task_move(socket, task, new_column_id, new_position) do
    require Logger

    case Columns.get_column_for_board(new_column_id, socket.assigns.board.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}

      new_column ->
        Logger.info(
          "Attempting to move task #{task.id} to column #{new_column_id} at position #{new_position}"
        )

        do_handle_task_move(socket, task, new_column, new_position)
    end
  end

  defp do_handle_task_move(socket, task, new_column, new_position) do
    require Logger

    case Tasks.move_task(task, new_column, new_position) do
      {:ok, _task} ->
        handle_task_move_success(socket)

      {:error, :wip_limit_reached} ->
        handle_task_move_wip_limit(socket, new_column)

      {:error, reason} ->
        Logger.error("Task move failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, gettext("Failed to move task"))
        |> push_event("move_failed", %{})
        |> BoardState.reload_board_columns()
    end
  end

  defp handle_task_move_success(socket) do
    require Logger
    Logger.info("Task move succeeded")
    # The column structure itself does not change on a task move — only the
    # `@tasks_by_column` assign does. Skipping `stream(:columns, ..., reset: true)`
    # keeps the column parent DOM stable so morphdom only diffs the moved
    # task element inside its new column instead of tearing down and rebuilding
    # every column, which the user sees as a brief disappear/reappear flicker
    # right after the drop animation completes.
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("move_success", %{})
     |> BoardState.load_tasks_for_columns(columns)
     |> BoardState.refresh_board_metrics()}
  end

  defp handle_task_move_wip_limit(socket, new_column) do
    require Logger
    Logger.warning("Task move failed: WIP limit reached")
    # On error, we need to reload to revert the client-side change
    # Send wip_limit_violation event to trigger visual feedback on target column
    socket
    |> put_flash(:error, gettext("Cannot move task: column has reached its WIP limit"))
    |> push_event("wip_limit_violation", %{column_id: new_column.id})
    |> push_event("move_failed", %{})
    |> BoardState.reload_board_columns()
  end

  def do_promote_goal(socket, goal) do
    case Tasks.promote_goal_to_ready(goal, socket.assigns.board.id) do
      {:ok, count} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(
           :info,
           dngettext(
             "tasks",
             "Moved 1 task to Ready",
             "Moved %{count} tasks to Ready",
             count,
             count: count
           )
         )
         |> stream(:columns, columns, reset: true)
         |> BoardState.load_tasks_for_columns(columns)}

      {:error, :not_a_goal} ->
        {:noreply, put_flash(socket, :error, gettext("Only goals can be promoted"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move goal to Ready"))}
    end
  end

  def lookup_viewable_task(socket, id) do
    with {:ok, task_id} <- Show.parse_task_id(id),
         %{} = task <- Tasks.get_task_for_board(task_id, socket.assigns.board.id) do
      {:ok, %{id: task_id, type: task.type}}
    else
      _ -> :error
    end
  end

  def schedule_task_modal(socket, task_id) do
    require Logger
    Logger.debug("view_task event: task_id=#{task_id}, scheduling modal show")
    Process.send_after(self(), {:show_task_modal, task_id}, 100)
    {:noreply, assign(socket, viewing_task_id: task_id, show_task_modal: false)}
  end

  def reject_view_task(socket, id) do
    require Logger
    Logger.debug("view_task event: rejected client-supplied id=#{inspect(id)}")
    {:noreply, put_flash(socket, :error, gettext("Task not found"))}
  end

  def perform_task_archive(socket, task, id) do
    require Logger

    case Tasks.archive_task(task) do
      {:ok, _archived_task} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task archived successfully"))
         |> stream(:columns, columns, reset: true)
         |> BoardState.load_tasks_for_columns(columns)}

      {:error, changeset} ->
        Logger.error("Failed to archive task #{id}: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to archive task"))}
    end
  end

  def perform_task_delete(socket, task) do
    case Tasks.delete_task(task) do
      {:ok, _deleted_task} ->
        columns = Columns.list_columns(socket.assigns.board)

        Process.send_after(self(), :clear_skip_reload, 100)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted successfully"))
         |> assign(:skip_next_reload, true)
         |> stream(:columns, columns)
         |> BoardState.load_tasks_for_columns(columns)}

      {:error, :has_dependents} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot delete task: other tasks depend on it. Remove dependencies first.")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end
end
