defmodule KanbanWeb.BoardLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    boards = Boards.list_boards(user)

    {:ok,
     socket
     |> assign(:has_boards, not Enum.empty?(boards))
     |> stream(:boards, boards)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Stride")}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(id, user) do
      {:ok, board} -> attempt_board_deletion(socket, board, user)
      {:error, :not_found} -> board_not_found_response(socket)
    end
  end

  defp attempt_board_deletion(socket, board, user) do
    case Boards.delete_board(board, user) do
      {:ok, _} ->
        boards = Boards.list_boards(user)

        {:noreply,
         socket
         |> assign(:has_boards, not Enum.empty?(boards))
         |> stream_delete(:boards, board)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Only the board owner can delete this board"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  defp board_not_found_response(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Board not found"))
     |> push_navigate(to: ~p"/boards")}
  end
end
