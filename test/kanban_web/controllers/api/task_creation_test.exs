defmodule KanbanWeb.API.TaskCreationTest do
  @moduledoc """
  The default column a task lands in when `POST /api/tasks` (or a batch goal)
  sends no `column_id` (D400). docs/api/post_tasks.md, post_tasks_batch.md and
  AI-WORKFLOW.md describe this chain: Backlog, then Ready, then the board's
  first column.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Columns
  alias KanbanWeb.API.TaskCreation

  setup do
    user = user_fixture()
    board = board_fixture(user)
    assert Columns.list_columns(board) == []
    %{board: board}
  end

  describe "get_default_column_id/1" do
    test "picks the column named Backlog even when it is not first", %{board: board} do
      column_fixture(board, %{name: "Ready"})
      backlog = column_fixture(board, %{name: "Backlog"})

      assert TaskCreation.get_default_column_id(board) == backlog.id
    end

    test "falls back to the column named Ready when the board has no Backlog", %{board: board} do
      column_fixture(board, %{name: "Doing"})
      ready = column_fixture(board, %{name: "Ready"})

      assert TaskCreation.get_default_column_id(board) == ready.id
    end

    test "falls back to the board's first column when it has neither", %{board: board} do
      first = column_fixture(board, %{name: "Ideas"})
      column_fixture(board, %{name: "Doing"})

      assert TaskCreation.get_default_column_id(board) == first.id
    end

    test "an AI-optimized board defaults to its Backlog column" do
      board = ai_optimized_board_fixture(user_fixture())
      backlog = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Backlog"))

      assert TaskCreation.get_default_column_id(board) == backlog.id
    end
  end
end
