defmodule KanbanWeb.BoardLive.MembersFormComponent do
  @moduledoc """
  Modal-friendly board members manager. Lets the board owner search
  for a registered user by email, add them with read-only or modify
  access, and remove existing non-owner members. Mounted as a
  `live_component` from `KanbanWeb.BoardLive.Show` when the
  `:manage_members` live action is active.
  """
  use KanbanWeb, :live_component

  alias Kanban.Boards
  alias KanbanWeb.BoardLive.Membership

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
    Membership.search_user(socket, socket.assigns.scope.user, email)
  end

  def handle_event("add_user", %{"access" => access}, socket) do
    Membership.add_user(socket, socket.assigns.scope.user, access)
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    Membership.remove_user(socket, socket.assigns.scope.user, user_id)
  end

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
              "background: var(--ink); color: var(--color-base-100);",
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
              "background: var(--ink); color: var(--color-base-100); border: none;",
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
