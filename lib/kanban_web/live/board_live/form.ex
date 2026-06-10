defmodule KanbanWeb.BoardLive.Form do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias KanbanWeb.BoardLive.FieldVisibility
  alias KanbanWeb.BoardLive.Membership

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, search_email: "", searched_user: nil, board_users: [])
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(id, user) do
      {:ok, board} -> apply_edit_action(socket, board, user)
      {:error, :not_found} -> board_not_found(socket)
    end
  end

  defp apply_action(socket, :new, params) do
    ai_optimized = Map.get(params, "ai_optimized") == "true"

    socket
    |> assign(:page_title, "Stride")
    |> assign(:board, %Board{})
    |> assign(:ai_optimized, ai_optimized)
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

  def handle_event("search_user", %{"email" => email}, socket) do
    Membership.search_user(socket, socket.assigns.current_scope.user, email)
  end

  def handle_event("add_user", %{"access" => access}, socket) do
    Membership.add_user(socket, socket.assigns.current_scope.user, access)
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    Membership.remove_user(socket, socket.assigns.current_scope.user, user_id)
  end

  def handle_event("toggle_field", %{"field" => field_name} = _params, socket) do
    FieldVisibility.toggle_field(socket, socket.assigns.current_scope.user, field_name)
  end

  defp save_board(socket, :edit, board_params) do
    case Boards.update_board(
           socket.assigns.board,
           board_params,
           socket.assigns.current_scope.user
         ) do
      {:ok, board} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Board updated successfully"))
         |> push_navigate(to: ~p"/boards/#{board}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_board(socket, :new, board_params) do
    user = socket.assigns.current_scope.user
    ai_optimized = Map.get(socket.assigns, :ai_optimized, false)

    result =
      if ai_optimized do
        Boards.create_ai_optimized_board(user, board_params)
      else
        Boards.create_board(user, board_params)
      end

    case result do
      {:ok, board} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Board created successfully"))
         |> push_navigate(to: ~p"/boards/#{board}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp apply_edit_action(socket, board, user) do
    if Boards.owner?(board, user) do
      board_users = Boards.list_board_users(board)

      socket
      |> assign(:page_title, "Stride")
      |> assign(:board, board)
      |> assign(:board_users, board_users)
      |> assign(:field_visibility, board.field_visibility || %{})
      |> assign(:form, to_form(Boards.change_board(board)))
    else
      socket
      |> put_flash(:error, gettext("Only the board owner can edit this board"))
      |> push_navigate(to: ~p"/boards")
    end
  end

  defp board_not_found(socket) do
    socket
    |> put_flash(:error, gettext("Board not found"))
    |> push_navigate(to: ~p"/boards")
  end
end
