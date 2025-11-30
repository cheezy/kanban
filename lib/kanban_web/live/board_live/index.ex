defmodule KanbanWeb.BoardLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    boards = Boards.list_boards(user)

    {:ok,
     socket
     |> assign(:has_boards, length(boards) > 0)
     |> stream(:boards, boards)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, gettext("Boards"))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)

    if Boards.owner?(board, user) do
      {:ok, _} = Boards.delete_board(board)
      boards = Boards.list_boards(user)

      {:noreply,
       socket
       |> assign(:has_boards, length(boards) > 0)
       |> stream_delete(:boards, board)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the board owner can delete this board"))
       |> push_navigate(to: ~p"/boards")}
    end
  end
end
