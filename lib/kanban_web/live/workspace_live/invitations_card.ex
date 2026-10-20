defmodule KanbanWeb.WorkspaceLive.InvitationsCard do
  @moduledoc """
  The Invitations section of `KanbanWeb.WorkspaceLive.Settings` (W2219): the
  invite form and the list of open invitations with resend and revoke.

  Rendered only for an org-admin of the workspace's Organization. The events
  it sends (`validate_invite`, `invite`, `resend_invitation`,
  `revoke_invitation`) are handled, and re-authorized, by the settings
  LiveView.
  """
  use KanbanWeb, :html

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  alias Kanban.Workspaces.Invitation

  attr :form, Phoenix.HTML.Form, required: true
  attr :boards, :list, required: true
  attr :invitations, :list, required: true

  def invitations_card(assigns) do
    ~H"""
    <.settings_card
      id="invitations"
      tab={:invitations}
      title={gettext("Invite people")}
      hint={
        gettext(
          "Invite someone by email to join this workspace and your Organization. The link works once and expires in %{days} days.",
          days: Invitation.validity_days()
        )
      }
    >
      <.form
        for={@form}
        id="invite-form"
        phx-change="validate_invite"
        phx-submit="invite"
        class="flex flex-col gap-1"
      >
        <.input field={@form[:email]} type="email" label={gettext("Email")} required />
        <div class="grid grid-cols-1 gap-x-4 @md:grid-cols-3">
          <.input field={@form[:role]} type="select" label={gettext("Role")} options={role_options()} />
          <.input
            field={@form[:board_id]}
            type="select"
            label={gettext("Board (optional)")}
            prompt={gettext("No board")}
            options={Enum.map(@boards, &{&1.name, &1.id})}
          />
          <.input
            field={@form[:board_access]}
            type="select"
            label={gettext("Board access")}
            options={access_options()}
          />
        </div>
        <div>
          <.button
            id="send-invitation"
            type="submit"
            variant="primary"
            class="btn btn-primary btn-sm"
            phx-disable-with={gettext("Sending...")}
          >
            {gettext("Send invitation")}
          </.button>
        </div>
      </.form>
    </.settings_card>

    <.settings_card
      id="pending-invitations"
      title={gettext("Pending invitations")}
      hint={gettext("Resending sends a new link and the old one stops working.")}
      compact
    >
      <p
        :if={@invitations == []}
        id="no-invitations"
        style="margin: 0; padding: 10px 0; font-size: 13px; color: var(--ink-2);"
      >
        {gettext("No pending invitations.")}
      </p>
      <ul id="invitation-list" style="list-style: none; margin: 0; padding: 0;">
        <li
          :for={invitation <- @invitations}
          id={"invitation-#{invitation.id}"}
          class="flex flex-col gap-2 @md:flex-row @md:items-center @md:gap-4"
          style="padding: 10px 0; border-bottom: 1px solid var(--line);"
        >
          <span
            class="@md:flex-1 min-w-0"
            style="font-size: 13px; font-weight: 500; color: var(--ink); overflow-wrap: anywhere;"
          >
            {invitation.email}
          </span>
          <span
            class="@md:flex-1 min-w-0"
            style="font-size: 12.5px; color: var(--ink-2); overflow-wrap: anywhere;"
          >
            {grant_text(invitation)}
          </span>
          <span
            id={"invitation-expiry-#{invitation.id}"}
            class="@md:w-36 @md:flex-shrink-0"
            style="font-size: 12px; font-family: var(--font-mono); color: var(--ink-2);"
          >
            {expiry_text(invitation)}
          </span>
          <div class="flex flex-wrap items-center gap-2 @md:flex-shrink-0">
            <.button
              id={"resend-invitation-#{invitation.id}"}
              type="button"
              phx-click="resend_invitation"
              phx-value-id={invitation.id}
              class="btn btn-soft btn-sm"
            >
              {gettext("Resend")}
            </.button>
            <.button
              id={"revoke-invitation-#{invitation.id}"}
              type="button"
              phx-click="revoke_invitation"
              phx-value-id={invitation.id}
              data-confirm={gettext("Revoke this invitation? Its link stops working.")}
              class="btn btn-soft btn-sm"
            >
              {gettext("Revoke")}
            </.button>
          </div>
        </li>
      </ul>
    </.settings_card>
    """
  end

  defp role_options, do: [{gettext("Member"), "member"}, {gettext("Guest"), "guest"}]

  defp access_options,
    do: [{gettext("Read only"), "read_only"}, {gettext("Can edit"), "modify"}]

  defp grant_text(%Invitation{} = invitation) do
    role = role_label(invitation.role)

    case invitation.board do
      %{name: name} -> gettext("%{role} · %{board}", role: role, board: name)
      _none -> role
    end
  end

  defp role_label(:member), do: gettext("Member")
  defp role_label(:guest), do: gettext("Guest")
  defp role_label(_none), do: gettext("Board only")

  defp expiry_text(%Invitation{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      gettext("Expires %{date}", date: Calendar.strftime(expires_at, "%Y-%m-%d"))
    else
      gettext("Expired")
    end
  end
end
