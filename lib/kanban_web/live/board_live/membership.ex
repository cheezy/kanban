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

  Whenever the members list is (re)loaded, `assign_member_cap/1` also stores
  `Boards.member_cap_status/1` under `:member_cap` (W2401). The cap helpers
  below only describe that status for the page; the cap itself is enforced by
  `Boards.add_user_to_board/4`, so a disabled form is never the guard.
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

  @doc """
  Stores the board's free-plan member cap status under `:member_cap`.

  Called wherever the members list loads, so the page never computes the
  status per render. The status comes from `Boards.member_cap_status/1`, which
  already folds in plan enforcement and whether the board is paid.
  """
  def assign_member_cap(socket) do
    assign(socket, :member_cap, Boards.member_cap_status(socket.assigns.board))
  end

  @doc """
  The "N of M people" line for a capped board, or `nil` when the board has no
  cap (a paid board, or plan enforcement off).
  """
  def member_cap_line(%{count: count, cap: cap}) when is_integer(cap) do
    gettext("%{count} of %{cap} people", count: count, cap: cap)
  end

  def member_cap_line(_status), do: nil

  @doc """
  The explanation shown once a capped board is at or over its cap, or `nil`
  while it still has room or has no cap. Grandfathered boards over the cap get
  the same explanation and no removal prompt.
  """
  def member_cap_explanation(%{cap: cap, reached?: true}) when is_integer(cap) do
    gettext("Free boards hold %{cap} people. To add more, move this board to a paid plan.",
      cap: cap
    )
  end

  def member_cap_explanation(_status), do: nil

  @doc """
  The flash shown when `Boards.add_user_to_board/4` refuses an add because the
  board is at its cap.
  """
  def member_cap_flash(%{cap: cap}) when is_integer(cap) do
    gettext("This board is full. Free boards hold %{cap} people.", cap: cap)
  end

  def member_cap_flash(_status), do: gettext("This board is full.")

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

    socket
    |> respond_to_add(board, Boards.add_user_to_board(board, user, access_atom, current_user))
  end

  defp respond_to_add(socket, board, {:ok, _board_user}) do
    {:noreply,
     socket
     |> assign(:board_users, Boards.list_board_users(board))
     |> assign_member_cap()
     |> assign(:searched_user, nil)
     |> assign(:search_email, "")
     |> put_flash(:info, gettext("User added successfully"))}
  end

  defp respond_to_add(socket, board, {:error, :member_cap_reached}) do
    # Reload the list too: another owner session may have filled the board,
    # and the count line should agree with the rows shown.
    socket =
      socket
      |> assign(:board_users, Boards.list_board_users(board))
      |> assign_member_cap()

    {:noreply, put_flash(socket, :error, member_cap_flash(socket.assigns.member_cap))}
  end

  defp respond_to_add(socket, _board, {:error, _changeset}) do
    {:noreply, put_flash(socket, :error, gettext("Failed to add user to board"))}
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
        respond_to_remove(socket, board, Boards.remove_user_from_board(board, user, current_user))
    end
  end

  defp respond_to_remove(socket, board, {:ok, _board_user}) do
    {:noreply,
     socket
     |> assign(:board_users, Boards.list_board_users(board))
     |> assign_member_cap()
     |> put_flash(:info, gettext("User removed successfully"))}
  end

  defp respond_to_remove(socket, _board, {:error, :owner_required}) do
    {:noreply, put_flash(socket, :error, gettext("The board owner can't be removed."))}
  end

  defp respond_to_remove(socket, _board, {:error, _reason}) do
    {:noreply, put_flash(socket, :error, gettext("Failed to remove user from board"))}
  end

  defp owner_authorized?(socket, current_user) do
    board = socket.assigns.board

    not is_nil(board.id) and Boards.owner?(board, current_user)
  end

  defp membership_denied_flash do
    gettext("Only the board owner can manage board membership")
  end
end
