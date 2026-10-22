defmodule KanbanWeb.BoardLive.MembersFormComponent do
  @moduledoc """
  Modal-friendly board members manager. Lets the board owner search
  for a registered user by email, add them with read-only or modify
  access, and remove existing non-owner members. Mounted as a
  `live_component` from `KanbanWeb.BoardLive.Show` when the
  `:manage_members` live action is active.

  A live component's own flash never reaches the page (LiveView copies it to
  the parent only on a patch or navigate), so every flash `Membership` sets —
  successes, errors and owner-only denials alike — is relayed to the parent
  LiveView, which applies it with `apply_parent_message/2`. The relayed flash
  replaces the page's, so a search that succeeds after a failed one clears the
  old error exactly as `Membership`'s own `clear_flash/1` intends.

  On a free board with plan enforcement on, the add section shows an
  "N of 3 people" line from the `:member_cap` assign (loaded with the members
  list, see `Membership.assign_member_cap/1`). At or over the cap the search
  form and add buttons are disabled with an explanation and a link to the paid
  plans (W2401). The disabled controls only reflect the cap: a crafted
  `add_user` event is still refused by `Boards.add_user_to_board/4`.
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
     |> Membership.assign_member_cap()
     |> assign_new(:searched_user, fn -> nil end)
     |> assign_new(:search_email, fn -> "" end)
     |> assign_new(:invite_email, fn -> nil end)}
  end

  @impl true
  def handle_event("search_user", %{"email" => email}, socket) do
    socket |> Membership.search_user(socket.assigns.scope.user, email) |> relay_flash()
  end

  def handle_event("add_user", %{"access" => access}, socket) do
    socket |> Membership.add_user(socket.assigns.scope.user, access) |> relay_flash()
  end

  def handle_event("invite_user", %{"access" => access}, socket) do
    socket |> Membership.invite_user(socket.assigns.scope.user, access) |> relay_flash()
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    socket |> Membership.remove_user(socket.assigns.scope.user, user_id) |> relay_flash()
  end

  @doc """
  Applies a message this component sent to its parent LiveView: the flash the
  last membership event produced replaces the page's flash.
  """
  def apply_parent_message(socket, {:replace_flash, flashes}) do
    Enum.reduce(flashes, Phoenix.LiveView.clear_flash(socket), fn {kind, message}, acc ->
      Phoenix.LiveView.put_flash(acc, kind, message)
    end)
  end

  @relayed_flash_kinds %{"info" => :info, "error" => :error}

  defp relay_flash({:noreply, socket}) do
    flashes =
      for {kind, message} <- socket.assigns.flash,
          Map.has_key?(@relayed_flash_kinds, kind),
          do: {Map.fetch!(@relayed_flash_kinds, kind), message}

    send(self(), {__MODULE__, {:replace_flash, flashes}})
    {:noreply, clear_flash(socket)}
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
        <div :if={@member_cap.cap} id="member-cap-status" style="margin-bottom: 10px;">
          <p
            id="member-cap-line"
            style="margin: 0; font-size: 12.5px; font-weight: 500; color: var(--ink-2);"
          >
            {Membership.member_cap_line(@member_cap)}
          </p>
          <p
            :if={@member_cap.reached?}
            id="member-cap-explanation"
            style="margin: 4px 0 0; font-size: 12.5px; color: var(--ink-2); line-height: 1.5;"
          >
            {Membership.member_cap_explanation(@member_cap)}
            <.link
              id="member-cap-pricing-link"
              href={~p"/pricing" <> "#contact"}
              style="color: var(--ink); font-weight: 500; text-decoration: underline; text-underline-offset: 2px;"
            >
              {gettext("Get Stride for your organization")}
            </.link>
          </p>
        </div>
        <form
          id="member-search-form"
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
            disabled={@member_cap.reached?}
            style={[
              "flex: 1; height: 32px; padding: 0 10px;",
              "border-radius: 5px; border: 1px solid var(--line-input);",
              input_fill(@member_cap.reached?),
              "font-size: 12.5px; font-family: var(--font-mono);"
            ]}
          />
          <button
            type="submit"
            disabled={@member_cap.reached?}
            style={[
              "height: 32px; padding: 0 12px; border-radius: 5px;",
              solid_button_fill(@member_cap.reached?),
              "font-size: 12px; font-weight: 500;"
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
        <div style="display: flex; flex-wrap: wrap; gap: 8px;">
          <button
            type="button"
            phx-click="add_user"
            phx-value-access="read_only"
            phx-target={@myself}
            disabled={@member_cap.reached?}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              outline_button_fill(@member_cap.reached?),
              "font-size: 12px; font-weight: 500;"
            ]}
          >
            {gettext("Add as Read Only")}
          </button>
          <button
            type="button"
            phx-click="add_user"
            phx-value-access="modify"
            phx-target={@myself}
            disabled={@member_cap.reached?}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              solid_button_fill(@member_cap.reached?),
              "font-size: 12px; font-weight: 500;"
            ]}
          >
            {gettext("Add with Edit Access")}
          </button>
        </div>
      </section>

      <section
        :if={@invite_email}
        id="board-invite-card"
        style={[
          "background: var(--surface); border: 1px solid var(--line);",
          "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;"
        ]}
      >
        <p style="margin: 0 0 10px; font-size: 12.5px; color: var(--ink-2); line-height: 1.5; overflow-wrap: anywhere;">
          {gettext("Invite %{email} to this board by email.", email: @invite_email)}
        </p>
        <div style="display: flex; flex-wrap: wrap; gap: 8px;">
          <button
            type="button"
            id="invite-read-only"
            phx-click="invite_user"
            phx-value-access="read_only"
            phx-target={@myself}
            disabled={@member_cap.reached?}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              outline_button_fill(@member_cap.reached?),
              "font-size: 12px; font-weight: 500;"
            ]}
          >
            {gettext("Invite as Read Only")}
          </button>
          <button
            type="button"
            id="invite-modify"
            phx-click="invite_user"
            phx-value-access="modify"
            phx-target={@myself}
            disabled={@member_cap.reached?}
            style={[
              "padding: 6px 10px; border-radius: 5px;",
              solid_button_fill(@member_cap.reached?),
              "font-size: 12px; font-weight: 500;"
            ]}
          >
            {gettext("Invite with Edit Access")}
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
              :if={user.disabled_at}
              id={"member-disabled-#{user.id}"}
              data-member-disabled
              title={gettext("This account is disabled and can't sign in. It still takes a seat.")}
              style={[
                "font-size: 10.5px; font-weight: 600; padding: 1px 6px; border-radius: 4px;",
                "background: var(--st-blocked-soft); color: var(--st-blocked);"
              ]}
            >
              {gettext("Disabled")}
            </span>

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

  # Disabled controls sit on the sunken well with --ink-3, the same measured
  # pair as the read-only access chip, rather than dimming with opacity (D214).
  @disabled_fill "background: var(--surface-sunken); color: var(--ink-3); cursor: not-allowed;"

  defp input_fill(true), do: @disabled_fill
  defp input_fill(false), do: "background: var(--surface); color: var(--ink);"

  defp solid_button_fill(true), do: @disabled_fill <> " border: 1px solid var(--line);"

  defp solid_button_fill(false) do
    "background: var(--ink); color: var(--color-base-100); border: none; cursor: pointer; " <>
      "box-shadow: 0 1px 0 rgba(0,0,0,.1) inset, 0 1px 2px rgba(0,0,0,.2);"
  end

  defp outline_button_fill(true), do: @disabled_fill <> " border: 1px solid var(--line);"

  defp outline_button_fill(false) do
    "background: transparent; color: var(--ink-2); border: 1px solid var(--line-strong); cursor: pointer;"
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
