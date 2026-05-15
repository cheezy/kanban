defmodule KanbanWeb.BoardAccent do
  @moduledoc """
  Assigns a deterministic accent color to a board based on its position
  in the current user's board list.

  Both the Boards index (`KanbanWeb.BoardLive.Index`) and the per-board
  header (`KanbanWeb.BoardLive.Show`) use this helper so the colored
  identifier badge and any other accent surfaces stay consistent across
  the two views — the same board renders with the same accent on both
  pages without persisting the choice to the database.
  """

  alias Kanban.Boards

  @accents ~w(orange violet doing ready backlog blocked)a

  @doc "The ordered list of accent atoms, cycled through by position."
  def accents, do: @accents

  @doc """
  Round-robin a list of boards through the accent palette, stamping each
  board's `:accent` key with the resulting atom. Use for the index list
  where every board is rendered together.
  """
  def assign_to_boards(boards) when is_list(boards) do
    boards
    |> Enum.with_index()
    |> Enum.map(fn {board, index} -> Map.put(board, :accent, accent_at(index)) end)
  end

  @doc """
  Returns the accent atom for a single board by looking up its position
  in the user's full board list. Issues one `Boards.list_boards/1`
  query — used by the board show page where only one board is loaded.
  """
  def for_board(board, user) do
    boards = Boards.list_boards(user)
    idx = Enum.find_index(boards, &(&1.id == board.id)) || 0
    accent_at(idx)
  end

  defp accent_at(index), do: Enum.at(@accents, rem(index, length(@accents)))
end
