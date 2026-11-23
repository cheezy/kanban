defmodule KanbanWeb.Plugs.Parsers do
  @moduledoc """
  `Plug.Parsers` for the endpoint, with one change: a parse failure on an
  `/api` path renders its error as JSON (D353).

  `Plug.Parsers` runs in the endpoint, before the router, so the `:api_json`
  pipeline's `put_format "json"` has not run yet when it raises. A malformed
  query string such as `?a=%FF` (400), an oversized body (413) or an
  unsupported content type (415) would otherwise reach
  `Phoenix.Endpoint.RenderErrors` with no format set, and with `Accept: */*`,
  `text/html` or no `Accept` header the error would render as HTML, which an
  `/api` client must never get.

  `RenderErrors` renders with the conn that entered the endpoint, unless the
  exception is a `Plug.Conn.WrapperError`, in which case it uses the wrapped
  conn. So for `/api` paths this plug re-raises any failure as a
  `WrapperError` carrying the conn with its format pinned to json. The
  exception itself, and therefore the status, is unchanged.

  Which API a path belongs to is decided by `KanbanWeb.PathScope`, on the
  decoded segments the router matches, so a percent-encoded prefix such as
  `/%61pi/me` gets the same treatment as `/api/me`.

  On the agent API (`/api`) the pin is applied only when parsing fails. A
  request that parses cleanly leaves this plug with no format set, so the
  router decides the format as before, and an unrouted agent `/api` path
  still renders its HTML 404. Every path not named here is passed straight
  to `Plug.Parsers` and never gets the pin.

  `/scim` paths get the same treatment with the `scim` format, so their
  errors render as SCIM errors (`KanbanWeb.SCIM.ErrorJSON`, W2247).

  The audit signing keys address, `/.well-known/stride-audit-signing-keys`,
  gets the json pin too (W2697): curl and verifier libraries fetch it, and
  its own refusals are JSON.

  The device sign-in token API (`/oauth` and everything under it, except the
  browser's `/oauth/authorize` page, W2746) and the person API (`/api/me` and
  everything under it) are pinned to json **before** parsing (D462), not
  only when it fails. Their clients read every refusal as JSON, so a path no
  route matches there renders its 404 through `KanbanWeb.ErrorJSON` in that
  API's own error body, whatever the `Accept` header says. The pin does not
  change the format of a routed request: the router's `:api_json` pipeline
  sets json there anyway, and `plug :accepts` still answers a 406 for an
  `Accept` the API does not serve. The headers are set before parsing too,
  so every response there carries them, the errors raised before the
  controller included: `cache-control: no-store` and `pragma: no-cache`
  under `/oauth`, `cache-control: private, no-store` under `/api/me`, whose
  `:device_api` pipeline then sets the header of every response it sends
  (`KanbanWeb.Plugs.DeviceApiCacheControl`).

  The browser's authorize page (`/oauth/authorize` and the paths under it,
  D463) is a browser page, so it gets no format pin: its errors render in
  the format the `Accept` header asks for, as on every other browser path.
  It gets `cache-control: no-store` before parsing: RFC 6749 asks that
  authorization responses are not cached, and the answers given before
  `KanbanWeb.OAuthController` runs (the log-in redirect, the organization
  two-factor redirect, a wrong verb's 404, a malformed query's 400) would
  otherwise carry Plug's default `max-age=0, private, must-revalidate`. A
  parse failure there is re-raised as a `WrapperError` carrying that conn,
  so its 400 keeps the header, in whichever format it renders.

  One exception (W2231): a malformed JSON body on `POST /api/mcp` is not
  raised but flagged, so the MCP endpoint can answer it with a JSON-RPC
  `-32700` after authentication — see `parse_mcp/2`.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  # The scope is decided on decoded segments, as the router matches routes
  # (KanbanWeb.PathScope), so a percent-encoded prefix such as /%61pi/me is
  # treated exactly as /api/me.
  @impl Plug
  def call(conn, opts), do: conn |> KanbanWeb.PathScope.of() |> parse(conn, opts)

  # The person API (/api/me/*) is no-store (decided 2026-11-19): the router's
  # :device_api pipeline sets it on every response it sends
  # (KanbanWeb.Plugs.DeviceApiCacheControl), and setting it here, before
  # parsing, covers a parse failure and an unmatched /api/me path, which never
  # reach that pipeline. The json format is pinned before parsing too (D462),
  # so an /api/me path no route matches renders its 404 through
  # KanbanWeb.ErrorJSON whatever the Accept header says.
  defp parse(:device_api, conn, opts) do
    conn
    |> device_api_no_store()
    |> Phoenix.Controller.put_format("json")
    |> parse_pinning_failures("json", opts)
  end

  # The agent API: the json pin is applied only when parsing fails, so an
  # unrouted /api path still renders its HTML 404.
  defp parse(:api, conn, opts), do: parse_pinning_failures(conn, "json", opts)
  defp parse(:mcp, conn, opts), do: parse_pinning_failures(conn, "json", opts, &parse_mcp/2)

  # SCIM (W2247): a parse failure on /scim renders through
  # KanbanWeb.SCIM.ErrorJSON as an application/scim+json SCIM error, which is
  # what an identity provider expects.
  defp parse(:scim, conn, opts), do: parse_pinning_failures(conn, "scim", opts)

  # The audit signing keys address (W2697) is read by curl and verifier
  # libraries, not by a browser, so a parse failure there (a kid that is not
  # valid UTF-8, say) renders as JSON like the address's own 404, not as the
  # HTML error page.
  defp parse(:audit_signing_keys, conn, opts), do: parse_pinning_failures(conn, "json", opts)

  # The device sign-in token API (W2746) is called by the apps, which read
  # every refusal as JSON. Every response under /oauth must be
  # `cache-control: no-store` (RFC 6749 §5.1), so the headers are set before
  # parsing: an error raised here, or in the router before the controller's
  # own no_store plug runs, keeps them.
  # The json format is pinned before parsing (D462), so a parse failure or an
  # /oauth path no route matches renders through KanbanWeb.ErrorJSON's OAuth
  # error shape whatever the Accept header says.
  defp parse(:oauth, conn, opts) do
    conn
    |> oauth_no_store()
    |> Phoenix.Controller.put_format("json")
    |> parse_pinning_failures("json", opts)
  end

  # The browser's authorize page (D463): a browser page, so no format pin
  # (its errors follow the Accept header, as on every browser path), but every
  # response on it is no-store, the ones sent before OAuthController's own
  # harden_response plug included (the log-in and two-factor redirects, a
  # wrong verb's 404). The controller sets the same value again, so nothing it
  # sends is overridden.
  defp parse(:oauth_authorize, conn, opts) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> parse_keeping_conn(opts)
  end

  defp parse(:browser, conn, opts), do: Plug.Parsers.call(conn, opts)

  # Re-raises a parse failure as a WrapperError carrying the conn unchanged,
  # so RenderErrors renders it with the headers already set on it rather than
  # with the conn that entered the endpoint. No format is pinned.
  defp parse_keeping_conn(conn, opts) do
    Plug.Parsers.call(conn, opts)
  catch
    kind, reason -> Plug.Conn.WrapperError.reraise(conn, kind, reason, __STACKTRACE__)
  end

  # Re-raises a parse failure as a WrapperError carrying the conn with its
  # format pinned, so RenderErrors renders it in that format. The exception,
  # and therefore the status, is unchanged.
  defp parse_pinning_failures(conn, format, opts, parser \\ &Plug.Parsers.call/2) do
    parser.(conn, opts)
  catch
    kind, reason ->
      conn
      |> Phoenix.Controller.put_format(format)
      |> Plug.Conn.WrapperError.reraise(kind, reason, __STACKTRACE__)
  end

  defp oauth_no_store(conn) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_header("pragma", "no-cache")
  end

  defp device_api_no_store(conn),
    do: Plug.Conn.put_resp_header(conn, "cache-control", "private, no-store")

  # W2231: a malformed JSON body on POST /api/mcp must be answered with a
  # JSON-RPC -32700 Parse error, and only AFTER authentication (an
  # unauthenticated request gets the 401 before any JSON-RPC handling). So
  # for that one route, and only for `Plug.Parsers.ParseError`, the failure is
  # recorded in `conn.private[:kanban_mcp_parse_error]` instead of raised: the
  # body is replaced with an empty map (nothing downstream sees the bytes),
  # the second `Plug.Parsers.call/2` takes its already-parsed clause and only
  # merges the query params, and the request continues to the router, where
  # the `:api` pipeline authenticates it and `KanbanWeb.API.McpController`
  # answers -32700. Every other failure on that route — an oversized body
  # (413), an unsupported content type (415), a malformed query string — still
  # raises through `parse_pinning_failures/4` exactly as for every other /api path.
  defp parse_mcp(%Plug.Conn{method: "POST"} = conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      %{conn | body_params: %{}}
      |> Plug.Parsers.call(opts)
      |> Plug.Conn.put_private(:kanban_mcp_parse_error, true)
  end

  defp parse_mcp(conn, opts), do: Plug.Parsers.call(conn, opts)
end
