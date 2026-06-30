defmodule KanbanWeb.BoardLive.Membership do
  @moduledoc """
  Shared board-membership flows — search a user by email, add them to the
  board, remove them, all gated on board ownership — used by
  `KanbanWeb.BoardLive.Form` and `KanbanWeb.BoardLive.MembersFormComponent`.

  Functions take the socket plus the current user as an explicit argument
  (the two callers store the user under different assign keys) and require
  the socket assigns `:board`, `:board_users`, `:searched_user`, and
  `:search_email`. Only `assign/3`, `put_flash/3`, and `clear_flash/1` are
  used, so the functions work on both LiveView and LiveComponent sockets.
  """
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1]

  alias Kanban.Accounts
  alias Kanban.Boards

  @doc """
  Looks up a registered user by email and stages them as `:searched_user`,
  rejecting self-adds and existing members with the same flash messages as
  before extraction.
  """
  def search_user(socket, current_user, email) do
    if owner_authorized?(socket, current_user) do
      do_search_user(socket, current_user, email)
    else
      # Without this gate a non-owner board member (even :read_only) could probe
      # arbitrary emails via Accounts.get_user_by_email/1 and learn whether an
      # account exists plus its display name — account enumeration (W1434).
      {:noreply, put_flash(socket, :error, membership_denied_flash())}
    end
  end

  defp do_search_user(socket, current_user, email) do
    email = String.trim(email)

    case Accounts.get_user_by_email(email) do
      nil -> respond_user_not_found(socket, email)
      user -> evaluate_searched_user(socket, current_user, user, email)
    end
  end

  @doc """
  Adds the staged `:searched_user` to the board with the given access level.
  Denied with a flash unless `current_user` owns the board.
  """
  def add_user(socket, current_user, access) do
    if owner_authorized?(socket, current_user) do
      do_add_user(socket, current_user, access)
    else
      {:noreply, put_flash(socket, :error, membership_denied_flash())}
    end
  end

  @doc """
  Removes the user with the given id from the board. Denied with a flash
  unless `current_user` owns the board.
  """
  def remove_user(socket, current_user, user_id) do
    if owner_authorized?(socket, current_user) do
      do_remove_user(socket, current_user, user_id)
    else
      {:noreply, put_flash(socket, :error, membership_denied_flash())}
    end
  end

  defp respond_user_not_found(socket, email) do
    {:noreply,
     socket
     |> assign(:searched_user, nil)
     |> assign(:search_email, email)
     |> put_flash(:error, gettext("Could not find a user with that email address"))}
  end

  defp evaluate_searched_user(socket, current_user, user, email) do
    cond do
      user.id == current_user.id ->
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

  defp do_add_user(socket, current_user, access) do
    user = socket.assigns.searched_user
    board = socket.assigns.board
    access_atom = String.to_existing_atom(access)

    case Boards.add_user_to_board(board, user, access_atom, current_user) do
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

  defp do_remove_user(socket, current_user, user_id) do
    board = socket.assigns.board
    user_id = String.to_integer(user_id)

    case Accounts.get_user(user_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("User not found"))}

      user ->
        case Boards.remove_user_from_board(board, user, current_user) do
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

  defp owner_authorized?(socket, current_user) do
    board = socket.assigns.board

    not is_nil(board.id) and Boards.owner?(board, current_user)
  end

  defp membership_denied_flash do
    gettext("Only the board owner can manage board membership")
  end
end
