defmodule KanbanWeb.WorkspaceLive.Settings do
  @moduledoc """
  Workspace settings at `/workspace/settings`, for the signed-in user's current
  workspace (`current_scope.workspace`, verified by `KanbanWeb.UserAuth`
  through `Kanban.Workspaces.Current`). Personal workspaces never appear here.

  Mount refuses, with a generic flash and a redirect to `/boards`, a user the
  plan check reports without paid access (`Kanban.Plans`), a user without an
  Organization (the plan check lets everyone through while plans are not
  enforced), and a user with no current workspace — including one whose
  workspace was archived or who was removed from it since they chose it.

  Sections follow the `KanbanWeb.UserLive.Settings` pattern, with an
  allow-listed `select_section` event that patches `?section=`:

    * Members — every member and guest. An org-admin of the workspace's
      Organization changes a role (member or guest) and removes a member, which
      also removes their board memberships in this workspace and revokes their
      API tokens there (`Kanban.Workspaces.remove_member/3`). Members and
      guests see a read-only list.
    * Boards — the workspace's boards the viewer can see. An org-admin can also
      move a board they own from their personal workspace here
      (`Kanban.Workspaces.move_board_to_workspace/3`).
    * Invitations — org-admins only (W2219). Invite an email address as a
      member or guest, optionally with access to one of the workspace's
      boards, and resend or revoke open invitations
      (`Kanban.Workspaces.Invitations`, `KanbanWeb.WorkspaceLive.InvitationsCard`).
    * Tokens — org-admins only (W2220). Create a workspace-scoped API token,
      whose plain text is shown once (`:new_token`, cleared on dismiss and on
      every section change), and revoke the workspace's tokens
      (`KanbanWeb.WorkspaceLive.Tokens`, `KanbanWeb.WorkspaceLive.TokensCard`).

  Hidden controls are not authorization. Every management event re-reads the
  actor, the workspace and the org-admin role from the database first; a
  member or guest who crafts one gets a denied flash and nothing changes. Ids
  in events are only hints, re-checked by the context.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents, only: [section_tab: 1, settings_card: 1]
  import KanbanWeb.WorkspaceLive.InvitationsCard, only: [invitations_card: 1]
  import KanbanWeb.WorkspaceLive.TokensCard, only: [tokens_card: 1]

  alias Ecto.Changeset
  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Plans
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace
  alias KanbanWeb.WorkspaceLive.Tokens

  @sections ["members", "boards", "invitations", "tokens"]
  @manager_sections ["invitations", "tokens"]
  @invitation_events ["invite", "resend_invitation", "revoke_invitation"]
  @token_events ["create_token", "revoke_token"]
  @roles %{"member" => :member, "guest" => :guest}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if settings_available?(scope) do
      {:ok, assign_settings(socket, scope.user, scope.workspace)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Workspace settings are not available."))
       |> redirect(to: ~p"/boards")}
    end
  end

  defp settings_available?(%{workspace: %Workspace{personal: false}} = scope) do
    Plans.check_user(scope, :workspaces, surface: :live_view) == :ok and
      Plans.user_has_paid_access?(scope)
  end

  defp settings_available?(_scope), do: false

  defp assign_settings(socket, user, workspace) do
    can_manage? = Policy.can_manage_workspace?(user, workspace)

    socket
    |> assign(:page_title, gettext("Workspace settings"))
    |> assign(:workspace, workspace)
    |> assign(:can_manage?, can_manage?)
    |> assign(:section, :members)
    |> assign(:invite_form, invite_form())
    |> assign(:token_form, Tokens.form())
    |> assign(:new_token, nil)
    |> load_lists(user)
  end

  defp load_lists(socket, user) do
    workspace = socket.assigns.workspace

    socket
    |> assign(:members, Workspaces.list_members(user, workspace))
    |> assign(:boards, Workspaces.list_boards(user, workspace))
    |> assign(:movable_boards, movable_boards(socket.assigns.can_manage?, user))
    |> assign(:invitations, Invitations.list_pending(user, workspace))
    |> assign(:tokens, Tokens.list(user, workspace))
  end

  defp movable_boards(true, user), do: Workspaces.list_movable_boards(user)
  defp movable_boards(false, _user), do: []

  # Every section change drops a token shown once, so it never reappears.
  @impl true
  def handle_params(%{"section" => section}, _uri, %{assigns: %{can_manage?: false}} = socket)
      when section in @manager_sections,
      do: {:noreply, show_section(socket, :members)}

  def handle_params(%{"section" => section}, _uri, socket) when section in @sections do
    {:noreply, show_section(socket, String.to_existing_atom(section))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, show_section(socket, :members)}

  defp show_section(socket, section) do
    socket |> assign(:section, section) |> assign(:new_token, nil)
  end

  @impl true
  def handle_event("select_section", %{"section" => section}, socket)
      when section in @sections do
    {:noreply, push_patch(socket, to: ~p"/workspace/settings?#{[section: section]}")}
  end

  def handle_event("select_section", _params, socket), do: {:noreply, socket}

  def handle_event("update_role", %{"user_id" => user_id, "role" => role}, socket)
      when is_binary(user_id) or is_integer(user_id) do
    with_manager(socket, &update_role(&1, &2, user_id, role, socket))
  end

  def handle_event("remove_member", %{"user_id" => user_id}, socket)
      when is_binary(user_id) or is_integer(user_id) do
    with_manager(socket, fn actor, workspace ->
      case listed_member(actor, workspace, user_id) do
        %User{} = member ->
          actor
          |> Workspaces.remove_member(workspace, member)
          |> respond(socket, actor, gettext("Member removed from the workspace."))

        nil ->
          {:noreply, member_not_found(socket, actor)}
      end
    end)
  end

  def handle_event("move_board", %{"move" => %{"board_id" => board_id}}, socket) do
    with_manager(socket, fn actor, workspace ->
      actor
      |> Workspaces.move_board_to_workspace(board_id, workspace)
      |> respond_to_move(socket, actor)
    end)
  end

  def handle_event("validate_invite", %{"invite" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :invite_form, invite_form(params, :validate))}
  end

  def handle_event("invite", %{"invite" => params}, socket) when is_map(params) do
    with_manager(socket, fn actor, workspace ->
      actor
      |> Invitations.invite_to_workspace(workspace, params, &url(~p"/invitations/#{&1}"))
      |> respond_to_invite(socket, actor, params)
    end)
  end

  def handle_event("resend_invitation", %{"id" => id}, socket)
      when is_binary(id) or is_integer(id) do
    with_manager(socket, fn actor, workspace ->
      actor
      |> listed_invitation(workspace, id, fn invitation_id ->
        Invitations.resend(actor, invitation_id, &url(~p"/invitations/#{&1}"))
      end)
      |> respond_to_invitation_change(socket, actor, gettext("Invitation sent again."))
    end)
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket)
      when is_binary(id) or is_integer(id) do
    with_manager(socket, fn actor, workspace ->
      actor
      |> listed_invitation(workspace, id, &Invitations.revoke(actor, &1))
      |> respond_to_invitation_change(socket, actor, gettext("Invitation revoked."))
    end)
  end

  def handle_event("create_token", %{"token" => params}, socket) when is_map(params) do
    with_manager(socket, fn actor, workspace ->
      actor
      |> Tokens.create(workspace, params)
      |> respond_to_token_create(socket, actor)
    end)
  end

  def handle_event("revoke_token", %{"id" => id}, socket) when is_binary(id) or is_integer(id) do
    with_manager(socket, fn actor, workspace ->
      case Tokens.revoke(actor, workspace, id) do
        :ok ->
          respond({:ok, nil}, socket, actor, gettext("Workspace token revoked."))

        {:error, :unauthorized} ->
          {:noreply, deny(socket)}

        {:error, message} ->
          {:noreply, socket |> replace_flash(:error, message) |> load_lists(actor)}
      end
    end)
  end

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, :new_token, nil)}

  # A crafted management event without its parameters changes nothing, but is
  # still refused for a viewer who may not manage the workspace.
  def handle_event(event, _params, socket)
      when event in ["update_role", "remove_member", "move_board"] or
             event in @invitation_events or event in @token_events do
    with_manager(socket, fn _actor, _workspace -> {:noreply, socket} end)
  end

  defp respond({:ok, _result}, socket, actor, message) do
    {:noreply, socket |> replace_flash(:info, message) |> load_lists(actor)}
  end

  defp respond({:error, :unauthorized}, socket, _actor, _message), do: {:noreply, deny(socket)}

  defp respond({:error, :not_found}, socket, actor, _message),
    do: {:noreply, member_not_found(socket, actor)}

  defp respond({:error, reason}, socket, actor, _message)
       when is_atom(reason) or is_struct(reason, Changeset) do
    {:noreply,
     socket
     |> replace_flash(:error, gettext("The change could not be saved. Please try again."))
     |> load_lists(actor)}
  end

  defp respond_to_move({:ok, _board}, socket, actor) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Board moved into this workspace."))
     |> load_lists(actor)}
  end

  defp respond_to_move({:error, _reason}, socket, actor) do
    {:noreply,
     socket
     |> replace_flash(
       :error,
       gettext("That board can't be moved here. Choose a board you own in your personal boards.")
     )
     |> load_lists(actor)}
  end

  defp respond_to_invite({:ok, invitation}, socket, actor, _params) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Invitation sent to %{email}.", email: invitation.email))
     |> assign(:invite_form, invite_form())
     |> load_lists(actor)}
  end

  defp respond_to_invite({:error, %Changeset{} = changeset}, socket, _actor, _params) do
    {:noreply, assign(socket, :invite_form, to_form(changeset, as: :invite))}
  end

  defp respond_to_invite({:error, :invalid_board}, socket, actor, params) do
    {:noreply,
     socket
     |> replace_flash(:error, gettext("Choose a board in this workspace."))
     |> assign(:invite_form, invite_form(params, nil))
     |> load_lists(actor)}
  end

  defp respond_to_invite({:error, reason}, socket, actor, _params),
    do: respond_to_invitation_change({:error, reason}, socket, actor, nil)

  defp respond_to_invitation_change({:ok, _invitation}, socket, actor, message) do
    {:noreply, socket |> replace_flash(:info, message) |> load_lists(actor)}
  end

  defp respond_to_invitation_change({:error, :unauthorized}, socket, _actor, _message),
    do: {:noreply, deny(socket)}

  defp respond_to_invitation_change({:error, :rate_limited}, socket, _actor, _message) do
    {:noreply,
     replace_flash(
       socket,
       :error,
       gettext("You've sent a lot of invitations. Please try again later.")
     )}
  end

  defp respond_to_invitation_change({:error, _not_found}, socket, actor, _message) do
    {:noreply,
     socket
     |> replace_flash(:error, gettext("Invitation not found."))
     |> load_lists(actor)}
  end

  defp respond_to_token_create({:ok, plain_text}, socket, actor) do
    {:noreply,
     socket
     |> replace_flash(
       :info,
       gettext("Workspace token created. Copy it now; it won't be shown again.")
     )
     |> assign(:new_token, plain_text)
     |> assign(:token_form, Tokens.form())
     |> load_lists(actor)}
  end

  defp respond_to_token_create({:error, :unauthorized}, socket, _actor),
    do: {:noreply, deny(socket)}

  defp respond_to_token_create({:error, %Phoenix.HTML.Form{} = form}, socket, _actor),
    do: {:noreply, assign(socket, :token_form, form)}

  defp respond_to_token_create({:error, message}, socket, actor) when is_binary(message),
    do: {:noreply, socket |> replace_flash(:error, message) |> load_lists(actor)}

  defp invite_form(params \\ %{}, action \\ nil) do
    params
    |> Invitations.change_workspace_invitation()
    |> Map.put(:action, action)
    |> to_form(as: :invite)
  end

  defp update_role(actor, workspace, user_id, role, socket) do
    with {:ok, role} <- parse_role(role),
         %User{} = member <- listed_member(actor, workspace, user_id) do
      actor
      |> Workspaces.update_member_role(workspace, member, role)
      |> respond(socket, actor, gettext("Role updated."))
    else
      _ -> {:noreply, member_not_found(socket, actor)}
    end
  end

  # current_scope is loaded at mount and never refreshed, so every management
  # event re-reads the actor, the workspace and the org-admin role from the
  # database, and passes those fresh values to the context.
  defp with_manager(socket, fun) do
    case fresh_manager(socket.assigns.current_scope.user.id, socket.assigns.workspace.id) do
      {:ok, actor, workspace} -> fun.(actor, workspace)
      :error -> {:noreply, deny(socket)}
    end
  end

  defp fresh_manager(user_id, workspace_id) do
    with %User{disabled_at: nil} = actor <- Accounts.get_user(user_id),
         %Workspace{personal: false} = workspace <- Workspaces.get_workspace(workspace_id, actor),
         true <- Policy.can_manage_workspace?(actor, workspace) do
      {:ok, actor, workspace}
    else
      _ -> :error
    end
  end

  defp deny(socket) do
    Kanban.AuditLog.event(:permission_denied,
      user_id: socket.assigns.current_scope.user.id,
      gate: :workspace_settings
    )

    replace_flash(socket, :error, gettext("Only an org-admin can manage this workspace."))
  end

  defp member_not_found(socket, actor) do
    socket
    |> replace_flash(:error, gettext("Member not found."))
    |> load_lists(actor)
  end

  # The user id from the event is matched against the workspace's member rows,
  # re-read now, so it can only ever name someone already in this workspace.
  defp listed_member(actor, workspace, user_id) do
    user_id = to_string(user_id)

    actor
    |> Workspaces.list_members(workspace)
    |> Enum.find_value(fn member ->
      if Integer.to_string(member.user_id) == user_id, do: member.user
    end)
  end

  # Like listed_member/3: the invitation id from the event is matched against
  # this workspace's pending invitations, re-read now, so an id from another
  # workspace is "not found" here whoever manages it.
  defp listed_invitation(actor, workspace, id, fun) do
    id = to_string(id)

    actor
    |> Invitations.list_pending(workspace)
    |> Enum.find(&(Integer.to_string(&1.id) == id))
    |> case do
      %{id: invitation_id} -> fun.(invitation_id)
      nil -> {:error, :not_found}
    end
  end

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> :error
    end
  end

  defp replace_flash(socket, kind, message) do
    socket
    |> clear_flash()
    |> put_flash(kind, message)
    |> push_event("flash:shown", %{kind: Atom.to_string(kind)})
  end

  defp sections(can_manage?) do
    [
      {:members, gettext("Members"), gettext("roles · removal")},
      {:boards, gettext("Boards"), gettext("list · move a board here")}
    ] ++
      if can_manage?,
        do: [
          {:invitations, gettext("Invitations"), gettext("invite · resend · revoke")},
          {:tokens, gettext("Tokens"), gettext("API tokens · create · revoke")}
        ],
        else: []
  end

  defp role_label(:member), do: gettext("Member")
  defp role_label(:guest), do: gettext("Guest")
  defp role_label(:owner), do: gettext("Owner")

  defp role_options do
    [{gettext("Member"), "member"}, {gettext("Guest"), "guest"}]
  end

  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_user), do: "—"

  defp move_form, do: to_form(%{"board_id" => ""}, as: :move)
end
