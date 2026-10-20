defmodule KanbanWeb.API.BoardController do
  @moduledoc """
  `GET /api/boards` (W2220): the boards the request's API token can be used on.

  A board token sees its one board. A workspace token sees the boards of its
  workspace that its user can currently modify, which are the ids it may send
  in `X-Stride-Board` or `board_id`. The route is marked board-optional, so a
  workspace token needs no selector here, and this action never reads
  `:current_board`.

  A board token's user must still have access to its board
  (`KanbanWeb.API.BoardReadAccess`), or the request is refused with `403`.
  """
  use KanbanWeb, :controller

  alias Kanban.ApiTokens

  plug KanbanWeb.API.BoardReadAccess

  def index(conn, _params) do
    api_token = conn.assigns.api_token

    render(conn, :index,
      boards: ApiTokens.list_token_boards(api_token),
      token_scope: ApiTokens.token_scope(api_token)
    )
  end
end
