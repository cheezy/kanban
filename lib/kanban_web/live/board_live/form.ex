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
    email = String.trim(email)

    case Accounts.get_user_by_email(email) do
      nil -> respond_user_not_found(socket, email)
      user -> evaluate_searched_user(socket, user, email)
    end
  end

  def handle_event("add_user", %{"access" => access}, socket) do
    if owner_authorized?(socket) do
      do_add_user(socket, access)
    else
      {:noreply, put_flash(socket, :error, membership_denied_flash())}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    if owner_authorized?(socket) do
      do_remove_user(socket, user_id)
    else
      {:noreply, put_flash(socket, :error, membership_denied_flash())}
    end
  end

  def handle_event("toggle_field", %{"field" => field_name} = _params, socket) do
    # W401: reject any client-supplied "field" name that is not on the
    # canonical allow-list before it lands in the JSONB map.
    if field_name in Board.toggleable_fields() do
      perform_toggle(socket, field_name)
    else
      {:noreply, put_flash(socket, :error, gettext("Invalid field name"))}
    end
  end

  defp respond_user_not_found(socket, email) do
    {:noreply,
     socket
     |> assign(:searched_user, nil)
     |> assign(:search_email, email)
     |> put_flash(:error, gettext("Could not find a user with that email address"))}
  end

  defp evaluate_searched_user(socket, user, email) do
    cond do
      user.id == socket.assigns.current_scope.user.id ->
        reject_searched_user(socket, email, gettext("You cannot add yourself to the board"))

      user_already_in_board?(socket, user) ->
        reject_searched_user(socket, email, gettext("User is already added to the board"))

      true ->
        {:noreply,
         socket
         |> assign(:searched_user, user)
         |> assign(:search_email, email)
         |> clear_flash()}
    end
  end

  defp user_already_in_board?(socket, user) do
    Enum.any?(socket.assigns.board_users, fn %{user: u} -> u.id == user.id end)
  end

  defp reject_searched_user(socket, email, message) do
    {:noreply,
     socket
     |> assign(:searched_user, nil)
     |> assign(:search_email, email)
     |> put_flash(:error, message)}
  end

  defp perform_toggle(socket, field_name) do
    board = socket.assigns.board
    new_visibility = build_toggled_visibility(socket.assigns.field_visibility, field_name)

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

  defp build_toggled_visibility(current_visibility, field_name) do
    # Build a complete visibility map (all allow-listed keys present with their
    # current value or false default) so we always pass a fully-populated map
    # into the changeset, then flip the toggled field.
    default_visibility = Map.new(Board.toggleable_fields(), fn key -> {key, false} end)
    complete_visibility = Map.merge(default_visibility, current_visibility)

    Map.put(complete_visibility, field_name, !Map.get(complete_visibility, field_name, false))
  end

  defp do_add_user(socket, access) do
    user = socket.assigns.searched_user
    board = socket.assigns.board
    access_atom = String.to_existing_atom(access)

    case Boards.add_user_to_board(board, user, access_atom, socket.assigns.current_scope.user) do
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

  defp do_remove_user(socket, user_id) do
    board = socket.assigns.board
    user_id = String.to_integer(user_id)

    case Repo.get(Accounts.User, user_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("User not found"))}

      user ->
        case Boards.remove_user_from_board(board, user, socket.assigns.current_scope.user) do
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

  defp owner_authorized?(socket) do
    board = socket.assigns.board
    current_user = socket.assigns.current_scope.user

    not is_nil(board.id) and Boards.owner?(board, current_user)
  end

  defp membership_denied_flash do
    gettext("Only the board owner can manage board membership")
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
