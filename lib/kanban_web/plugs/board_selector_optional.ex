defmodule KanbanWeb.Plugs.BoardSelectorOptional do
  @moduledoc """
  Marks an API route that does not act on one board, such as `GET /api/boards`
  (W2220). Pipe it in before `:api`: `KanbanWeb.Plugs.AuthenticateApiToken`
  then lets a workspace token through without a board selector and assigns no
  `:current_board`. Every other API route is board-bound.
  """

  import Plug.Conn, only: [put_private: 3]

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: put_private(conn, :stride_board_selector, :optional)
end
