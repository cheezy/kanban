defmodule KanbanWeb.BoardLive.Form do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Boards.Board

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)

    socket
    |> assign(:page_title, gettext("Edit Board"))
    |> assign(:board, board)
    |> assign(:form, to_form(Boards.change_board(board)))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("New Board"))
    |> assign(:board, %Board{})
    |> assign(:form, to_form(Boards.change_board(%Board{})))
  end

  @impl true
  def handle_event("validate", %{"board" => board_params}, socket) do
    changeset = Boards.change_board(socket.assigns.board, board_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"board" => board_params}, socket) do
    save_board(socket, socket.assigns.live_action, board_params)
  end

  defp save_board(socket, :edit, board_params) do
    case Boards.update_board(socket.assigns.board, board_params) do
      {:ok, _board} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Board updated successfully"))
         |> push_navigate(to: ~p"/boards")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_board(socket, :new, board_params) do
    user = socket.assigns.current_scope.user

    case Boards.create_board(user, board_params) do
      {:ok, _board} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Board created successfully"))
         |> push_navigate(to: ~p"/boards")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
