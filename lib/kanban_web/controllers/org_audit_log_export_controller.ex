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

  Filter params are parsed by `Kanban.AuditLog.Filters.parse_for_organization/2`,
  the same function the viewer uses, so the same URL params give the same rows
  on the page and in the file. An action that no event of this Organization
  holds is dropped, as on the page: the filter is not applied, the file holds
  every event of the Organization up to the row cap, and neither the audit
  row's filters nor a signed manifest records that action. The known actions
  are read from the signed-in org-admin's own Organization, never a param, so
  the drop reveals nothing about another Organization. The actor-email filter
  is never applied (it would confirm a guessed email of a redacted outside
  actor). All querying and encoding live in the `Kanban.AuditLog` context. The
  body is sent chunked from `Kanban.AuditLog.export_stream/3`, which reads the
  table in keyset batches. Every export is itself audited
  (`:org_audit_log_exported`, linked to the Organization) before the first
  byte is sent, so even an aborted download leaves a record.

  ## Signed exports

  The `signed` param takes exactly two values. `signed=false`, like no
  `signed` param at all, gives the unsigned export. Any other value (`yes`,
  `1`, `TRUE`, an empty value, a value with spaces, a list) is refused: the
  request is redirected to `/org/audit` with a fixed flash that does not echo
  the value, whether or not signing is on. That is checked after the format
  and before the rate limit, so the refusal is not charged, and nothing is
  recorded. A `signed` param given more than once in the query string, such
  as `signed=true&signed=false`, is refused the same way, because Plug would
  keep only its last value. A request whose `signed` param asks for a
  signature therefore never gets an unsigned file silently. A misspelt param
  name, such as `sigend=true`, is not a `signed` param at all and gives the
  unsigned export.

  `signed=true` downloads one zip instead: the same CSV or JSON file, a
  `manifest.json` describing it, an Ed25519 signature over the manifest and a
  `README.txt` with the verification commands. `Kanban.AuditLog.with_signed_export/3`
  (`Kanban.AuditLog.SignedExport`) builds it in a temporary directory and
  removes that directory when the download ends or fails. It applies the same
  forced `organization_id`, the same redaction and the same row cap.

  The signed flow differs from the unsigned one in five ways:

    * **Signing off.** When this instance has no signing key the request is
      redirected to `/org/audit` with a flash. This is checked before the rate
      limit, so the refusal is not charged, and nothing is recorded.
    * **The audit row comes after the build.** The row carries `signed: true`,
      the `key_id` and the export file's `sha256`, which are known only once
      the file is written. It is still recorded before the first byte is sent.
      So a signed file never holds its own audit row, and `truncated` is what
      the build saw, not a count taken beforehand.
    * **The role is read again after the build.** A build takes long enough
      for the requester to be removed, moved to another Organization or
      disabled meanwhile. Such a requester gets no file: they are refused as
      the gate refuses them (`KanbanWeb.UserAuth.OrgAdminGate.recheck_conn/1`),
      with a `permission_denied` event and no export row. The request has
      already been charged against the rate limit.
    * **No `x-export-truncated` header.** The manifest is the record.
    * **A failed build** redirects to `/org/audit` with a flash and records
      nothing. It has already been charged against the rate limit.

  An unsigned export records `signed: false`.

  A signed download the client cancels ends normally: the closed connection
  is logged at info level by its transport reason alone, the temporary
  directory is removed and the audit row stays. That row records that a
  signed file was issued, not that it was received. A transport failure that
  is not a client closing, such as a file the server could not read, ends the
  same way but is logged at warning and reported to ErrorTracker. Any other
  failure during the send still raises.

  ## HEAD

  A `HEAD` request (`KanbanWeb.Plugs.HeadRequest`) gets the headers a `GET`
  would send and no body. Nothing is built, signed, charged against the rate
  limit or recorded for it, because no file leaves the server. An unsupported
  format, an invalid `signed` value, and a signed request while signing is
  off, are refused as for `GET`.

  ## Limits

    * **Row cap.** An export holds at most 50,000 rows, newest first
      (`config :kanban, KanbanWeb.OrgAuditLogExportController, max_rows: n`
      overrides it). A signed export reads one row past the cap instead of
      counting; see above. For an unsigned export, a
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
      format and the `signed` value are validated, so neither an unsupported
      format nor an invalid `signed` value is charged, and before
      the audit row and the stream, so a refused request writes nothing and
      opens no stream: it is redirected to `/org/audit` with a flash. Signed
      and unsigned exports share this one limit.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_org_admin_user: 2]

  alias Kanban.AuditLog
  alias Kanban.AuditLog.Filters
  alias Kanban.RateLimit
  alias KanbanWeb.Plugs.HeadRequest
  alias KanbanWeb.UserAuth.OrgAdminGate

  require Logger

  @default_max_rows 50_000

  # The posix reasons Bandit itself treats as a client going away
  # (deps/bandit/lib/bandit/logger.ex).
  @client_closure_reasons [:closed, :enotconn, :einval, :econnaborted, :econnreset]

  plug :require_org_admin_user

  def export(conn, params) do
    conn
    |> export_request(params, HeadRequest.head?(conn))
    |> answer_export(conn, params)
  end

  # The known actions come from the signed-in org-admin's own Organization,
  # never from a param, read per request exactly as the page's handle_params/3
  # reads them.
  defp answer_export({:ok, kind, format}, conn, params) do
    known_actions = AuditLog.list_actions(organization_id: conn.assigns.current_organization.id)
    parsed = Filters.parse_for_organization(params, known_actions)
    send_export(conn, kind, format, parsed)
  end

  defp answer_export({:head, kind, format}, conn, _params), do: send_head(conn, kind, format)
  defp answer_export({:error, reason}, conn, _params), do: refuse(conn, reason)

  # The order matters: the format, then the signed value and whether signing
  # is on, then the rate limit. So neither an unsupported format, an invalid
  # signed value nor a signed request made while signing is off is charged.
  defp export_request(conn, params, false) do
    with {:ok, format} <- export_format(params["format"]),
         {:ok, kind} <- export_kind(signed_param(conn, params)),
         :ok <- check_rate_limit(conn) do
      {:ok, kind, format}
    end
  end

  # A HEAD is refused as a GET would be for its format, for an invalid signed
  # value and for signing being off. Otherwise it is answered with the headers
  # alone: the server drops the body of a HEAD, so nothing is built, charged
  # or recorded for one.
  defp export_request(conn, params, true) do
    with {:ok, format} <- export_format(params["format"]),
         {:ok, kind} <- export_kind(signed_param(conn, params)) do
      {:head, kind, format}
    end
  end

  # Keyed on the signed-in org-admin only: no request param and no IP, so
  # varying params cannot dodge it and colleagues behind one NAT do not share it.
  # Signed and unsigned exports are charged against the same bucket.
  defp check_rate_limit(conn) do
    RateLimit.check(:org_audit_export, identity: "user:#{conn.assigns.current_scope.user.id}")
  end

  # Fixed messages only: no path, exception text or request value reaches the
  # flash.
  defp refuse(conn, reason) do
    conn
    |> put_flash(:error, refusal_message(reason))
    |> redirect(to: ~p"/org/audit")
  end

  defp refusal_message(:unsupported_format), do: gettext("Unsupported export format.")

  defp refusal_message(:invalid_signed),
    do: gettext("The signed parameter must be true or false.")

  defp refusal_message({:rate_limited, _retry_after_ms}),
    do: gettext("Too many exports. Try again later.")

  defp refusal_message(reason) when reason in [:signing_off, :not_configured],
    do: gettext("Signed exports are not set up on this server.")

  defp refusal_message(:build_failed),
    do: gettext("The signed export could not be built. Try again.")

  defp export_format(nil), do: {:ok, :csv}
  defp export_format("csv"), do: {:ok, :csv}
  defp export_format("json"), do: {:ok, :json}
  defp export_format(_other), do: {:error, :unsupported_format}

  # Only three forms are accepted: no param or "false" for an unsigned export,
  # and the exact value "true" for a signed one. Any other value, a list or a
  # map included, is refused whether or not signing is on, so a request that
  # asked for a signature never silently gets an unsigned file. Decided before
  # the rate limit, so neither refusal is charged.
  defp export_kind(nil), do: {:ok, :plain}
  defp export_kind("false"), do: {:ok, :plain}

  defp export_kind("true") do
    if AuditLog.signed_export_available?(), do: {:ok, :signed}, else: {:error, :signing_off}
  end

  defp export_kind(_other), do: {:error, :invalid_signed}

  # Plug keeps only the last of a repeated query key, so signed=true&signed=false
  # or signed[]=true&signed=false would read as "false". A repeated signed key,
  # bracketed or not, is therefore answered with
  # :repeated, which export_kind/1 refuses. The raw query string has already
  # been decoded once by Plug, so it is well formed here.
  defp signed_param(conn, params) do
    if repeated_signed?(conn.query_string), do: :repeated, else: params["signed"]
  end

  defp repeated_signed?(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.count(fn {key, _value} -> signed_key?(key) end)
    |> Kernel.>(1)
  end

  # Plug roots a bracketed key such as signed[] or signed[a] under the same
  # "signed" param, so those count as signed keys too. A key such as signed[
  # or signed[x, with no closing bracket, is a param of its own name to Plug,
  # so it is not counted.
  defp signed_key?("signed"), do: true
  defp signed_key?("signed[" <> rest), do: String.ends_with?(rest, "]")
  defp signed_key?(_key), do: false

  defp send_head(conn, kind, format) do
    conn
    |> put_head_content_type(kind, format)
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{head_filename(kind, format)}")
    )
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, "")
  end

  defp put_head_content_type(conn, :signed, _format),
    do: put_resp_content_type(conn, "application/zip")

  defp put_head_content_type(conn, :plain, format), do: put_export_content_type(conn, format)

  defp head_filename(:signed, _format), do: signed_filename()
  defp head_filename(:plain, format), do: export_filename(format)

  defp send_export(conn, :plain, format, parsed) do
    organization_id = conn.assigns.current_organization.id
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
      signed: false,
      filters: Filters.summary(parsed)
    )

    # Timed as the [:kanban, :export] span. The telemetry copy carries only the
    # kind and format: never the filters, which can contain an email, nor the
    # org-admin's IP address.
    Kanban.Telemetry.span([:kanban, :export], %{kind: :org_audit_log, format: format}, fn ->
      {stream_export(conn, format, filters, organization_id, max_rows, truncated),
       %{kind: :org_audit_log, format: format}}
    end)
  end

  # The span covers the build, the audit row and the download. Its format is
  # :zip whatever the file inside; a failed build still ends with a stop event.
  defp send_export(conn, :signed, format, parsed) do
    metadata = %{kind: :org_audit_log, format: :zip}

    Kanban.Telemetry.span([:kanban, :export], metadata, fn ->
      {send_signed_export(conn, format, parsed), metadata}
    end)
  end

  defp send_signed_export(conn, format, parsed) do
    case AuditLog.with_signed_export(
           parsed,
           signed_export_opts(conn, format),
           &deliver_signed_export(conn, &1, parsed)
         ) do
      {:ok, conn} -> conn
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # The Organization and the org-admin come from the session's assigns and the
  # host and key URL from this endpoint: no request param reaches the manifest
  # except the parsed filters.
  defp signed_export_opts(conn, format) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    [
      format: format,
      organization: %{id: organization.id, name: organization.name},
      generated_by: %{user_id: user.id, email: user.email},
      instance: KanbanWeb.Endpoint.host(),
      keys_url: url(~p"/.well-known/stride-audit-signing-keys"),
      max_rows: max_rows()
    ]
  end

  # Runs once the zip is built and while its temporary directory still exists.
  # A build can take long enough for the org-admin to be removed, moved or
  # disabled meanwhile, so the role is read again first: such a requester is
  # refused as the gate refuses them, and gets no file.
  defp deliver_signed_export(conn, archive, parsed) do
    case OrgAdminGate.recheck_conn(conn) do
      :ok -> record_and_send_signed_export(conn, archive, parsed)
      {:refused, conn} -> conn
    end
  end

  # The audit row is written first, so even an aborted download leaves a record
  # of which signed file was issued.
  defp record_and_send_signed_export(conn, archive, parsed) do
    AuditLog.event(:org_audit_log_exported,
      user_id: conn.assigns.current_scope.user.id,
      organization_id: conn.assigns.current_organization.id,
      ip: conn.remote_ip,
      format: Atom.to_string(archive.format),
      truncated: archive.truncated,
      signed: true,
      key_id: archive.key_id,
      sha256: archive.sha256,
      filters: Filters.summary(parsed)
    )

    send_zip(conn, archive.zip_path)
  end

  # The path is the zip Kanban.AuditLog.SignedExport has just built in its own
  # temporary directory; no request value reaches it. No x-export-truncated
  # header: the manifest inside the zip is the record.
  # A client that cancels the download makes Bandit's send_file raise
  # Bandit.TransportError; only that is rescued, so every other failure still
  # raises and reaches ErrorTracker.
  # sobelow_skip ["Traversal.SendDownload"]
  defp send_zip(conn, zip_path) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:file, zip_path},
      filename: signed_filename(),
      content_type: "application/zip",
      disposition: :attachment
    )
  rescue
    error in Bandit.TransportError -> end_cancelled_download(conn, error, __STACKTRACE__)
  end

  # Plug.Conn.send_file sets the conn's state only once the adapter has sent,
  # so this conn is still :unset, and Bandit raises Plug.Conn.NotSentError for
  # an :unset conn. :sent makes Bandit end the request and close the HTTP/1.1
  # connection without writing to it again. Only the reason is logged: never
  # the path, the requester's email or IP.
  defp end_cancelled_download(conn, %Bandit.TransportError{error: reason} = error, stacktrace) do
    report_cancelled_download(reason, error, stacktrace)
    %{conn | state: :sent}
  end

  defp report_cancelled_download(reason, _error, _stacktrace)
       when reason in @client_closure_reasons do
    Logger.info("signed audit export download ended: client closed (#{inspect(reason)})")
  end

  # Bandit raises the same error for a failure on the server's side of the
  # sendfile, such as a file it cannot open (:emfile, :enoent, :eacces), so
  # every other reason is still reported to ErrorTracker.
  defp report_cancelled_download(reason, error, stacktrace) do
    Logger.warning("signed audit export download failed: transport error (#{inspect(reason)})")
    ErrorTracker.report(error, stacktrace)
  end

  defp signed_filename, do: "org_audit_log_#{Date.utc_today()}_signed.zip"

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
