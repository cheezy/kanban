defmodule KanbanWeb.ArchiveLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks

  @impl true
  def mount(%{"id" => board_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(board_id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    subscribe_to_board_updates(socket, board.id)

    archived_tasks = Tasks.list_archived_tasks_for_board(board.id)

    {:ok,
     socket
     |> assign(:page_title, "Stride - Task Management")
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:has_archived_tasks, archived_tasks != [])
     |> stream(:archived_tasks, archived_tasks)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("unarchive", %{"id" => id}, socket) do
    case Kanban.Repo.get(Kanban.Tasks.Task, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unarchive task"))}

      task ->
        case Tasks.unarchive_task(task) do
          {:ok, _task} ->
            archived_tasks = Tasks.list_archived_tasks_for_board(socket.assigns.board.id)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Task unarchived successfully"))
             |> assign(:has_archived_tasks, archived_tasks != [])
             |> stream(:archived_tasks, archived_tasks, reset: true)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to unarchive task"))}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Kanban.Repo.get(Kanban.Tasks.Task, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}

      task ->
        case Tasks.delete_task(task) do
          {:ok, _task} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Task deleted successfully"))
             |> stream_delete(:archived_tasks, task)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
        end
    end
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_updated, _task}, socket) do
    archived_tasks = Tasks.list_archived_tasks_for_board(socket.assigns.board.id)

    {:noreply,
     socket
     |> assign(:has_archived_tasks, archived_tasks != [])
     |> stream(:archived_tasks, archived_tasks, reset: true)}
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_deleted, _task}, socket) do
    archived_tasks = Tasks.list_archived_tasks_for_board(socket.assigns.board.id)

    {:noreply,
     socket
     |> assign(:has_archived_tasks, archived_tasks != [])
     |> stream(:archived_tasks, archived_tasks, reset: true)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end
end
