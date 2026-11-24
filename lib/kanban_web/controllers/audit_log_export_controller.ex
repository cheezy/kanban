defmodule KanbanWeb.AuditLogExportController do
  @moduledoc """
  Site-admin download of the audit log as CSV or JSON, honouring the same
  filters as the `/admin/audit-log` viewer (`KanbanWeb.Admin.AuditLogLive.Index`).

  The route sits in the router's admin scope behind `:require_admin_user`; the
  plug is re-declared here as defense in depth, so the controller cannot serve
  audit data (emails, IPs) even if the route is ever re-grouped.

  Filter params are parsed strictly by `Kanban.AuditLog.Filters`; all querying
  and encoding live in the `Kanban.AuditLog` context. The body is sent chunked
  from `Kanban.AuditLog.export_stream/3`, which reads the table in keyset
  batches, so a large export is never loaded into memory at once. Every export
  is itself audited (`:audit_log_exported`) before the first byte is sent, so
  even an aborted download leaves a record.

  ## HEAD

  A `HEAD` request (`KanbanWeb.Plugs.HeadRequest`) gets the headers a `GET`
  would send and no body. Nothing is read, recorded or timed for it: no audit
  events are read, no `:audit_log_exported` row is written and no
  `[:kanban, :export]` span is emitted, because no file leaves the server. An
  unsupported format is refused as for `GET`, and `:require_admin_user` still
  runs first.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_admin_user: 2]

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters
  alias KanbanWeb.Plugs.HeadRequest

  plug :require_admin_user

  def export(conn, params) do
    case export_format(params["format"]) do
      {:ok, format} ->
        answer_export(conn, format, params, HeadRequest.head?(conn))

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

  # Only a request that arrived as HEAD skips the audit row and the stream;
  # Plug.Head has already rewritten its method to GET, so conn.method cannot
  # tell the two apart. The server drops a HEAD's body, so nothing is read,
  # recorded or timed for one.
  defp answer_export(conn, format, _params, true), do: send_head(conn, format)

  defp answer_export(conn, format, params, false),
    do: send_export(conn, format, Filters.parse(params))

  defp send_head(conn, format) do
    conn
    |> put_export_headers(format)
    |> send_resp(200, "")
  end

  defp send_export(conn, format, parsed) do
    AuditLog.event(:audit_log_exported,
      user_id: conn.assigns.current_scope.user.id,
      ip: conn.remote_ip,
      format: Atom.to_string(format),
      filters: Filters.summary(parsed)
    )

    # Timed as the [:kanban, :export] span. Unlike the audit event above, the
    # telemetry copy carries only the kind and format: never the filters,
    # which can contain an email, nor the admin's IP address.
    Kanban.Telemetry.span([:kanban, :export], %{kind: :audit_log, format: format}, fn ->
      {stream_export(conn, format, parsed), %{kind: :audit_log, format: format}}
    end)
  end

  defp stream_export(conn, format, parsed) do
    conn =
      conn
      |> put_export_headers(format)
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

  # The headers a GET streams under, shared with HEAD so the two cannot drift.
  defp put_export_headers(conn, format) do
    conn
    |> put_export_content_type(format)
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{export_filename(format)}")
    )
    |> put_resp_header("cache-control", "no-store")
  end

  # A literal content type per format. export_format/1 has already reduced the
  # request to :csv or :json, and naming each type here keeps the response type
  # fixed in code rather than looked up from a value (Sobelow XSS.ContentType).
  defp put_export_content_type(conn, :csv), do: put_resp_content_type(conn, "text/csv")

  defp put_export_content_type(conn, :json),
    do: put_resp_content_type(conn, "application/json")

  # A fixed token plus today's date — no user input ever reaches the header.
  defp export_filename(format), do: "audit_log_#{Date.utc_today()}.#{format}"
end
