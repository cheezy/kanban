defmodule Kanban.ColumnsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Columns` context.
  """

  alias Kanban.Columns

  @doc """
  Generate a column for a given board.
  """
  def column_fixture(board, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Column #{System.unique_integer([:positive])}"
      })

    {:ok, column} = Columns.create_column(board, attrs)

    column
  end
end
