defmodule KanbanWeb.OrgLive.SCIM do
  @moduledoc """
  The org-admin SCIM provisioning page at `/org/scim` (W2247): the SCIM base
  URL to give the identity provider, the form that creates an
  Organization-scoped SCIM token, the new token's plain text shown once, and
  the Organization's tokens with revoke.

  The Organization comes from `current_organization`, which the
  `:require_org_admin` gate assigns from the signed-in user's own membership;
  it is never read from params. `current_scope` is loaded once at mount and an
  event does not run the gate again, so `validate`, `create_token` and
  `revoke_token` re-read the actor and their org-admin role from the database
  first, and `Kanban.SCIM` checks once more. A refused event is audited as
  `permission_denied` and redirects to `/boards`. `dismiss_token` only clears
  the revealed token from the page, and any other event is ignored, so
  neither needs the check.

  The plain text is held only in the `:new_token` assign: never in a form,
  cleared by the next event, and gone after a reload.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.SCIM
  alias Kanban.SCIM.ScimToken

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization

    {:ok,
     socket
     |> assign(:page_title, gettext("SCIM provisioning"))
     |> assign(:organization, organization)
     |> assign(:base_url, base_url())
     |> assign(:new_token, nil)
     |> assign(:form, to_form(SCIM.change_token(), as: :token))
     |> load_tokens()}
  end

  @impl true
  def handle_event("validate", %{"token" => params}, socket) do
    with_org_admin(socket, fn _actor, _organization_id ->
      form = params |> SCIM.change_token() |> Map.put(:action, :validate) |> to_form(as: :token)
      {:noreply, socket |> assign(:new_token, nil) |> assign(:form, form)}
    end)
  end

  def handle_event("create_token", %{"token" => params}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      actor |> SCIM.create_token(organization_id, params) |> token_created(socket)
    end)
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    with_org_admin(socket, fn actor, organization_id ->
      case SCIM.revoke_token(actor, organization_id, id) do
        {:ok, _token} ->
          {:noreply,
           socket
           |> assign(:new_token, nil)
           |> load_tokens()
           |> put_flash(:info, gettext("Token revoked."))}

        {:error, :not_found} ->
          {:noreply, socket |> assign(:new_token, nil) |> load_tokens()}

        {:error, :unauthorized} ->
          {:noreply, refuse(socket)}
      end
    end)
  end

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, :new_token, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp token_created({:ok, {_token, plaintext}}, socket) do
    {:noreply,
     socket
     |> assign(:new_token, plaintext)
     |> assign(:form, to_form(SCIM.change_token(), as: :token))
     |> load_tokens()}
  end

  defp token_created({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply,
     socket
     |> assign(:new_token, nil)
     |> assign(:form, to_form(Map.put(changeset, :action, :insert), as: :token))}
  end

  defp token_created({:error, :unauthorized}, socket), do: {:noreply, refuse(socket)}

  # The SCIM routes are /scim/v2/<resource>, so the base is one of them less
  # its resource name, which keeps the URL verified.
  defp base_url, do: url(~p"/scim/v2/Users") |> String.replace_suffix("/Users", "")

  defp load_tokens(socket) do
    assign(socket, :tokens, SCIM.list_tokens(socket.assigns.organization.id))
  end

  # Re-read the actor and their org-admin role from the database, as
  # KanbanWeb.OrgLive.SSO does, rather than trusting mount.
  defp with_org_admin(socket, fun) do
    %{current_scope: %{user: %{id: id}}, organization: organization} = socket.assigns

    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization.id) do
      fun.(actor, organization.id)
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
    |> assign(:new_token, nil)
    |> put_flash(
      :error,
      gettext("You must be an org-admin of an Organization to access this page.")
    )
    |> redirect(to: ~p"/boards")
  end

  defp token_details(%ScimToken{} = token) do
    gettext("By %{creator} · created %{created} · last used %{used}",
      creator: creator(token),
      created: date(token.inserted_at),
      used: date(token.last_used_at)
    )
  end

  defp creator(%ScimToken{created_by: %User{name: name}}) when is_binary(name) and name != "",
    do: name

  defp creator(%ScimToken{created_by: %User{email: email}}), do: email
  defp creator(_token), do: "—"

  defp date(nil), do: gettext("never")
  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
end
