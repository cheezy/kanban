defmodule KanbanWeb.OrgLive.Security do
  @moduledoc """
  The org-admin Security page at `/org/security`: the signed-in org-admin's
  own Organization's security policy (`Kanban.Organizations.SecurityPolicy`).

  The Organization comes from `current_organization`, which the
  `:require_org_admin` gate assigns from the membership loaded into
  `current_scope`; it is never read from params. `current_scope` is loaded once
  at mount and an event does not run the gate's `handle_params` hook, so every
  `validate` and `save` re-reads the actor and their org-admin role from the
  database first, and `Kanban.Organizations.SecurityPolicies.update_policy/2`
  checks again before writing. A refused event is audited as
  `permission_denied` and redirects to `/boards`.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  # The router's live_session :require_authenticated_user lets in every
  # signed-in user. Re-declaring the org-admin gate here keeps the page closed
  # to members, free users and site admins even if the route is moved.
  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization
    policy = SecurityPolicies.policy_for_organization(organization.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Organization security"))
     |> assign(:organization, organization)
     |> assign_policy(policy)}
  end

  @impl true
  def handle_event("validate", %{"security_policy" => params}, socket) do
    with_org_admin(socket, fn _actor ->
      form =
        socket.assigns.policy
        |> SecurityPolicies.change_policy(params)
        |> Map.put(:action, :validate)
        |> to_form()

      {:noreply, assign(socket, :form, form)}
    end)
  end

  def handle_event("save", %{"security_policy" => params}, socket) do
    with_org_admin(socket, fn actor ->
      case SecurityPolicies.update_policy(actor, params) do
        {:ok, policy} ->
          {:noreply,
           socket
           |> assign_policy(policy)
           |> put_flash(:info, gettext("Security policy saved."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_policy(socket, %SecurityPolicy{} = policy) do
    socket
    |> assign(:policy, policy)
    |> assign(:form, policy |> SecurityPolicies.change_policy() |> to_form())
  end

  # Re-read the actor and their org-admin role from the database, as
  # KanbanWeb.OrgLive.Console does, rather than trusting the scope from mount.
  defp with_org_admin(socket, fun) do
    %{current_scope: %{user: %{id: id}}, organization: organization} = socket.assigns

    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization.id) do
      fun.(actor)
    else
      _not_an_enabled_org_admin -> {:noreply, refuse(socket)}
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

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp grace_range, do: SecurityPolicy.grace_days_range()
  defp retention_range, do: SecurityPolicy.retention_days_range()
end
