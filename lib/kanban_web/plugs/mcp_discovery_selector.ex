defmodule KanbanWeb.Plugs.McpDiscoverySelector do
  @moduledoc """
  Marks a `POST /api/mcp` request whose body holds only discovery messages
  (`KanbanWeb.MCP.Server.discovery_payload?/1`: `initialize`, `ping`,
  `tools/list`, notifications and client responses). Pipe it in before `:api`:
  `KanbanWeb.Plugs.AuthenticateApiToken` then lets a workspace token through
  without a board selector and assigns no `:current_board`, so an MCP client
  can connect and list the tools before it knows a board. A selector that is
  sent is still checked, and a body holding any `tools/call` gets no mark, so
  it needs a board as before.

  A body that failed to parse is never marked; the parser leaves it empty.
  """

  import Plug.Conn, only: [put_private: 3]

  alias KanbanWeb.MCP.Server

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%Plug.Conn{body_params: body} = conn, _opts) do
    if Server.discovery_payload?(body),
      do: put_private(conn, :stride_board_selector, :when_named),
      else: conn
  end
end
