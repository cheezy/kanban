defmodule Kanban.BoardsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Boards` context.
  """

  alias Kanban.Boards

  @doc """
  Generate a board for a given user.
  """
  def board_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Board #{System.unique_integer([:positive])}",
        description: "A test board description"
      })

    {:ok, board} = Boards.create_board(user, attrs)

    board
  end
end
