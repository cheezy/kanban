defmodule KanbanWeb.BoardLive.MembersFormComponent do
  @moduledoc """
  Modal-friendly board members manager. Lets the board owner search
  for a registered user by email, add them with read-only or modify
  access, and remove existing non-owner members. Mounted as a
  `live_component` from `KanbanWeb.BoardLive.Show` when the
  `:manage_members` live action is active.
  """
  use KanbanWeb, :live_component

  alias Kanban.Accounts
  alias Kanban.Boards
  alias Kanban.Repo

  @impl true
  def update(%{board: board, current_scope: scope} = assigns, socket) do
    board_users = Boards.list_board_users(board)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:scope, scope)
     |> assign(:board_users, board_users)
     |> assign_new(:searched_user, fn -> nil end)
     |> assign_new(:search_email, fn -> "" end)}
  end

  @impl true
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

  defp respond_user_not_found(socket, email) do
    {:noreply,
     socket
     |> assign(:searched_user, nil)
     |> assign(:search_email, email)
     |> put_flash(:error, gettext("Could not find a user with that email address"))}
  end

  defp evaluate_searched_user(socket, user, email) do
    cond do
      user.id == socket.assigns.scope.user.id ->
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

  defp do_add_user(socket, access) do
    user = socket.assigns.searched_user
    board = socket.assigns.board
    access_atom = String.to_existing_atom(access)

    case Boards.add_user_to_board(board, user, access_atom, socket.assigns.scope.user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:board_users, Boards.list_board_users(board))
         |> assign(:searched_user, nil)
         |> assign(:search_email, "")
         |> put_flash(:info, gettext("User added successfully"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add user to board"))}
    end
  end

  defp do_remove_user(socket, user_id) do
    board = socket.assigns.board
    user_id = String.to_integer(user_id)

    case Repo.get(Accounts.User, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("User not found"))}

      user ->
        case Boards.remove_user_from_board(board, user, socket.assigns.scope.user) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:board_users, Boards.list_board_users(board))
             |> put_flash(:info, gettext("User removed successfully"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove user from board"))}
        end
    end
  end

  defp owner_authorized?(socket) do
    board = socket.assigns.board
    user = socket.assigns.scope.user
    not is_nil(board.id) and Boards.owner?(board, user)
  end

  defp membership_denied_flash, do: gettext("Only the board owner can manage board membership")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="stride-screen">
      <p style="margin: 0 0 14px; font-size: 12.5px; color: var(--ink-3); line-height: 1.5;">
        {gettext("Users must be already registered in the system in order to be added to Boards.")}
      </p>

      <section style={[
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;"
      ]}>
        <div class="ucase" style="font-size: 10.5px; color: var(--ink-3); margin-bottom: 6px;">
          {gettext("Add user by email")}
        </div>
        <form
          phx-submit="search_user"
          phx-target={@myself}
          style="display: flex; align-items: center; gap: 8px;"
        >
          <input
            type="email"
            name="email"
            id={"members-search-email-#{@board.id}"}
            value={@search_email}
            placeholder={gettext("name@example.com")}
            style={[
              "flex: 1; height: 32px; padding: 0 10px;",
              "border-radius: 5px; border: 1px solid var(--line-strong);",
              "background: var(--surface); color: var(--ink);",
              "font-size: 12.5px; font-family: var(--font-mono);"
            ]}
          />
          <button
            type="submit"
            style={[
              "height: 32px; padding: 0 12px; border-radius: 5px; border: none;",
              "background: var(--ink); color: var(--color-primary-content);",
              "font-size: 12px; font-weight: 500; cursor: pointer;",
              "box-shadow: 0 1px 0 rgba(0,0,0,.1) inset, 0 1px 2px rgba(0,0,0,.2);"
            ]}
          >
            {gettext("Search")}
          </button>
        </form>
      </section>

      <section
        :if={@searched_user}
        style={[
          "background: var(--stride-orange-soft); color: var(--stride-orange-ink);",
          "border: 1px solid var(--line); border-radius: 10px;",
          "padding: 14px 16px; margin-bottom: 14px;"
        ]}
      >
        <div style="margin-bottom: 10px;">
          <div style="font-size: 13px; font-weight: 600; color: var(--ink); letter-spacing: -0.005em;">
            {@searched_user.name}
          </div>
          <div style="font-size: 11.5px; color: var(--ink-3); font-family: var(--font-mono); margin-top: 2px;">
            {@searched_user.email}
          </div>
        </div>
        <div style="display: flex; gap: 8px;">
          <button
            type="button"
            phx-click="add_user"
            phx-value-access="read_only"
            phx-target={@myself}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              "background: transparent; color: var(--ink-2);",
              "border: 1px solid var(--line-strong);",
              "font-size: 12px; font-weight: 500; cursor: pointer;"
            ]}
          >
            {gettext("Add as Read Only")}
          </button>
          <button
            type="button"
            phx-click="add_user"
            phx-value-access="modify"
            phx-target={@myself}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              "background: var(--ink); color: var(--color-primary-content); border: none;",
              "font-size: 12px; font-weight: 500; cursor: pointer;",
              "box-shadow: 0 1px 0 rgba(0,0,0,.1) inset, 0 1px 2px rgba(0,0,0,.2);"
            ]}
          >
            {gettext("Add with Edit Access")}
          </button>
        </div>
      </section>

      <section :if={@board_users != []}>
        <div
          class="ucase"
          style="font-size: 10.5px; color: var(--ink-3); margin-bottom: 8px;"
        >
          {gettext("Current users")}
        </div>
        <div style="display: flex; flex-direction: column; gap: 6px;">
          <div
            :for={%{user: user, access: access} <- @board_users}
            style={[
              "display: flex; align-items: center; gap: 10px;",
              "padding: 10px 12px; border-radius: 8px;",
              "background: var(--surface); border: 1px solid var(--line);"
            ]}
          >
            <div style="flex: 1; min-width: 0;">
              <div style="font-size: 13px; font-weight: 500; color: var(--ink); letter-spacing: -0.005em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                {user.name}
              </div>
              <div style="font-size: 11.5px; color: var(--ink-3); font-family: var(--font-mono); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                {user.email}
              </div>
            </div>

            <span
              class="ucase"
              style={[
                "padding: 2px 8px; border-radius: 999px;",
                "font-size: 9.5px; letter-spacing: 0.04em; font-weight: 600;",
                "background: #{access_chip_bg(access)};",
                "color: #{access_chip_ink(access)};"
              ]}
            >
              {access_label(access)}
            </span>

            <button
              :if={access != :owner}
              type="button"
              phx-click="remove_user"
              phx-value-user_id={user.id}
              phx-target={@myself}
              style={[
                "padding: 4px 8px; border-radius: 4px;",
                "background: transparent; border: none; cursor: pointer;",
                "font-size: 11.5px; font-weight: 500; color: var(--st-blocked);"
              ]}
            >
              {gettext("Remove")}
            </button>
          </div>
        </div>
      </section>

      <div style="margin-top: 18px; display: flex; justify-content: flex-end;">
        <.link
          patch={@patch}
          style="font-size: 12.5px; color: var(--ink-2); text-decoration: underline; text-underline-offset: 2px;"
        >
          {gettext("Close")}
        </.link>
      </div>
    </div>
    """
  end

  defp access_chip_bg(:owner), do: "var(--stride-violet-soft)"
  defp access_chip_bg(:modify), do: "var(--st-doing-soft)"
  defp access_chip_bg(:read_only), do: "var(--surface-sunken)"
  defp access_chip_bg(_), do: "var(--surface-sunken)"

  defp access_chip_ink(:owner), do: "var(--stride-violet-ink)"
  defp access_chip_ink(:modify), do: "var(--st-doing)"
  defp access_chip_ink(:read_only), do: "var(--ink-3)"
  defp access_chip_ink(_), do: "var(--ink-3)"

  defp access_label(:owner), do: gettext("Owner")
  defp access_label(:modify), do: gettext("Can Edit")
  defp access_label(:read_only), do: gettext("Read Only")
  defp access_label(_), do: ""
end
