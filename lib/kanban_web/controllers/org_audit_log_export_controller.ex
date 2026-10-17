defmodule KanbanWeb.OrgAuditLogExportController do
  @moduledoc """
  Org-admin download of their Organization's audit log as CSV or JSON,
  honouring the same filters as the `/org/audit` viewer
  (`KanbanWeb.OrgLive.AuditLog`).

  The route's pipeline runs `require_org_admin_user`, and the plug is
  re-declared here as defense in depth. The plug assigns
  `current_organization` from the signed-in user's own membership, and the
  `organization_id` filter is forced from it: no request param can widen the
  export to another Organization's events. An event whose actor is not a
  member of the Organization, such as a site admin, is exported without that
  actor's id, email or IP address (`Kanban.AuditLog.OrganizationScope`).

  Filter params are parsed strictly by `Kanban.AuditLog.Filters`; all querying
  and encoding live in the `Kanban.AuditLog` context. The body is sent chunked
  from `Kanban.AuditLog.export_stream/2`, which reads the table in keyset
  batches. Every export is itself audited (`:org_audit_log_exported`, linked to
  the Organization) before the first byte is sent, so even an aborted download
  leaves a record.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_org_admin_user: 2]

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters

  plug :require_org_admin_user

  def export(conn, params) do
    case export_format(params["format"]) do
      {:ok, format} ->
        send_export(conn, format, Filters.parse(params))

      :error ->
        conn
        |> put_flash(:error, gettext("Unsupported export format."))
        |> redirect(to: ~p"/org/audit")
    end
  end

  defp export_format(nil), do: {:ok, :csv}
  defp export_format("csv"), do: {:ok, :csv}
  defp export_format("json"), do: {:ok, :json}
  defp export_format(_other), do: :error

  defp send_export(conn, format, parsed) do
    organization_id = conn.assigns.current_organization.id
    # No actor-email filter: it matches before outside actors are redacted, so
    # it would confirm a guessed email of a site admin.
    parsed = %{parsed | filters: Keyword.delete(parsed.filters, :actor_email)}
    filters = Keyword.put(parsed.filters, :organization_id, organization_id)

    AuditLog.event(:org_audit_log_exported,
      user_id: conn.assigns.current_scope.user.id,
      organization_id: organization_id,
      ip: conn.remote_ip,
      format: Atom.to_string(format),
      filters: parsed |> Filters.summary() |> Map.delete("actor_email")
    )

    # Timed as the [:kanban, :export] span. The telemetry copy carries only the
    # kind and format: never the filters, which can contain an email, nor the
    # org-admin's IP address.
    Kanban.Telemetry.span([:kanban, :export], %{kind: :org_audit_log, format: format}, fn ->
      {stream_export(conn, format, filters, organization_id),
       %{kind: :org_audit_log, format: format}}
    end)
  end

  defp stream_export(conn, format, filters, organization_id) do
    conn =
      conn
      |> put_export_content_type(format)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{export_filename(format)}")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    filters
    |> AuditLog.export_stream(format, redact_actors_outside: organization_id)
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # A literal content type per format, fixed in code rather than looked up from
  # a value (Sobelow XSS.ContentType).
  defp put_export_content_type(conn, :csv), do: put_resp_content_type(conn, "text/csv")

  defp put_export_content_type(conn, :json),
    do: put_resp_content_type(conn, "application/json")

  # A fixed token plus today's date — no user input ever reaches the header.
  defp export_filename(format), do: "org_audit_log_#{Date.utc_today()}.#{format}"
end
