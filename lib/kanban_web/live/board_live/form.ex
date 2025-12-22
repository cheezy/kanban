defmodule KanbanWeb.BoardLive.Form do
  use KanbanWeb, :live_view

  alias Kanban.Accounts
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo

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
    board = Boards.get_board!(id, user)

    if Boards.owner?(board, user) do
      board_users = Boards.list_board_users(board)

      socket
      |> assign(:page_title, gettext("Edit Board"))
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

  def handle_event("search_user", %{"email" => email}, socket) do
    email = String.trim(email)

    case Accounts.get_user_by_email(email) do
      nil ->
        {:noreply,
         socket
         |> assign(:searched_user, nil)
         |> assign(:search_email, email)
         |> put_flash(:error, gettext("User not found with email: %{email}", email: email))}

      user ->
        current_user_id = socket.assigns.current_scope.user.id

        if user.id == current_user_id do
          {:noreply,
           socket
           |> assign(:searched_user, nil)
           |> assign(:search_email, email)
           |> put_flash(:error, gettext("You cannot add yourself to the board"))}
        else
          already_added? =
            Enum.any?(socket.assigns.board_users, fn %{user: u} -> u.id == user.id end)

          if already_added? do
            {:noreply,
             socket
             |> assign(:searched_user, nil)
             |> assign(:search_email, email)
             |> put_flash(:error, gettext("User is already added to the board"))}
          else
            {:noreply,
             socket
             |> assign(:searched_user, user)
             |> assign(:search_email, email)
             |> clear_flash()}
          end
        end
    end
  end

  def handle_event("add_user", %{"access" => access}, socket) do
    user = socket.assigns.searched_user
    board = socket.assigns.board
    access_atom = String.to_existing_atom(access)

    case Boards.add_user_to_board(board, user, access_atom) do
      {:ok, _board_user} ->
        board_users = Boards.list_board_users(board)

        {:noreply,
         socket
         |> assign(:board_users, board_users)
         |> assign(:searched_user, nil)
         |> assign(:search_email, "")
         |> put_flash(:info, gettext("User added successfully"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to add user to board"))}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    board = socket.assigns.board
    user_id = String.to_integer(user_id)

    case Repo.get(Accounts.User, user_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("User not found"))}

      user ->
        case Boards.remove_user_from_board(board, user) do
          {:ok, _board_user} ->
            board_users = Boards.list_board_users(board)

            {:noreply,
             socket
             |> assign(:board_users, board_users)
             |> put_flash(:info, gettext("User removed successfully"))}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Failed to remove user from board"))}
        end
    end
  end

  def handle_event("toggle_field", %{"field" => field_name}, socket) do
    board = socket.assigns.board
    current_visibility = socket.assigns.field_visibility

    new_visibility =
      Map.put(current_visibility, field_name, !Map.get(current_visibility, field_name, false))

    case Boards.update_field_visibility(
           board,
           new_visibility,
           socket.assigns.current_scope.user
         ) do
      {:ok, updated_board} ->
        {:noreply, assign(socket, :field_visibility, updated_board.field_visibility)}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only board owners can change field visibility"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update field visibility"))}
    end
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
