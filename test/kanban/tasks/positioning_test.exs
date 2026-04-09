defmodule Kanban.Tasks.PositioningTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Positioning

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  describe "get_next_position/1" do
    test "returns 0 for empty column", %{column: column} do
      assert Positioning.get_next_position(column) == 0
    end

    test "returns max position + 1", %{column: column} do
      _task1 = task_fixture(column)
      _task2 = task_fixture(column)

      assert Positioning.get_next_position(column) == 2
    end
  end

  describe "get_next_position_locked/1" do
    test "returns 0 for empty column", %{column: column} do
      result =
        Repo.transaction(fn ->
          Positioning.get_next_position_locked(column)
        end)

      assert {:ok, 0} = result
    end

    test "returns max position + 1", %{column: column} do
      _task1 = task_fixture(column)
      _task2 = task_fixture(column)

      result =
        Repo.transaction(fn ->
          Positioning.get_next_position_locked(column)
        end)

      assert {:ok, 2} = result
    end

    test "serializes concurrent position allocations", %{column: column} do
      # Launch two concurrent tasks that each lock, read, and insert
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Repo.transaction(fn ->
              pos = Positioning.get_next_position_locked(column)

              Repo.insert!(%Kanban.Tasks.Task{
                title: "Concurrent Task",
                column_id: column.id,
                position: pos,
                type: :work,
                priority: :medium
              })

              pos
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Both should succeed with different positions
      positions = Enum.map(results, fn {:ok, pos} -> pos end)
      assert length(Enum.uniq(positions)) == 2
    end
  end
end
