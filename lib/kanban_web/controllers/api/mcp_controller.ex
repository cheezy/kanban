defmodule KanbanWeb.API.McpController do
  @moduledoc """
  The Model Context Protocol endpoint, `POST /api/mcp` (W2231).

  JSON-RPC 2.0 over the Streamable HTTP transport, JSON responses only. It
  sits in the authenticated `/api` scope, so the `:api` pipeline's Bearer
  token plug (with its failed-auth rate limiting) answers an unauthenticated
  request with `401` before any JSON-RPC handling happens, and every tool runs
  as the token's user on the token's board. Method dispatch lives in
  `KanbanWeb.MCP.Server`.

  Only an `application/json` body is accepted; any other content type is a
  JSON-RPC `-32600` with `400`.

  `GET` and `DELETE /api/mcp` return `405`: the server opens no SSE stream and
  keeps no session to end.

  An `Origin` header, when present, must name this server's own origin;
  anything else — another site, or a `null` origin — is refused with `403`,
  which stops a browser page from driving the endpoint (DNS rebinding).
  """
  use KanbanWeb, :controller

  alias KanbanWeb.MCP.JsonRpc
  alias KanbanWeb.MCP.Server

  plug :validate_origin
  plug :validate_protocol_version when action == :handle
  plug :require_json_content_type when action == :handle

  def handle(%Plug.Conn{private: %{kanban_mcp_parse_error: true}} = conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(JsonRpc.error(nil, JsonRpc.parse_error(), "Parse error"))
  end

  def handle(conn, _params) do
    case Server.handle_payload(conn.body_params, conn) do
      :accepted -> send_resp(conn, :accepted, "")
      {:reply, status, body} -> conn |> put_status(status) |> json(body)
    end
  end

  # One action per verb, both answering 405. A single action routed from both
  # GET and DELETE is the "action reuse" pattern Sobelow's Config.CSRFRoute
  # check flags, because a GET could then reach a state-changing handler.
  def get_not_allowed(conn, _params), do: method_not_allowed(conn)
  def delete_not_allowed(conn, _params), do: method_not_allowed(conn)

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(:method_not_allowed)
    |> json(JsonRpc.error(nil, JsonRpc.server_error(), "Method not allowed"))
  end

  defp validate_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] -> conn
      [origin] -> if allowed_origin?(origin), do: conn, else: forbidden_origin(conn)
      _several -> forbidden_origin(conn)
    end
  end

  # Compared against the endpoint's configured URL, never the request's Host
  # header: under DNS rebinding the Host header is the attacker's own name.
  @doc false
  def allowed_origin?(origin) when is_binary(origin) do
    expected = KanbanWeb.Endpoint.struct_url()

    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        scheme == expected.scheme and String.downcase(host) == String.downcase(expected.host) and
          port == expected.port

      _ ->
        false
    end
  end

  defp forbidden_origin(conn) do
    conn
    |> put_status(:forbidden)
    |> json(JsonRpc.error(nil, JsonRpc.server_error(), "Forbidden origin"))
    |> halt()
  end

  # The transport is JSON only. Plug.Parsers also decodes form and multipart
  # bodies, which would otherwise reach the dispatcher as a JSON-RPC message,
  # so anything but an application/json body is an invalid request.
  defp require_json_content_type(conn, _opts) do
    if json_content_type?(get_req_header(conn, "content-type")) do
      conn
    else
      conn
      |> put_status(:bad_request)
      |> json(
        JsonRpc.error(nil, JsonRpc.invalid_request(), "Content-Type must be application/json")
      )
      |> halt()
    end
  end

  defp json_content_type?([content_type]) do
    match?({:ok, "application", "json", _params}, Plug.Conn.Utils.media_type(content_type))
  end

  defp json_content_type?(_headers), do: false

  # The MCP-Protocol-Version header is optional (absent means the client is on
  # an older revision); a value this server cannot speak is a 400.
  defp validate_protocol_version(conn, _opts) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        conn

      [version] ->
        if String.trim(version) in Server.supported_versions(),
          do: conn,
          else: unsupported_protocol_version(conn)

      _several ->
        unsupported_protocol_version(conn)
    end
  end

  defp unsupported_protocol_version(conn) do
    conn
    |> put_status(:bad_request)
    |> json(JsonRpc.error(nil, JsonRpc.invalid_request(), "Unsupported MCP-Protocol-Version"))
    |> halt()
  end
end
