defmodule KanbanWeb.AuditLogExportController do
  @moduledoc """
  Site-admin download of the audit log as CSV or JSON, honouring the same
  filters as the `/admin/audit-log` viewer (`KanbanWeb.Admin.AuditLogLive.Index`).

  The route sits in the router's admin scope behind `:require_admin_user`; the
  plug is re-declared here as defense in depth, so the controller cannot serve
  audit data (emails, IPs) even if the route is ever re-grouped.

  Filter params are parsed strictly by `Kanban.AuditLog.Filters`; all querying
  and encoding live in the `Kanban.AuditLog` context. The body is sent chunked
  from `Kanban.AuditLog.export_stream/2`, which reads the table in keyset
  batches, so a large export is never loaded into memory at once. Every export
  is itself audited (`:audit_log_exported`) before the first byte is sent, so
  even an aborted download leaves a record.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_admin_user: 2]

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters

  plug :require_admin_user

  @content_types %{csv: "text/csv", json: "application/json"}

  def export(conn, params) do
    case export_format(params["format"]) do
      {:ok, format} ->
        send_export(conn, format, Filters.parse(params))

      :error ->
        conn
        |> put_flash(:error, gettext("Unsupported export format."))
        |> redirect(to: ~p"/admin/audit-log")
    end
  end

  defp export_format(nil), do: {:ok, :csv}
  defp export_format("csv"), do: {:ok, :csv}
  defp export_format("json"), do: {:ok, :json}
  defp export_format(_other), do: :error

  defp send_export(conn, format, parsed) do
    AuditLog.event(:audit_log_exported,
      user_id: conn.assigns.current_scope.user.id,
      ip: conn.remote_ip,
      format: Atom.to_string(format),
      filters: Filters.summary(parsed)
    )

    conn =
      conn
      |> put_resp_content_type(@content_types[format])
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{export_filename(format)}")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    parsed.filters
    |> AuditLog.export_stream(format)
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # A fixed token plus today's date — no user input ever reaches the header.
  defp export_filename(format), do: "audit_log_#{Date.utc_today()}.#{format}"
end
