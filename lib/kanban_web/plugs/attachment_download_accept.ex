defmodule KanbanWeb.Plugs.AttachmentDownloadAccept do
  @moduledoc """
  Lets `GET /api/tasks/:id/attachments/:attachment_id` serve a client
  whatever its `Accept` header says.

  Every `/api` route sits behind `plug :accepts, ["json"]`, which answers
  `406` to an `Accept` header that names no JSON-compatible type. A
  download's body is the file's own bytes, never JSON, and HTTP clients
  fetching a file commonly send `Accept: application/octet-stream` or the
  file's own type, so on this route the header is not negotiated: the JSON
  format is selected through the `_format` param, which
  `Phoenix.Controller.accepts/2` reads before the header. The bytes are
  sent with the stored content type and every error still renders as the
  API's JSON body. An explicit `_format` param is never overridden, so a
  request asking for another format through it still gets the `406`.

  The same `_format` mechanism lets `GET /api/mcp` through
  (`KanbanWeb.Plugs.McpEventStreamAccept`).
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{params: %{"_format" => _format}} = conn, _opts), do: conn

  def call(%Plug.Conn{params: params} = conn, _opts)
      when is_map(params) and not is_struct(params),
      do: %{conn | params: Map.put(params, "_format", "json")}

  def call(conn, _opts), do: conn
end
