defmodule KanbanWeb.OrgLive.Security do
  @moduledoc """
  The org-admin Security page at `/org/security`: the signed-in org-admin's
  own Organization's security policy (`Kanban.Organizations.SecurityPolicy`).

  The Organization comes from `current_organization`, which the
  `:require_org_admin` gate assigns from the membership loaded into
  `current_scope`; it is never read from params. `current_scope` is loaded once
  at mount and an event does not run the gate's `handle_params` hook, so every
  `validate` and `save` re-reads the actor and their org-admin role from the
  database first (`KanbanWeb.OrgLive.OrgAdminCheck`), and
  `Kanban.Organizations.SecurityPolicies.update_policy/2` checks again before
  writing. A refused event is audited as `permission_denied` and redirects to
  `/boards`.

  The form's params pass through `KanbanWeb.OrgLive.FormParams.scalar/2`
  first (D441): a value that is not a string becomes blank, and the
  `require_two_factor` and `hide_titles_in_notifications` checkboxes are kept
  only as the `"true"` or `"false"` they send, so a crafted payload cannot crash the re-rendered inputs. A
  `validate` or `save` event whose `"security_policy"` param is missing or not
  a map runs the same org-admin check and changes nothing.

  The hide-titles checkbox controls pushes, which reach only the Stride app,
  so it is rendered only while `:mobile_app_preview` is on for the viewing
  org-admin or the policy is already on, so a policy in force can always be
  seen and turned off. When it is not rendered the form sends no
  `hide_titles_in_notifications` value at all, `FormParams.scalar/2` copies
  only the keys present and the changeset casts only those, so the stored
  value is kept rather than read as false; and a value a crafted event sends
  while it is not rendered is dropped before the cast, so the server refuses
  the hidden control too.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 2, refuse: 1]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  # The router's live_session :require_authenticated_user lets in every
  # signed-in user. Re-declaring the org-admin gate here keeps the page closed
  # to members, free users and site admins even if the route is moved.
  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.FeatureFlags
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias KanbanWeb.LocalTime
  alias KanbanWeb.OrgLive.FormParams

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization
    policy = SecurityPolicies.policy_for_organization(organization.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Organization security"))
     |> assign(:organization, organization)
     |> assign(
       :mobile_preview?,
       FeatureFlags.enabled?(socket.assigns.current_scope, :mobile_app_preview)
     )
     |> assign_policy(policy)}
  end

  @impl true
  def handle_event("validate", %{"security_policy" => params}, socket) when is_map(params) do
    with_org_admin(socket, fn _actor ->
      form =
        socket.assigns.policy
        |> SecurityPolicies.change_policy(scalar_params(params, socket))
        |> Map.put(:action, :validate)
        |> to_form()

      {:noreply, assign(socket, :form, form)}
    end)
  end

  def handle_event("save", %{"security_policy" => params}, socket) when is_map(params) do
    with_org_admin(socket, fn actor ->
      actor
      |> SecurityPolicies.update_policy(scalar_params(params, socket))
      |> policy_saved(socket)
    end)
  end

  # A missing or non-map "security_policy" would raise in the changeset cast.
  # It cannot come from the page, so it runs the org-admin check and does
  # nothing.
  def handle_event(event, _params, socket) when event in ["validate", "save"] do
    with_org_admin(socket, fn _actor -> {:noreply, socket} end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A hide-titles value is refused while its checkbox is not rendered, so only
  # a crafted event could send one, and it cannot change the policy either way.
  defp scalar_params(params, %{assigns: %{show_hide_titles?: false}}),
    do: params |> Map.delete("hide_titles_in_notifications") |> scalar_params()

  defp scalar_params(params, _socket), do: scalar_params(params)

  defp scalar_params(params),
    do: FormParams.scalar(params, ["require_two_factor", "hide_titles_in_notifications"])

  defp policy_saved({:ok, policy}, socket) do
    {:noreply,
     socket |> assign_policy(policy) |> put_flash(:info, gettext("Security policy saved."))}
  end

  defp policy_saved({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, assign(socket, :form, to_form(changeset))}

  defp policy_saved({:error, :unauthorized}, socket), do: {:noreply, refuse(socket)}

  defp assign_policy(socket, %SecurityPolicy{} = policy) do
    socket
    |> assign(:policy, policy)
    |> assign(
      :show_hide_titles?,
      socket.assigns.mobile_preview? or policy.hide_titles_in_notifications
    )
    |> assign(:form, policy |> SecurityPolicies.change_policy() |> to_form())
  end

  defp format_time(%DateTime{} = at), do: LocalTime.format(at, :datetime)

  defp grace_range, do: SecurityPolicy.grace_days_range()
  defp retention_range, do: SecurityPolicy.retention_days_range()
end
