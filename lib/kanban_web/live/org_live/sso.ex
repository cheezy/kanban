defmodule KanbanWeb.OrgLive.SSO do
  @moduledoc """
  The org-admin single sign-on page at `/org/sso` (W2245): the email domains
  the Organization claims, with the DNS TXT record each needs, the
  Organization's OpenID Connect connection and its SAML 2.0 connection
  (W2246), with Stride's SP entity id, assertion consumer service URL and a
  link to download its SP metadata (`KanbanWeb.SAMLController`).

  The Organization comes from `current_organization`, which the
  `:require_org_admin` gate assigns from the signed-in user's own membership;
  it is never read from params. `current_scope` is loaded once at mount and an
  event does not run the gate again, so every event re-reads the actor, their
  org-admin role and their paid access (`Kanban.Plans`, feature `:sso`) from
  the database first, and the `Kanban.SSO` write checks once more. A refused
  event is audited as `permission_denied` and redirects to `/boards`.

  The client secret is never sent to the browser: the form's secret field is
  always empty, and leaving it empty keeps the stored secret.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.LockedFeature, only: [locked_feature: 1]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.SSO
  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.SAML

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization

    socket =
      socket
      |> assign(:page_title, gettext("Single sign-on"))
      |> assign(:organization, organization)
      |> assign(:callback_url, url(~p"/users/sso/callback"))

    case SSO.check_access(socket.assigns.current_scope, :live_view) do
      :ok -> {:ok, socket |> assign(:locked?, false) |> load(organization.id)}
      {:error, {:plan_required, :sso}} -> {:ok, assign(socket, :locked?, true)}
    end
  end

  @impl true
  def handle_event("add_domain", %{"domain" => params}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      case SSO.add_domain(actor, organization_id, params) do
        {:ok, _domain} ->
          {:noreply,
           socket
           |> load(organization_id)
           |> put_flash(:info, gettext("Domain added. Publish its TXT record, then verify it."))}

        {:error, :domain_taken} ->
          {:noreply, put_flash(socket, :error, domain_taken_message())}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :domain_form, to_form(changeset, as: :domain))}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event("verify_domain", %{"id" => id}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      actor
      |> SSO.verify_domain(organization_id, id)
      |> verified(socket, organization_id)
    end)
  end

  def handle_event("remove_domain", %{"id" => id}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      case SSO.remove_domain(actor, organization_id, id) do
        {:ok, _domain} ->
          {:noreply,
           socket |> load(organization_id) |> put_flash(:info, gettext("Domain removed."))}

        {:error, :not_found} ->
          {:noreply, load(socket, organization_id)}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event("validate_connection", %{"connection" => params}, socket) do
    with_org_admin(socket, fn _actor, _organization_id ->
      form =
        socket.assigns.connection
        |> SSO.change_oidc_connection(Map.delete(params, "client_secret"))
        |> Map.put(:action, :validate)
        |> connection_form()

      {:noreply, assign(socket, :connection_form, form)}
    end)
  end

  def handle_event("save_connection", %{"connection" => params}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      case SSO.save_oidc_connection(actor, organization_id, params) do
        {:ok, _connection} ->
          {:noreply,
           socket
           |> load(organization_id)
           |> put_flash(:info, gettext("Single sign-on connection saved."))}

        {:error, :unsafe_issuer} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("The issuer URL must be a public https address.")
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :connection_form, connection_form(changeset))}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event("validate_saml", %{"saml" => params}, socket) do
    with_org_admin(socket, fn _actor, _organization_id ->
      form =
        socket.assigns.saml_connection
        |> SSO.change_saml_connection(params)
        |> Map.put(:action, :validate)
        |> to_form(as: :saml)

      {:noreply, assign(socket, :saml_form, form)}
    end)
  end

  def handle_event("save_saml", %{"saml" => params}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      case SSO.save_saml_connection(actor, organization_id, params) do
        {:ok, _connection} ->
          {:noreply,
           socket
           |> load(organization_id)
           |> put_flash(:info, gettext("SAML connection saved."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :saml_form, to_form(changeset, as: :saml))}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket, organization_id) do
    connection = SSO.get_oidc_connection(organization_id)

    socket
    |> assign(:domains, SSO.list_domains(organization_id))
    |> assign(:domain_form, to_form(SSO.change_domain(), as: :domain))
    |> assign(:connection, connection)
    |> assign(:secret_set?, not is_nil(connection) and is_binary(connection.client_secret))
    |> assign(:connection_form, connection |> SSO.change_oidc_connection() |> connection_form())
    |> load_saml(organization_id)
  end

  defp load_saml(socket, organization_id) do
    saml_connection = SSO.get_saml_connection(organization_id)

    socket
    |> assign(:saml_connection, saml_connection)
    |> assign(:saml_sp, SAML.service_provider(organization_id))
    |> assign(:saml_form, saml_connection |> SSO.change_saml_connection() |> to_form(as: :saml))
  end

  # The secret never reaches the form, whatever the changeset holds.
  defp connection_form(changeset) do
    changeset
    |> Ecto.Changeset.delete_change(:client_secret)
    |> Map.update!(:data, &Map.put(&1, :client_secret, nil))
    |> to_form(as: :connection)
  end

  # Re-read the actor, their org-admin role and their paid access from the
  # database, as KanbanWeb.OrgLive.Security does, rather than trusting mount.
  defp with_org_admin(socket, fun) do
    %{current_scope: %{user: %{id: id}}, organization: organization} = socket.assigns

    with false <- socket.assigns.locked?,
         %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization.id),
         :ok <- SSO.check_access(actor, :live_view) do
      fun.(actor, organization.id)
    else
      _not_an_enabled_paid_org_admin -> {:noreply, refuse(socket)}
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

  defp domain_taken_message,
    do: gettext("Another Organization has already verified this domain.")

  defp record_name(domain), do: DomainVerification.record_name(domain)
  defp record_value(domain), do: DomainVerification.record_value(domain)

  defp verified({:ok, domain}, socket, organization_id) do
    {:noreply,
     socket
     |> load(organization_id)
     |> put_flash(:info, gettext("%{domain} is verified.", domain: domain.domain))}
  end

  defp verified({:error, :record_not_found}, socket, _organization_id) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "The TXT record was not found. DNS changes can take a while to appear; try again later."
       )
     )}
  end

  defp verified({:error, :domain_taken}, socket, _organization_id),
    do: {:noreply, put_flash(socket, :error, domain_taken_message())}

  defp verified({:error, :not_found}, socket, organization_id),
    do: {:noreply, load(socket, organization_id)}

  defp verified({:error, :unauthorized}, socket, _organization_id),
    do: {:noreply, refuse(socket)}
end
