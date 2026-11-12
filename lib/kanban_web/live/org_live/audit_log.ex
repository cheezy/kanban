defmodule KanbanWeb.OrgLive.AuditLog do
  @moduledoc """
  The org-admin audit log at `/org/audit`: the audit events of the signed-in
  org-admin's own Organization.

  It mirrors the site-admin viewer (`KanbanWeb.Admin.AuditLogLive.Index`):
  action and from/to UTC date filters live in the URL (the actor-email filter
  is left out, because it would confirm a guessed email of a redacted outside
  actor), `handle_params/3`
  re-reads them, pages are keyset-paginated by an opaque `cursor` param, and
  the export links carry exactly the filters on screen.

  The Organization filter is forced from `current_organization`, which the
  `:require_org_admin` gate assigns from the membership loaded into
  `current_scope`. It is never read from params, so adding an
  `organization_id` to the URL changes nothing. The action filter lists only
  actions that occur in this Organization's events. An event whose actor is
  not a member of the Organization, such as a site admin, shows no email or IP
  address (`Kanban.AuditLog.OrganizationScope`).

  Params are parsed strictly by `Kanban.AuditLog.Filters.parse_for_organization/2`,
  the same function the export (`KanbanWeb.OrgAuditLogExportController`) uses,
  so an action this Organization's events do not hold, and the actor-email
  filter, are dropped on the page and in its exports alike. Every query lives
  in the `Kanban.AuditLog` context.

  The signed export button and the signing key panel read the current key
  through `Kanban.AuditLog.Signing` once, in `mount/3`. Only the key id and
  fingerprint reach the socket, never the raw public key and never anything
  from the private seed. With signing off the button is disabled, a note says
  so and the panel is not rendered.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.AuditLogActions, only: [action_label: 1, action_options: 1]
  import KanbanWeb.AuditLogMetadata, only: [audit_metadata: 1]

  # The router's live_session :require_authenticated_user lets in every
  # signed-in user. Re-declaring the org-admin gate here keeps the audit log
  # closed to members, free users and site admins even if the route is moved.
  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters
  alias Kanban.AuditLog.Signing

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.current_organization

    {:ok,
     socket
     |> assign(:page_title, gettext("Organization audit log"))
     |> assign(:organization, organization)
     |> assign(:signing_key, signing_key())}
  end

  # The known actions are read on every handle_params/3, as the export reads
  # them on every request, so a page left open while the Organization's action
  # set changes still filters a patched URL exactly as its export links do.
  @impl true
  def handle_params(params, _url, socket) do
    organization_id = socket.assigns.organization.id
    actions = AuditLog.list_actions(organization_id: organization_id)
    parsed = Filters.parse_for_organization(params, actions)
    filters = Keyword.put(parsed.filters, :organization_id, organization_id)

    page =
      AuditLog.list_events_page(filters,
        cursor: parsed.cursor,
        limit: @page_size,
        redact_actors_outside: organization_id
      )

    filter_params = Filters.summary(parsed)

    {:noreply,
     socket
     |> assign(:actions, actions)
     |> assign(:filter_params, filter_params)
     |> assign(:paged?, parsed.cursor != nil)
     |> assign(:next_cursor, page.next_cursor)
     |> assign(:empty?, page.entries == [])
     |> assign(:form, to_form(filter_params, as: :filters))
     |> stream(:events, page.entries, reset: true)}
  end

  # Any filter change starts again from the newest page: the form carries no
  # cursor, so the patched URL drops it.
  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    path =
      filter_params
      |> Filters.parse_for_organization(socket.assigns.actions)
      |> Filters.summary()
      |> index_path()

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("filter", _params, socket), do: {:noreply, socket}

  defp index_path(params), do: ~p"/org/audit?#{params}"

  defp export_path(params, format),
    do: ~p"/org/audit/export?#{Map.put(params, "format", format)}"

  # The signed export is a CSV in a zip. Like the other export links it
  # carries only the filters on screen, never the page cursor.
  defp signed_export_path(params),
    do: ~p"/org/audit/export?#{params |> Map.put("format", "csv") |> Map.put("signed", "true")}"

  defp signing_keys_path, do: ~p"/.well-known/stride-audit-signing-keys"

  defp signing_key_pem_path(%{key_id: key_id}),
    do: ~p"/.well-known/stride-audit-signing-keys?#{%{"format" => "pem", "kid" => key_id}}"

  # Public key material only: the raw public key bytes are not needed to
  # render the panel, so they never enter the socket.
  defp signing_key do
    case Signing.current_key() do
      %{key_id: key_id, fingerprint: fingerprint} -> %{key_id: key_id, fingerprint: fingerprint}
      nil -> nil
    end
  end

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  # An actor who is not a member of this Organization (a site admin who
  # created it or appointed its org-admins) is never identified to the org-admin.
  defp actor_label(%{actor_redacted: true}), do: gettext("Outside your Organization")

  # The actor's current email; for an actor whose account has since been
  # deleted (the foreign key nulled) the id kept in the metadata is shown.
  defp actor_label(%{actor_user: %{email: email}}), do: email

  defp actor_label(%{metadata: %{"user_id" => id}}) when is_integer(id),
    do: gettext("User #%{id} (deleted)", id: id)

  defp actor_label(_event), do: pgettext("audit log actor", "None")
end
