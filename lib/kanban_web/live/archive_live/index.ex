defmodule KanbanWeb.ArchiveLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks

  @impl true
  def mount(%{"id" => board_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        {:ok, assign_archive_state(socket, board, user)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Board not found"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  defp assign_archive_state(socket, board, user) do
    user_access = Boards.get_user_access(board.id, user.id)

    subscribe_to_board_updates(socket, board.id)

    archived_tasks = load_archived_tasks(board.id)

    socket
    |> assign(:page_title, "Stride")
    |> assign(:board, board)
    |> assign(:user_access, user_access)
    |> assign(:can_modify, user_access in [:owner, :modify])
    |> assign(:is_owner, user_access == :owner)
    |> assign(:has_archived_tasks, archived_tasks != [])
    |> stream(:archived_tasks, archived_tasks)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("unarchive", %{"id" => id}, socket) do
    case authorize_modify_for_archived(socket, id) do
      {:ok, task} ->
        perform_unarchive(socket, task)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to unarchive tasks on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unarchive task"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case authorize_modify_for_archived(socket, id) do
      {:ok, task} ->
        perform_delete(socket, task)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to delete tasks on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  defp perform_unarchive(socket, task) do
    case Tasks.unarchive_task(task) do
      {:ok, _task} ->
        archived_tasks = load_archived_tasks(socket.assigns.board.id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task unarchived successfully"))
         |> assign(:has_archived_tasks, archived_tasks != [])
         |> stream(:archived_tasks, archived_tasks, reset: true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unarchive task"))}
    end
  end

  defp perform_delete(socket, task) do
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

  defp load_archived_tasks(board_id) do
    board_id
    |> Tasks.list_archived_tasks_for_board()
    |> Tasks.sort_by_goal_hierarchy()
  end

  defp authorize_modify_for_archived(socket, raw_id) do
    if socket.assigns.can_modify do
      lookup_archived_task(socket, raw_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_archived_task(socket, raw_id) do
    with {:ok, id} <- parse_id(raw_id),
         %{} = task <- Tasks.get_archived_task_for_board(id, socket.assigns.board.id) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end
end
