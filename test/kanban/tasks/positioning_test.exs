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

  defp archive!(task) do
    Kanban.Tasks.Task
    |> where([x], x.id == ^task.id)
    |> Repo.update_all(set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    task
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

  describe "WIP limit excludes archived tasks" do
    test "can_add_task? does not count archived tasks toward the WIP limit", %{board: board} do
      col = column_fixture(board, %{wip_limit: 2})

      # Two ARCHIVED work tasks occupy the column (raw count == limit).
      for _ <- 1..2, do: col |> task_fixture() |> archive!()

      # Live count is 0, so a new task can still be added.
      assert Positioning.can_add_task?(col)
    end

    test "move_task into a WIP-limited column ignores archived tasks", %{board: board} do
      src = column_fixture(board, %{name: "Src"})
      dst = column_fixture(board, %{name: "Dst", wip_limit: 2})

      # Two ARCHIVED work tasks in the destination (raw count == limit).
      for _ <- 1..2, do: dst |> task_fixture() |> archive!()

      mover = task_fixture(src)

      # Live count in dst is 0, so the move succeeds.
      assert {:ok, _} = Kanban.Tasks.move_task(mover, dst, 0)
    end

    test "move_task is still rejected when the live count is at the WIP limit", %{board: board} do
      src = column_fixture(board, %{name: "Src2"})
      dst = column_fixture(board, %{name: "Dst2", wip_limit: 1})

      _live = task_fixture(dst)
      mover = task_fixture(src)

      assert {:error, :wip_limit_reached} = Kanban.Tasks.move_task(mover, dst, 0)
    end
  end
end
