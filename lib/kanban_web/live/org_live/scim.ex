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
  first (`KanbanWeb.OrgLive.OrgAdminCheck`), and `Kanban.SCIM` checks once
  more. A refused event is audited as `permission_denied` and redirects to
  `/boards`. `dismiss_token` only clears the revealed token from the page, and
  any other event is ignored, so neither needs the check.

  The plain text is held only in the `:new_token` assign: never in a form,
  cleared by the next event, and gone after a reload. It is wrapped in a
  `ShownToken`, whose `Inspect` implementation prints no fields, so a crash
  report or anything else that inspects the LiveView's state does not print it
  (D437). Formatting that bypasses `Inspect` (`structs: false`, Erlang `~p`)
  would still show it. A `validate` or `create_token`
  event whose `"token"` param is missing or not a map cannot come from the
  page's form; it runs the same org-admin check, clears the revealed token and
  changes nothing else, rather than crashing the view.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 3, refuse: 2]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts.User
  alias Kanban.SCIM
  alias Kanban.SCIM.ScimToken
  alias KanbanWeb.LocalTime

  defmodule ShownToken do
    @moduledoc """
    A new SCIM token's plain text, shown once after creation. Its `Inspect`
    implementation prints no fields, so a crash report that inspects the
    LiveView's state, as one at the `:debug` level does, does not print it
    (D437).
    """
    @derive {Inspect, only: []}
    @enforce_keys [:value]
    defstruct [:value]
  end

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
  def handle_event("validate", %{"token" => params}, socket) when is_map(params) do
    with_scim_org_admin(socket, fn _actor, _organization_id ->
      form =
        params
        |> token_params()
        |> SCIM.change_token()
        |> Map.put(:action, :validate)
        |> to_form(as: :token)

      {:noreply, socket |> assign(:new_token, nil) |> assign(:form, form)}
    end)
  end

  def handle_event("create_token", %{"token" => params}, socket) when is_map(params) do
    with_scim_org_admin(socket, fn actor, organization_id ->
      actor |> SCIM.create_token(organization_id, token_params(params)) |> token_created(socket)
    end)
  end

  # A token form event whose "token" is missing or not a map (a string, a list
  # or nil) would raise in the changeset cast. It still runs the org-admin
  # check and clears the revealed token, as the form's own events do.
  def handle_event(event, _params, socket) when event in ["validate", "create_token"] do
    with_scim_org_admin(socket, fn _actor, _organization_id ->
      {:noreply, assign(socket, :new_token, nil)}
    end)
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    with_scim_org_admin(socket, fn actor, organization_id ->
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
          {:noreply, refuse(socket, refuse_opts())}
      end
    end)
  end

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, :new_token, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The form has one text field. A name that is not a string (a map, say)
  # would fail the cast and then crash the re-rendered input, so it is
  # dropped and the form reports the name as blank.
  defp token_params(%{"name" => name}) when is_binary(name), do: %{"name" => name}
  defp token_params(_params), do: %{"name" => ""}

  defp token_created({:ok, {_token, plaintext}}, socket) do
    {:noreply,
     socket
     |> assign(:new_token, %ShownToken{value: plaintext})
     |> assign(:form, to_form(SCIM.change_token(), as: :token))
     |> load_tokens()}
  end

  defp token_created({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply,
     socket
     |> assign(:new_token, nil)
     |> assign(:form, to_form(Map.put(changeset, :action, :insert), as: :token))}
  end

  defp token_created({:error, :unauthorized}, socket),
    do: {:noreply, refuse(socket, refuse_opts())}

  # The SCIM routes are /scim/v2/<resource>, so the base is one of them less
  # its resource name, which keeps the URL verified.
  defp base_url, do: url(~p"/scim/v2/Users") |> String.replace_suffix("/Users", "")

  defp load_tokens(socket) do
    assign(socket, :tokens, SCIM.list_tokens(socket.assigns.organization.id))
  end

  # Every event runs the shared org-admin check (KanbanWeb.OrgLive.OrgAdminCheck),
  # and every refusal also clears the revealed token, so a refused actor never
  # keeps the plain text on the page.
  defp with_scim_org_admin(socket, fun), do: with_org_admin(socket, fun, refuse_opts())

  defp refuse_opts, do: [on_refuse: &assign(&1, :new_token, nil)]

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
  defp date(%DateTime{} = datetime), do: LocalTime.format(datetime, :short_date)
end
