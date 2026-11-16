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
  the database first (`KanbanWeb.OrgLive.OrgAdminCheck`), and the `Kanban.SSO`
  write checks once more. A refused event is audited as `permission_denied`
  and redirects to `/boards`.

  The client secret is never sent to the browser: the form's secret field is
  always empty, and leaving it empty keeps the stored secret.

  Every form's params pass through `KanbanWeb.OrgLive.FormParams.scalar/2`
  before they reach a changeset (D441). A value that is not a string (a map,
  a list, an integer) would fail the cast and stay in the changeset params,
  and the re-rendered input would then crash the view, whose crash report
  prints the event
  payload, typed client secret included, at every log level. So such a value
  becomes blank and is treated exactly as an empty input: a required field
  reports it as blank, a blank secret or certificate keeps the stored one, and
  blank metadata is ignored. `enabled` is kept only as the `"true"` or
  `"false"` the checkbox sends. A form event whose `"domain"`,
  `"connection"` or `"saml"` param is missing or not a map cannot come from
  the page; it runs the same paid org-admin check and changes nothing.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.LockedFeature, only: [locked_feature: 1]
  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 3, refuse: 1]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.SSO
  alias Kanban.SSO.DomainRecheck
  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.SAML
  alias KanbanWeb.LocalTime
  alias KanbanWeb.OrgLive.FormParams

  require Logger

  @form_events ~w(add_domain validate_connection save_connection validate_saml save_saml)

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
  def handle_event("add_domain", %{"domain" => params}, socket) when is_map(params) do
    with_paid_org_admin(socket, fn actor, organization_id ->
      actor
      |> SSO.add_domain(organization_id, scalar_params(params))
      |> domain_added(socket, organization_id)
    end)
  end

  def handle_event("verify_domain", %{"id" => id}, socket) do
    with_paid_org_admin(socket, fn actor, organization_id ->
      actor
      |> SSO.verify_domain(organization_id, id)
      |> verified(socket, organization_id)
    end)
  end

  def handle_event("remove_domain", %{"id" => id}, socket) do
    with_paid_org_admin(socket, fn actor, organization_id ->
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

  def handle_event("validate_connection", %{"connection" => params}, socket)
      when is_map(params) do
    contained(socket, "validate", fn -> validate_connection(socket, scalar_params(params)) end)
  end

  def handle_event("save_connection", %{"connection" => params}, socket) when is_map(params) do
    contained(socket, "save", fn -> save_connection(socket, scalar_params(params)) end)
  end

  def handle_event("validate_saml", %{"saml" => params}, socket) when is_map(params) do
    with_paid_org_admin(socket, fn _actor, _organization_id ->
      form =
        socket.assigns.saml_connection
        |> SSO.change_saml_connection(scalar_params(params))
        |> Map.put(:action, :validate)
        |> to_form(as: :saml)

      {:noreply, assign(socket, :saml_form, form)}
    end)
  end

  def handle_event("save_saml", %{"saml" => params}, socket) when is_map(params) do
    with_paid_org_admin(socket, fn actor, organization_id ->
      actor
      |> SSO.save_saml_connection(organization_id, scalar_params(params))
      |> saml_saved(socket, organization_id)
    end)
  end

  # A form event whose form param is missing or not a map (a string, a list or
  # nil) would raise in the changeset cast or the Kanban.SSO guard. It cannot
  # come from the page, so it runs the paid org-admin check and does nothing.
  def handle_event(event, _params, socket) when event in @form_events do
    with_paid_org_admin(socket, fn _actor, _organization_id -> {:noreply, socket} end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Only strings reach a form's changeset and so its inputs (D441): a required
  # field reports a non-string value as blank and an optional one keeps or
  # ignores it. enabled, a checkbox, is kept only as "true" or "false".
  defp scalar_params(params), do: FormParams.scalar(params, ["enabled"])

  # A raise, exit or throw in the connection form's events would crash the
  # LiveView, and the crash report logs the last message, whose form payload
  # holds the typed client secret, which :filter_parameters does not reach
  # (D436). So it is contained here, as KanbanWeb.OrgLive.AuditStreamForm
  # does: only the exception's module (or the kind of failure) is logged and
  # reported to ErrorTracker, never its message or reason, which can quote
  # the values.
  defp contained(socket, event, fun) do
    fun.()
  catch
    kind, reason ->
      failure =
        "SSO connection form #{event} failed: #{failure_name(kind, reason, __STACKTRACE__)}"

      Logger.error(failure)
      report(failure, __STACKTRACE__)
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  defp failure_name(:error, reason, stacktrace),
    do: inspect(Exception.normalize(:error, reason, stacktrace).__struct__)

  defp failure_name(kind, _reason, _stacktrace), do: inspect(kind)

  # Reporting must not crash the view either (the store can be down), or the
  # payload would reach the crash report after all.
  defp report(failure, stacktrace) do
    ErrorTracker.report(%RuntimeError{message: failure}, stacktrace)
  catch
    _kind, _reason -> :ok
  end

  defp validate_connection(socket, params) do
    with_paid_org_admin(socket, fn _actor, _organization_id ->
      form =
        socket.assigns.connection
        |> SSO.change_oidc_connection(Map.delete(params, "client_secret"))
        |> Map.put(:action, :validate)
        |> connection_form()

      {:noreply, assign(socket, :connection_form, form)}
    end)
  end

  defp save_connection(socket, params) do
    with_paid_org_admin(socket, fn actor, organization_id ->
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
    |> Map.update!(:params, &drop_secret_param/1)
    |> to_form(as: :connection)
  end

  # A failed save's changeset keeps the typed params, secret included, in the
  # view state, where a later crash report would print them (D436).
  defp drop_secret_param(params) when is_map(params), do: Map.delete(params, "client_secret")
  defp drop_secret_param(params), do: params

  # Every event runs the shared org-admin check (KanbanWeb.OrgLive.OrgAdminCheck)
  # and also needs the page unlocked and the actor's paid access (Kanban.Plans,
  # feature :sso) re-read from the database.
  defp with_paid_org_admin(socket, fun), do: with_org_admin(socket, fun, also: &paid_access?/2)

  defp paid_access?(socket, actor),
    do: socket.assigns.locked? == false and SSO.check_access(actor, :live_view) == :ok

  defp domain_taken_message,
    do: gettext("Another Organization has already verified this domain.")

  defp record_name(domain), do: DomainVerification.record_name(domain)

  # A verified domain whose daily re-check has stopped finding its record.
  defp failing?(%{verified_at: %DateTime{}, failed_checks: failed}) when failed > 0, do: true
  defp failing?(_domain), do: false

  defp failing_message(domain) do
    remaining = DomainRecheck.misses_before_unverify() - domain.failed_checks

    ngettext(
      "Stride's daily check has not found this domain's TXT record since %{date}. Publish it again: if the next check does not find it either, the domain stops being verified and people on it can no longer use single sign-on.",
      "Stride's daily check has not found this domain's TXT record since %{date}. Publish it again: if the next %{count} checks do not find it either, the domain stops being verified and people on it can no longer use single sign-on.",
      remaining,
      date: LocalTime.format(domain.failing_since, :short_date)
    )
  end

  defp record_value(domain), do: DomainVerification.record_value(domain)

  defp domain_added({:ok, _domain}, socket, organization_id) do
    {:noreply,
     socket
     |> load(organization_id)
     |> put_flash(:info, gettext("Domain added. Publish its TXT record, then verify it."))}
  end

  defp domain_added({:error, :domain_taken}, socket, _organization_id),
    do: {:noreply, put_flash(socket, :error, domain_taken_message())}

  defp domain_added({:error, %Ecto.Changeset{} = changeset}, socket, _organization_id),
    do: {:noreply, assign(socket, :domain_form, to_form(changeset, as: :domain))}

  defp domain_added({:error, :unauthorized}, socket, _organization_id),
    do: {:noreply, refuse(socket)}

  defp saml_saved({:ok, _connection}, socket, organization_id) do
    {:noreply,
     socket |> load(organization_id) |> put_flash(:info, gettext("SAML connection saved."))}
  end

  defp saml_saved({:error, %Ecto.Changeset{} = changeset}, socket, _organization_id),
    do: {:noreply, assign(socket, :saml_form, to_form(changeset, as: :saml))}

  defp saml_saved({:error, :unauthorized}, socket, _organization_id),
    do: {:noreply, refuse(socket)}

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
