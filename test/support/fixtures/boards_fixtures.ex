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

  @doc """
  Generate an AI optimized board for a given user.
  """
  def ai_optimized_board_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "AI Board #{System.unique_integer([:positive])}",
        description: "An AI optimized board"
      })

    {:ok, board} = Boards.create_ai_optimized_board(user, attrs)

    board
  end
end
