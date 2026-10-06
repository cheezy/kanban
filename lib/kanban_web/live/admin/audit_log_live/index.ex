defmodule KanbanWeb.Admin.AuditLogLive.Index do
  @moduledoc """
  Site-admin viewer for the persisted audit trail (`Kanban.AuditLog`).

  Filters (action, actor email, from/to UTC dates) live in the URL: the filter
  form patches the query string and `handle_params/3` re-reads it, so a view is
  bookmarkable and the export links carry exactly the filters on screen. Pages
  are keyset-paginated (an opaque `cursor` param), never offset-scanned.

  Params are parsed strictly by `Kanban.AuditLog.Filters`; every query lives in
  the `Kanban.AuditLog` context.
  """
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares
  # `{KanbanWeb.UserAuth, :require_admin}` for this route, but we re-declare it
  # here so the LiveView itself cannot be reached by a non-admin even if the
  # route is ever re-grouped or the on_mount hook is dropped from the
  # live_session declaration.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Audit Log"))
     |> assign(:actions, AuditLog.list_actions())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    parsed = Filters.parse(params)
    page = AuditLog.list_events_page(parsed.filters, cursor: parsed.cursor, limit: @page_size)
    filter_params = Filters.summary(parsed)

    {:noreply,
     socket
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
    path = filter_params |> Filters.parse() |> Filters.summary() |> index_path()
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("filter", _params, socket), do: {:noreply, socket}

  defp index_path(params), do: ~p"/admin/audit-log?#{params}"

  defp export_path(params, format),
    do: ~p"/admin/audit-log/export?#{Map.put(params, "format", format)}"

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  defp metadata_json(metadata) when metadata == %{} or is_nil(metadata), do: ""
  defp metadata_json(metadata), do: Jason.encode!(metadata, pretty: true)

  # The actor's current email; for an actor whose account has since been
  # deleted (the foreign key nulled) the id kept in the metadata is shown.
  defp actor_label(%{actor_user: %{email: email}}), do: email

  defp actor_label(%{metadata: %{"user_id" => id}}) when is_integer(id),
    do: gettext("User #%{id} (deleted)", id: id)

  defp actor_label(_event), do: gettext("None")
end
