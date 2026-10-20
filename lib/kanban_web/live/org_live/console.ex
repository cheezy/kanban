defmodule KanbanWeb.OrgLive.Console do
  @moduledoc """
  The org console at `/org`, reachable only by an org-admin.

  It always shows the signed-in org-admin's own Organization: the id comes from
  the membership `KanbanWeb.UserAuth` loaded into `current_scope`, never from
  params. Sections follow the `KanbanWeb.UserLive.Settings` pattern, with an
  allow-listed `select_section` event. Choosing a section patches the URL to
  `/org?section=<name>`, so a section can be linked to and survives a reload:

    * Details - the Organization's name, address and contact, read-only. Only a
      site admin edits them.
    * Members - every member with name, email and role, read-only, with
      Disabled and Unconfirmed accounts labelled. The list reloads each time
      the section opens.
    * Workspaces - the Organization's unarchived workspaces, which the
      org-admin creates, renames and archives through
      `Kanban.Organizations.OrgWorkspaces`. Archived workspaces are hidden.

  The org-admin gate re-reads the role from the database on every patch, but
  events do not patch, so every Workspaces event re-reads the actor and their
  org-admin role itself before it does anything. A refused actor is redirected
  to `/boards` exactly as the gate would.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.Components.AccountStatus

  import KanbanWeb.UserLive.SettingsComponents, only: [section_tab: 1, settings_card: 1]

  alias Ecto.Changeset
  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrgWorkspaces
  alias Kanban.Workspaces.Workspace

  # The router's live_session :require_authenticated_user lets in every
  # signed-in user. Re-declaring the org-admin gate here keeps the console
  # closed to members, free users and site admins even if the route is moved.
  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  @sections ["details", "members", "workspaces"]

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: %{user: user}, current_organization: %Organization{id: id}} =
      socket.assigns

    case Organizations.get_organization(id, user) do
      %Organization{} = organization ->
        {:ok, assign_console(socket, organization, user)}

      # The org-admin role was removed between the gate and this lookup.
      nil ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("You must be an org-admin of an Organization to access this page.")
         )
         |> redirect(to: ~p"/boards")}
    end
  end

  defp assign_console(socket, organization, user) do
    socket
    |> assign(:page_title, gettext("Organization"))
    |> assign(:organization, organization)
    |> assign(:members, Organizations.list_members(organization))
    |> assign(:workspaces, OrgWorkspaces.list_workspaces(user, organization.id))
    |> assign(:create_rev, 0)
    |> assign(:create_form, create_form(0))
    |> reset_rename()
    |> assign(:section, :details)
  end

  # ?section= opens that section; anything else, including an unknown name or
  # no parameter, shows Details. Opening Members reloads the list, so a member
  # disabled, confirmed or removed since the page loaded shows as they are now.
  @impl true
  def handle_params(%{"section" => "members"}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:members, Organizations.list_members(socket.assigns.organization))
     |> assign(:section, :members)}
  end

  def handle_params(%{"section" => section}, _uri, socket) when section in @sections do
    {:noreply, assign(socket, :section, String.to_existing_atom(section))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :section, :details)}

  @impl true
  def handle_event("select_section", %{"section" => section}, socket)
      when section in @sections do
    {:noreply, push_patch(socket, to: ~p"/org?#{[section: section]}")}
  end

  # A crafted payload naming any other section leaves the console as it is.
  def handle_event("select_section", _params, socket), do: {:noreply, socket}

  def handle_event("create_workspace", params, socket) do
    with_org_admin(socket, fn actor ->
      actor
      |> OrgWorkspaces.create_workspace(
        socket.assigns.organization.id,
        name_params(params, "workspace")
      )
      |> respond_to_create(actor, socket)
    end)
  end

  def handle_event("start_rename", %{"id" => id}, socket) when is_binary(id) or is_integer(id) do
    with_org_admin(socket, fn actor ->
      case listed_workspace(socket, id) do
        %Workspace{} = workspace -> {:noreply, start_renaming(socket, workspace)}
        nil -> {:noreply, workspace_not_found(socket, actor)}
      end
    end)
  end

  def handle_event("cancel_rename", _params, socket) do
    with_org_admin(socket, fn _actor -> {:noreply, reset_rename(socket)} end)
  end

  def handle_event("rename_workspace", %{"workspace_id" => id} = params, socket) do
    with_org_admin(socket, fn actor ->
      actor
      |> OrgWorkspaces.rename_workspace(id, name_params(params, "rename"))
      |> respond_to_rename(actor, socket)
    end)
  end

  def handle_event("archive_workspace", %{"id" => id}, socket) do
    with_org_admin(socket, fn actor ->
      actor
      |> OrgWorkspaces.archive_workspace(id)
      |> respond_to_archive(actor, socket)
    end)
  end

  # A crafted workspace event with no id, or an id that is not a string or an
  # integer, changes nothing.
  def handle_event(event, _params, socket)
      when event in ["start_rename", "rename_workspace", "archive_workspace"],
      do: {:noreply, socket}

  defp respond_to_create({:ok, _workspace}, actor, socket) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Workspace created."))
     |> reset_create_form()
     |> refresh_workspaces(actor)}
  end

  defp respond_to_create({:error, %Changeset{} = changeset}, _actor, socket) do
    form = to_form(changeset, as: :workspace, id: create_form_id(socket.assigns.create_rev))
    {:noreply, assign(socket, :create_form, form)}
  end

  defp respond_to_create({:error, reason}, actor, socket),
    do: workspace_error(socket, reason, actor)

  defp respond_to_rename({:ok, workspace}, actor, socket) do
    message = socket |> listed_workspace(workspace.id) |> rename_message(workspace)

    {:noreply,
     socket
     |> replace_flash(:info, message)
     |> reset_rename()
     |> refresh_workspaces(actor)}
  end

  defp respond_to_rename({:error, %Changeset{} = changeset}, _actor, socket),
    do: {:noreply, assign(socket, :rename_form, invalid_form(changeset, :rename))}

  defp respond_to_rename({:error, reason}, actor, socket),
    do: workspace_error(socket, reason, actor)

  # Saving the name the row already shows changes nothing and writes no audit
  # row, so it must not report a rename.
  defp rename_message(%Workspace{name: name}, %Workspace{name: name}),
    do: gettext("No changes to save.")

  defp rename_message(_listed, _saved), do: gettext("Workspace renamed.")

  defp respond_to_archive({:ok, _workspace}, actor, socket) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Workspace archived."))
     |> reset_rename()
     |> refresh_workspaces(actor)}
  end

  defp respond_to_archive({:error, reason}, actor, socket),
    do: workspace_error(socket, reason, actor)

  defp workspace_error(socket, :unauthorized, _actor), do: {:noreply, refuse(socket)}

  defp workspace_error(socket, :not_found, actor),
    do: {:noreply, workspace_not_found(socket, actor)}

  defp workspace_error(socket, :workspace_has_boards, actor) do
    {:noreply,
     socket
     |> replace_flash(
       :error,
       gettext("This workspace still holds boards. Move them out before archiving it.")
     )
     |> refresh_workspaces(actor)}
  end

  defp workspace_error(socket, _reason, actor) do
    {:noreply,
     socket
     |> replace_flash(:error, gettext("The workspace could not be changed. Please try again."))
     |> refresh_workspaces(actor)}
  end

  defp workspace_not_found(socket, actor) do
    socket
    |> replace_flash(:error, gettext("Workspace not found."))
    |> reset_rename()
    |> refresh_workspaces(actor)
  end

  # current_scope is loaded at mount and never refreshed, and an event does not
  # run the gate's handle_params hook. Re-read the actor and their org-admin
  # role from the database, and pass that fresh struct to the context.
  defp with_org_admin(socket, fun) do
    case authorized_actor(socket) do
      %User{} = actor -> fun.(actor)
      nil -> {:noreply, refuse(socket)}
    end
  end

  defp authorized_actor(socket) do
    %{current_scope: %{user: %{id: id}}, organization: %Organization{id: organization_id}} =
      socket.assigns

    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization_id) do
      actor
    else
      _ -> nil
    end
  end

  defp refuse(socket) do
    Kanban.AuditLog.event(:permission_denied,
      user_id: socket.assigns.current_scope.user.id,
      gate: :require_org_admin
    )

    socket
    |> put_flash(
      :error,
      gettext("You must be an org-admin of an Organization to access this page.")
    )
    |> redirect(to: ~p"/boards")
  end

  defp refresh_workspaces(socket, actor) do
    assign(
      socket,
      :workspaces,
      OrgWorkspaces.list_workspaces(actor, socket.assigns.organization.id)
    )
  end

  # The listed workspaces are only a UI hint: renaming re-reads the workspace
  # through OrgWorkspaces, so a stale list can open a form but never save one.
  defp listed_workspace(socket, id) do
    id = to_string(id)
    Enum.find(socket.assigns.workspaces, &(Integer.to_string(&1.id) == id))
  end

  defp start_renaming(socket, workspace) do
    socket
    |> assign(:renaming_id, workspace.id)
    |> assign(:rename_form, workspace_form(workspace, :rename))
  end

  defp reset_rename(socket) do
    socket
    |> assign(:renaming_id, nil)
    |> assign(:rename_form, nil)
  end

  # A new rev gives the emptied create form a new input id. The form has no
  # phx-change, so the server's empty value is the same before and after a
  # create and LiveView sends no diff for it; with the same id the typed name
  # would stay in the field and a second click would create a duplicate. The
  # new input is mounted afresh, which is what moves focus back into it.
  defp reset_create_form(socket) do
    rev = socket.assigns.create_rev + 1

    socket
    |> assign(:create_rev, rev)
    |> assign(:create_form, create_form(rev))
  end

  defp create_form(rev) do
    %Workspace{}
    |> OrgWorkspaces.change_workspace()
    |> to_form(as: :workspace, id: create_form_id(rev))
  end

  defp create_form_id(rev), do: "workspace-#{rev}"

  # The create and rename forms use different names, so their inputs never
  # share an id while a rename is open.
  defp workspace_form(workspace, as),
    do: workspace |> OrgWorkspaces.change_workspace() |> to_form(as: as)

  # The changeset comes back from Repo.insert/1 or Repo.update/1, which set its
  # action, so the form shows its errors.
  defp invalid_form(%Changeset{} = changeset, as), do: to_form(changeset, as: as)

  # A tampered payload can drop the form, its name or send a non-map; each is
  # treated as an empty name, which the changeset rejects as blank on both
  # create and rename, so a rename with no name never reports success.
  defp name_params(params, key) do
    case Map.get(params, key) do
      %{"name" => name} -> %{"name" => name}
      _other -> %{"name" => ""}
    end
  end

  # Every message replaces the one before it, so an earlier error never stays
  # on screen beside the success that follows it. "flash:shown" restarts the
  # info message's dismiss timer even when the new text is the same as the old.
  defp replace_flash(socket, kind, message) do
    socket
    |> clear_flash()
    |> put_flash(kind, message)
    |> push_event("flash:shown", %{kind: Atom.to_string(kind)})
  end

  defp sections do
    [
      {:details, gettext("Details"), gettext("name · address · contact")},
      {:members, gettext("Members"), gettext("names · roles")},
      {:workspaces, gettext("Workspaces"), gettext("create · rename · archive")}
    ]
  end

  defp role_label(:org_admin), do: gettext("Org-admin")
  defp role_label(:member), do: gettext("Member")

  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_user), do: "—"

  defp location(%Organization{} = organization) do
    [organization.city, organization.region, organization.postal_code, organization.country]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
    |> detail()
  end

  defp detail(nil), do: "—"
  defp detail(""), do: "—"
  defp detail(value), do: value
end
