defmodule KanbanWeb.Plugs.HeadRequest do
  @moduledoc """
  Remembers that a request arrived as `HEAD`, for the endpoint plugs after
  `Plug.Head`, which rewrites a `HEAD` into a `GET` so it can match the GET
  routes. Plug it immediately before `Plug.Head`.

  A controller that streams a body asks `head?/1`, so it can send the GET
  headers without reading the body the server will drop anyway
  (`KanbanWeb.AttachmentController`).
  """
  @behaviour Plug

  import Plug.Conn, only: [put_private: 3]

  @key :kanban_head_request

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "HEAD"} = conn, _opts), do: put_private(conn, @key, true)
  def call(conn, _opts), do: conn

  @doc "`true` when the request arrived as `HEAD`, before `Plug.Head` turned it into a `GET`."
  @spec head?(Plug.Conn.t()) :: boolean()
  def head?(%Plug.Conn{private: private}), do: Map.get(private, @key, false)
end
