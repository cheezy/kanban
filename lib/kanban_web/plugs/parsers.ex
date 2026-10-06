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

  The pin is applied only when parsing fails. A request that parses cleanly
  leaves this plug with no format set, so the router decides the format as
  before, and an unrouted `/api` path still renders its HTML 404. Non-`/api`
  paths are passed straight to `Plug.Parsers` and never get the pin.

  One exception (W2231): a malformed JSON body on `POST /api/mcp` is not
  raised but flagged, so the MCP endpoint can answer it with a JSON-RPC
  `-32700` after authentication — see `parse_api/2`.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, opts) do
    parse_api(conn, opts)
  catch
    kind, reason ->
      conn
      |> Phoenix.Controller.put_format("json")
      |> Plug.Conn.WrapperError.reraise(kind, reason, __STACKTRACE__)
  end

  def call(conn, opts), do: Plug.Parsers.call(conn, opts)

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
  # raises through the `catch` above exactly as for every other /api path.
  defp parse_api(%Plug.Conn{method: "POST", path_info: ["api", "mcp"]} = conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      %{conn | body_params: %{}}
      |> Plug.Parsers.call(opts)
      |> Plug.Conn.put_private(:kanban_mcp_parse_error, true)
  end

  defp parse_api(conn, opts), do: Plug.Parsers.call(conn, opts)
end
