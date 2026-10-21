defmodule KanbanWeb.UserLive.DangerZoneComponent do
  @moduledoc """
  The Delete account section of the account settings page (W2221).

  It lists what stops the user deleting their account
  (`Kanban.Accounts.deletion_blockers/1`) with what to do about each: a board
  they own that other people use can be handed to one of its members right
  here (`Kanban.Boards.transfer_board_ownership/3`); being the last org-admin
  or the last site admin needs someone else to act first. Being the only
  member of an Organization (`Kanban.Accounts.deletion_warnings/1`) is shown as
  a warning, and does not stop the deletion.

  With nothing in the way, a confirmation dialog asks for the password and the
  confirmation phrase (`Kanban.Accounts.account_deletion_phrase/0`). After the
  deletion the component tells the parent LiveView, which disconnects the
  user's other open sessions, and submits a hidden form to `DELETE
  /users/log-out` so this browser's session and remember-me cookie are
  cleared too.

  Rendered by `KanbanWeb.UserLive.Settings`, which is sudo-gated. The sudo
  check runs only when the page mounts, so the deletion still needs the
  password.
  """
  use KanbanWeb, :live_component

  alias Kanban.Accounts
  alias Kanban.Boards
  alias Phoenix.LiveView.JS

  @input_style "width: 100%; max-width: 320px; padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-input); font-size: 12.5px; color: var(--ink); outline: none; font-family: inherit;"
  @danger_style "height: 32px; padding: 0 14px; border-radius: 5px; background: var(--st-blocked); color: var(--color-base-100); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer;"
  @secondary_style "height: 32px; padding: 0 14px; border-radius: 5px; background: transparent; color: var(--ink-2); border: 1px solid var(--line-strong); font-size: 12.5px; font-weight: 500; cursor: pointer;"

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       show_modal: false,
       trigger_logout: false,
       params: %{"password" => "", "confirmation" => ""},
       errors: %{},
       notice: nil,
       phrase: Accounts.account_deletion_phrase()
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load_blockers()}
  end

  defp load_blockers(socket) do
    user = socket.assigns.current_scope.user
    blockers = Accounts.deletion_blockers(user)

    candidates =
      for {:shared_board, board} <- blockers, into: %{} do
        {board.id, Boards.list_ownership_candidates(board, user)}
      end

    assign(socket,
      blockers: blockers,
      candidates: candidates,
      warnings: Accounts.deletion_warnings(user)
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        input_style: @input_style,
        danger_style: @danger_style,
        secondary_style: @secondary_style,
        phrase_ok: phrase_ok?(assigns.params, assigns.phrase)
      )

    ~H"""
    <div id="danger-zone-panel" style="display: flex; flex-direction: column; gap: 14px;">
      <p
        :if={@notice}
        id="danger-zone-notice"
        role="status"
        style={[
          "margin: 0; padding: 8px 10px; border-radius: 6px; font-size: 12.5px; line-height: 1.5; color: var(--ink); border: 1px solid var(--line);",
          notice_style(elem(@notice, 0))
        ]}
      >
        {elem(@notice, 1)}
      </p>
      <p style="margin: 0; font-size: 12.5px; color: var(--ink-2); line-height: 1.55; text-wrap: pretty;">
        {gettext(
          "Deleting your account signs you out everywhere and removes your API tokens, your memberships and the boards in your personal workspace that only you use. Boards other people still use stay with them, boards in an Organization's workspace stay with the Organization, and the tasks and comments you added there are kept without your name. This cannot be undone."
        )}
      </p>

      <div
        :if={@blockers != []}
        id="deletion-blockers"
        style="display: flex; flex-direction: column; gap: 10px;"
      >
        <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink);">
          {gettext("Before you can delete your account")}
        </h3>
        <ul style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 10px;">
          <li
            :for={blocker <- @blockers}
            id={blocker_id(blocker)}
            style="padding: 10px 12px; border-radius: 6px; border: 1px solid var(--line); border-left: 3px solid var(--st-blocked); background: var(--surface);"
          >
            <.blocker
              blocker={blocker}
              candidates={@candidates}
              myself={@myself}
              input_style={@input_style}
              secondary_style={@secondary_style}
            />
          </li>
        </ul>
      </div>

      <ul
        :if={@warnings != []}
        id="deletion-warnings"
        style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 10px;"
      >
        <li
          :for={{:sole_org_member, organization} <- @warnings}
          id={"warning-sole-org-member-#{organization.id}"}
          style="padding: 10px 12px; border-radius: 6px; border: 1px solid var(--line); border-left: 3px solid var(--st-doing); background: var(--surface);"
        >
          <p style="margin: 0; font-size: 12.5px; color: var(--ink); line-height: 1.5;">
            {gettext("You are the only member of %{organization}.",
              organization: organization.name
            )}
          </p>
          <p style="margin: 4px 0 0; font-size: 12px; color: var(--ink-2); line-height: 1.5;">
            {gettext(
              "If you delete your account, nobody will be able to manage it or open its workspaces and boards until a Stride admin appoints a new org-admin."
            )}
          </p>
        </li>
      </ul>

      <div :if={@blockers == []}>
        <button
          type="button"
          id="open-delete-account"
          phx-click="open_delete"
          phx-target={@myself}
          style={@danger_style}
        >
          {gettext("Delete my account")}
        </button>
      </div>

      <.modal
        :if={@show_modal}
        id="delete-account-modal"
        label={gettext("Delete your account")}
        show
        on_cancel={JS.push("close_delete", target: @myself)}
      >
        <.form
          for={%{}}
          as={:delete_account}
          id="delete-account-form"
          phx-change="validate_delete"
          phx-submit="delete_account"
          phx-target={@myself}
          style="display: flex; flex-direction: column; gap: 14px;"
        >
          <h2 style="margin: 0; font-size: 17px; font-weight: 600; color: var(--ink);">
            {gettext("Delete your account")}
          </h2>
          <p style="margin: 0; font-size: 12.5px; color: var(--ink-2); line-height: 1.55;">
            {gettext(
              "This permanently deletes your account. Enter your password and type the phrase below to confirm."
            )}
          </p>

          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Password")}
            </span>
            <%!-- `value` is REQUIRED on a password input inside a phx-change
                  form, or typing in the other field wipes it (see settings.ex). --%>
            <input
              type="password"
              name="delete_account[password]"
              id="delete-account-password"
              value={@params["password"]}
              autocomplete="current-password"
              required
              aria-invalid={@errors[:password] && "true"}
              style={@input_style}
            />
            <span :if={@errors[:password]} style="font-size: 11.5px; color: var(--st-blocked);">
              {@errors[:password]}
            </span>
          </label>

          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Type %{phrase} to confirm", phrase: @phrase)}
            </span>
            <input
              type="text"
              name="delete_account[confirmation]"
              id="delete-account-confirmation"
              value={@params["confirmation"]}
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
              required
              aria-invalid={@errors[:confirmation] && "true"}
              style={@input_style}
            />
            <span
              :if={@errors[:confirmation]}
              style="font-size: 11.5px; color: var(--st-blocked);"
            >
              {@errors[:confirmation]}
            </span>
          </label>

          <div style="display: flex; gap: 8px; flex-wrap: wrap;">
            <button
              type="submit"
              id="confirm-delete-account"
              disabled={!@phrase_ok}
              phx-disable-with={gettext("Deleting...")}
              style={@danger_style <> if(@phrase_ok, do: "", else: " opacity: 0.55; cursor: not-allowed;")}
            >
              {gettext("Permanently delete my account")}
            </button>
            <button
              type="button"
              phx-click="close_delete"
              phx-target={@myself}
              style={@secondary_style}
            >
              {gettext("Cancel")}
            </button>
          </div>
        </.form>
      </.modal>

      <.form
        for={%{}}
        id="account-deleted-logout"
        action={~p"/users/log-out"}
        method="delete"
        phx-trigger-action={@trigger_logout}
      >
        <input type="hidden" name="account_deleted" value="true" />
      </.form>
    </div>
    """
  end

  attr :blocker, :any, required: true
  attr :candidates, :map, required: true
  attr :myself, :any, required: true
  attr :input_style, :string, required: true
  attr :secondary_style, :string, required: true

  defp blocker(%{blocker: :last_site_admin} = assigns) do
    ~H"""
    <p style="margin: 0; font-size: 12.5px; color: var(--ink); line-height: 1.5;">
      {gettext(
        "You are the last site admin. Make another user a site admin before you delete your account."
      )}
    </p>
    """
  end

  defp blocker(%{blocker: {:last_org_admin, organization}} = assigns) do
    assigns = assign(assigns, :organization, organization)

    ~H"""
    <p style="margin: 0; font-size: 12.5px; color: var(--ink); line-height: 1.5;">
      {gettext("You are the last org-admin of %{organization}, which has other members.",
        organization: @organization.name
      )}
    </p>
    <p style="margin: 4px 0 0; font-size: 12px; color: var(--ink-2); line-height: 1.5;">
      {gettext("A Stride admin must appoint another org-admin before you can delete your account.")}
    </p>
    """
  end

  defp blocker(%{blocker: {:shared_board, board}} = assigns) do
    assigns =
      assign(assigns, board: board, board_candidates: Map.get(assigns.candidates, board.id, []))

    ~H"""
    <p style="margin: 0; font-size: 12.5px; color: var(--ink); line-height: 1.5;">
      {gettext("You own %{board}, which other people use.", board: @board.name)}
      <.link
        navigate={~p"/boards/#{@board.id}/members"}
        style="color: var(--ink); text-decoration: underline; text-underline-offset: 2px;"
      >
        {gettext("Open its members")}
      </.link>
    </p>
    <form
      :if={@board_candidates != []}
      id={"transfer-board-#{@board.id}"}
      phx-submit="transfer"
      phx-target={@myself}
      style="margin-top: 8px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center;"
    >
      <input type="hidden" name="board_id" value={@board.id} />
      <label for={"transfer-board-#{@board.id}-owner"} style="font-size: 12px; color: var(--ink-2);">
        {gettext("Transfer ownership to")}
      </label>
      <select
        id={"transfer-board-#{@board.id}-owner"}
        name="new_owner_id"
        style={@input_style}
      >
        <option :for={candidate <- @board_candidates} value={candidate.id}>
          {candidate.name || candidate.email}
        </option>
      </select>
      <button type="submit" style={@secondary_style}>
        {gettext("Transfer ownership")}
      </button>
    </form>
    <p
      :if={@board_candidates == []}
      style="margin: 6px 0 0; font-size: 12px; color: var(--ink-2); line-height: 1.5;"
    >
      {gettext(
        "None of its other members can take it over because their accounts are disabled. Remove them from the board, then come back."
      )}
    </p>
    """
  end

  defp notice_style(:error), do: "border-left: 3px solid var(--st-blocked);"
  defp notice_style(:info), do: "border-left: 3px solid var(--st-ready);"

  defp blocker_id(:last_site_admin), do: "blocker-last-site-admin"
  defp blocker_id({:last_org_admin, _organization}), do: "blocker-last-org-admin"
  defp blocker_id({:shared_board, board}), do: "blocker-board-#{board.id}"

  defp phrase_ok?(%{"confirmation" => confirmation}, phrase),
    do: String.trim(confirmation) == phrase

  @impl true
  def handle_event("open_delete", _params, socket) do
    {:noreply, assign(socket, show_modal: true, errors: %{}, params: blank_params())}
  end

  def handle_event("close_delete", _params, socket) do
    {:noreply, assign(socket, show_modal: false, errors: %{}, params: blank_params())}
  end

  def handle_event("validate_delete", %{"delete_account" => params}, socket) do
    {:noreply, assign(socket, params: take_params(params), errors: %{})}
  end

  def handle_event("delete_account", %{"delete_account" => params}, socket) do
    params = take_params(params)

    socket.assigns.current_scope
    |> Accounts.delete_own_account(params["password"], params["confirmation"])
    |> handle_delete_result(assign(socket, :params, params))
  end

  def handle_event("transfer", %{"board_id" => board_id, "new_owner_id" => owner_id}, socket) do
    user = socket.assigns.current_scope.user

    socket =
      case blocked_board(socket.assigns.blockers, board_id) do
        nil ->
          assign(socket, :notice, {:error, gettext("That board is not waiting for a new owner.")})

        board ->
          board
          |> Boards.transfer_board_ownership(owner_id, user)
          |> transfer_flash(socket, board)
      end

    {:noreply, load_blockers(socket)}
  end

  defp handle_delete_result({:ok, %{session_tokens: tokens}}, socket) do
    send(self(), {:account_deleted, tokens})

    {:noreply, assign(socket, show_modal: false, trigger_logout: true, params: blank_params())}
  end

  defp handle_delete_result({:error, :not_found}, socket) do
    {:noreply, redirect(socket, to: ~p"/users/log-in")}
  end

  defp handle_delete_result({:error, {:blocked, _blockers}}, socket) do
    {:noreply,
     socket
     |> assign(show_modal: false, params: blank_params())
     |> assign(:notice, {:error, gettext("Something now stops your account being deleted.")})
     |> load_blockers()}
  end

  defp handle_delete_result({:error, reason}, socket) do
    {:noreply, assign(socket, errors: delete_error(reason))}
  end

  defp delete_error(:invalid_password), do: %{password: gettext("That password is not correct.")}

  defp delete_error(:rate_limited),
    do: %{password: gettext("Too many wrong passwords. Try again in a few minutes.")}

  defp delete_error(:invalid_confirmation),
    do: %{confirmation: gettext("Type the phrase exactly as shown.")}

  defp transfer_flash({:ok, _board}, socket, board) do
    assign(
      socket,
      :notice,
      {:info, gettext("Ownership of %{board} transferred.", board: board.name)}
    )
  end

  defp transfer_flash({:error, _reason}, socket, board) do
    assign(
      socket,
      :notice,
      {:error, gettext("Ownership of %{board} could not be transferred.", board: board.name)}
    )
  end

  # Only a board listed as a blocker can be transferred from here; the context
  # authorizes the transfer again in its own transaction.
  defp blocked_board(blockers, board_id) do
    Enum.find_value(blockers, fn
      {:shared_board, board} -> if to_string(board.id) == board_id, do: board
      _other -> nil
    end)
  end

  defp take_params(params) do
    %{
      "password" => string_param(params, "password"),
      "confirmation" => string_param(params, "confirmation")
    }
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp blank_params, do: %{"password" => "", "confirmation" => ""}
end
