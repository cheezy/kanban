defmodule KanbanWeb.BoardLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      user = socket.assigns.current_scope.user
      {:ok, stream(socket, :boards, Boards.list_boards(user))}
    else
      {:ok, stream(socket, :boards, [])}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, gettext("Boards"))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    {:ok, _} = Boards.delete_board(board)

    {:noreply, stream_delete(socket, :boards, board)}
  end
end
