defmodule KanbanWeb.API.BoardJSON do
  @moduledoc """
  JSON rendering for `GET /api/boards` (W2220).
  """

  alias Kanban.Boards.Board

  @doc """
  The boards a token can be used on, with `meta.token_scope` (`"board"` or
  `"workspace"`).
  """
  def index(%{boards: boards, token_scope: token_scope}) do
    %{data: Enum.map(boards, &board/1), meta: %{token_scope: token_scope}}
  end

  @doc """
  The rendered fields of one board.
  """
  def board(%Board{} = board) do
    %{
      id: board.id,
      name: board.name,
      description: board.description,
      workspace_id: board.workspace_id
    }
  end
end
