defmodule Kanban.BoardsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Boards` context.
  """

  import Ecto.Query

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.WorkspacesFixtures

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

  @doc """
  Moves a board into a new workspace of `organization`, which makes it a paid
  board. Boards from the fixtures above live in the owner's personal
  workspace, so they are free. Returns the reloaded board.
  """
  def move_board_to_organization(%Board{id: id}, organization) do
    workspace = WorkspacesFixtures.org_workspace_fixture(organization)

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, id)
  end
end
