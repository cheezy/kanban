defmodule Kanban.Tasks.BoardLookupTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.BoardLookup

  defp board_with_task do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
    {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})
    %{board: board, column: ready, task: task}
  end

  describe "get_task_with_column/2" do
    test "returns the board's task with only its column preloaded" do
      %{board: board, column: column, task: task} = board_with_task()

      found = BoardLookup.get_task_with_column(task.id, board.id)

      assert found.id == task.id
      assert found.column.id == column.id
      refute Ecto.assoc_loaded?(found.comments)
      refute Ecto.assoc_loaded?(found.task_histories)
    end

    test "returns nil for a task on another board or a missing id" do
      %{task: task} = board_with_task()
      %{board: other_board} = board_with_task()

      assert BoardLookup.get_task_with_column(task.id, other_board.id) == nil
      assert BoardLookup.get_task_with_column(-1, other_board.id) == nil
    end
  end

  describe "get_task_by_identifier_with_column/2" do
    test "returns the task with that identifier on this board, never another board's" do
      %{board: board, column: column, task: task} = board_with_task()
      %{board: other_board, task: other_task} = board_with_task()

      # Identifiers are numbered per board, so both boards have the same one.
      assert other_task.identifier == task.identifier

      found = BoardLookup.get_task_by_identifier_with_column(task.identifier, board.id)
      assert found.id == task.id
      assert found.column.id == column.id

      other = BoardLookup.get_task_by_identifier_with_column(task.identifier, other_board.id)
      assert other.id == other_task.id
    end

    test "returns nil for an unknown identifier" do
      %{board: board} = board_with_task()

      assert BoardLookup.get_task_by_identifier_with_column("W99999999", board.id) == nil
    end
  end
end
