defmodule Kanban.ColumnsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Columns` context.
  """

  alias Kanban.Boards
  alias Kanban.Columns

  @doc """
  Generate a column for a given board.

  `Columns.create_column/3` is owner-authorized, so the fixture resolves the
  board's owner itself — callers (including tests that deliberately bind a
  non-owner `user` variable) don't need to pass one.
  """
  def column_fixture(board, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Column #{System.unique_integer([:positive])}"
      })

    {:ok, column} = Columns.create_column(board, attrs, board_owner(board))

    column
  end

  defp board_owner(board) do
    %{user: owner} =
      board
      |> Boards.list_board_users()
      |> Enum.find(&(&1.access == :owner))

    owner
  end
end
