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
  from `Kanban.AuditLog.export_stream/3`, which reads the table in keyset
  batches. Every export is itself audited (`:org_audit_log_exported`, linked to
  the Organization) before the first byte is sent, so even an aborted download
  leaves a record.

  ## Limits

    * **Row cap.** An export holds at most 50,000 rows, newest first
      (`config :kanban, KanbanWeb.OrgAuditLogExportController, max_rows: n`
      overrides it). A
      bounded count, which reads at most cap + 1 rows, decides before the
      audit row is written whether the cap will cut the file. A cut file
      carries an `x-export-truncated: true` header and the audit row records
      `truncated: true`; the CSV or JSON still ends cleanly, with no marker
      row. The export's own audit row leads its file when the filters admit
      it, so it counts toward the cap. An event written by someone else
      between that count and the first batch can still push the oldest row
      out without the flag; the cap itself always holds.
    * **Rate limit.** Each org-admin may export 10 times an hour (the
      `:org_audit_export` surface of `Kanban.RateLimit`, keyed on the
      signed-in user's id, never a request param). The check runs after the
      format is validated, so an unsupported format is not charged, and before
      the audit row and the stream, so a refused request writes nothing and
      opens no stream: it is redirected to `/org/audit` with a flash.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_org_admin_user: 2]

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters
  alias Kanban.RateLimit

  @default_max_rows 50_000

  plug :require_org_admin_user

  def export(conn, params) do
    with {:ok, format} <- export_format(params["format"]),
         :ok <- check_rate_limit(conn) do
      send_export(conn, format, Filters.parse(params))
    else
      :error ->
        refuse(conn, gettext("Unsupported export format."))

      {:error, {:rate_limited, _retry_after_ms}} ->
        refuse(conn, gettext("Too many exports. Try again later."))
    end
  end

  # Keyed on the signed-in org-admin only: no request param and no IP, so
  # varying params cannot dodge it and colleagues behind one NAT do not share it.
  defp check_rate_limit(conn) do
    RateLimit.check(:org_audit_export, identity: "user:#{conn.assigns.current_scope.user.id}")
  end

  defp refuse(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/org/audit")
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
    max_rows = max_rows()
    user_id = conn.assigns.current_scope.user.id
    truncated = truncated?(filters, max_rows, user_id)

    AuditLog.event(:org_audit_log_exported,
      user_id: user_id,
      organization_id: organization_id,
      ip: conn.remote_ip,
      format: Atom.to_string(format),
      truncated: truncated,
      filters: parsed |> Filters.summary() |> Map.delete("actor_email")
    )

    # Timed as the [:kanban, :export] span. The telemetry copy carries only the
    # kind and format: never the filters, which can contain an email, nor the
    # org-admin's IP address.
    Kanban.Telemetry.span([:kanban, :export], %{kind: :org_audit_log, format: format}, fn ->
      {stream_export(conn, format, filters, organization_id, max_rows, truncated),
       %{kind: :org_audit_log, format: format}}
    end)
  end

  # Decided before the audit row is written, so the row and the header agree.
  # That row leads the file whenever the filters admit it, so it is counted.
  defp truncated?(filters, max_rows, user_id) do
    AuditLog.export_truncated?(filters, max_rows, %{
      action: "org_audit_log_exported",
      organization_id: Keyword.fetch!(filters, :organization_id),
      actor_user_id: user_id,
      inserted_at: DateTime.utc_now()
    })
  end

  # A missing or invalid override falls back to the default, so the cap holds.
  defp max_rows do
    case :kanban |> Application.get_env(__MODULE__, []) |> Keyword.get(:max_rows) do
      rows when is_integer(rows) and rows > 0 -> rows
      _unset_or_invalid -> @default_max_rows
    end
  end

  defp stream_export(conn, format, filters, organization_id, max_rows, truncated) do
    conn =
      conn
      |> put_export_content_type(format)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{export_filename(format)}")
      )
      |> put_resp_header("cache-control", "no-store")
      |> put_truncated_header(truncated)
      |> send_chunked(200)

    filters
    |> AuditLog.export_stream(format, redact_actors_outside: organization_id, max_rows: max_rows)
    |> Enum.reduce_while(conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # Only a cut file carries the header; its value is a fixed literal.
  defp put_truncated_header(conn, true), do: put_resp_header(conn, "x-export-truncated", "true")
  defp put_truncated_header(conn, false), do: conn

  # A literal content type per format, fixed in code rather than looked up from
  # a value (Sobelow XSS.ContentType).
  defp put_export_content_type(conn, :csv), do: put_resp_content_type(conn, "text/csv")

  defp put_export_content_type(conn, :json),
    do: put_resp_content_type(conn, "application/json")

  # A fixed token plus today's date — no user input ever reaches the header.
  defp export_filename(format), do: "org_audit_log_#{Date.utc_today()}.#{format}"
end
