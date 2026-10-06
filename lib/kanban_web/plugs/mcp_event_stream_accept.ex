defmodule KanbanWeb.Plugs.McpEventStreamAccept do
  @moduledoc """
  Lets `GET` and `DELETE /api/mcp` answer `405` to an MCP client that asks for
  a server-sent-events stream (W2231).

  The MCP Streamable HTTP transport has a client open its optional SSE stream
  with `GET` and `Accept: text/event-stream`, and expects `405 Method Not
  Allowed` from a server that offers none. Every `/api` route sits behind
  `plug :accepts, ["json"]`, which would refuse that request with `406` before
  `KanbanWeb.API.McpController` could answer `405`. So, on these two routes
  only, an `Accept` header that names `text/event-stream` selects the JSON
  format through the `_format` param — which `Phoenix.Controller.accepts/2`
  reads before the header — and the request then authenticates and gets the
  `405` with its JSON-RPC body. Any other `Accept` value is left alone, so it
  is negotiated exactly as on every other `/api` route (a `text/html` request
  still gets `406`), and an explicit `_format` param is never overridden.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{params: %{"_format" => _format}} = conn, _opts), do: conn

  def call(%Plug.Conn{params: params} = conn, _opts)
      when is_map(params) and not is_struct(params) do
    if accepts_event_stream?(conn) do
      %{conn | params: Map.put(params, "_format", "json")}
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  @doc false
  def accepts_event_stream?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&event_stream?/1)
  end

  defp event_stream?(entry) do
    media_type = entry |> String.trim() |> Plug.Conn.Utils.media_type()
    match?({:ok, "text", "event-stream", _params}, media_type)
  end
end
