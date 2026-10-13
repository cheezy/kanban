defmodule Kanban.Tasks.GoalTargetColumnTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.GoalTargetColumn
  alias Kanban.Tasks.Task

  # Creating or moving a child re-places its goal, so tests put rows exactly
  # where they need them with a direct write.
  defp put!(task, fields) do
    from(t in Task, where: t.id == ^task.id) |> Repo.update_all(set: fields)
    Repo.reload!(task)
  end

  defp board_with_columns(names) do
    board = board_fixture(user_fixture())
    columns = Enum.map(names, &column_fixture(board, %{name: &1}))
    {board, columns}
  end

  describe "resolve/1" do
    test "returns the Done column when every child is done" do
      {_board, [ready, doing, done]} = board_with_columns(["Ready", "Doing", "Done"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      in_done = task_fixture(ready, %{title: "In Done", parent_id: goal.id})
      completed = task_fixture(ready, %{title: "Completed", parent_id: goal.id})
      put!(in_done, column_id: done.id)
      # A :completed child counts as done wherever it sits.
      put!(completed, column_id: doing.id, status: :completed)
      goal = put!(goal, column_id: ready.id)

      assert {:ok, %Task{id: goal_id}, target} = GoalTargetColumn.resolve(in_done)
      assert goal_id == goal.id
      assert target.id == done.id
    end

    test "holds the goal in its current column while after_goal is pending" do
      {_board, [ready, doing, done]} = board_with_columns(["Ready", "Doing", "Done"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      child = put!(child, column_id: done.id)
      put!(goal, column_id: doing.id, after_goal_status: :pending)

      assert {:ok, _goal, target} = GoalTargetColumn.resolve(child)
      assert target.id == doing.id
    end

    test "picks the leftmost child column when children are spread across columns" do
      {_board, [backlog, ready, doing, done]} =
        board_with_columns(["Backlog", "Ready", "Doing", "Done"])

      goal = task_fixture(backlog, %{title: "Goal", type: :goal})
      left = task_fixture(backlog, %{title: "Left", parent_id: goal.id})
      right = task_fixture(backlog, %{title: "Right", parent_id: goal.id})
      finished = task_fixture(backlog, %{title: "Finished", parent_id: goal.id})
      put!(left, column_id: ready.id)
      right = put!(right, column_id: doing.id)
      put!(finished, column_id: done.id)
      put!(goal, column_id: backlog.id)

      assert {:ok, _goal, target} = GoalTargetColumn.resolve(right)
      assert target.id == ready.id
    end

    test "never targets Done on a board without a Done column" do
      {_board, [ready, doing]} = board_with_columns(["Ready", "Doing"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      child = put!(child, column_id: doing.id, status: :completed)
      put!(goal, column_id: ready.id)

      assert {:ok, _goal, target} = GoalTargetColumn.resolve(child)
      assert target.id == doing.id
    end

    test "returns :error for a task without a goal parent" do
      {_board, [ready]} = board_with_columns(["Ready"])

      orphan = task_fixture(ready, %{title: "Orphan"})
      work_parent = task_fixture(ready, %{title: "Work parent"})
      child = task_fixture(ready, %{title: "Child of work"})
      child = put!(child, parent_id: work_parent.id)

      assert GoalTargetColumn.resolve(orphan) == :error
      assert GoalTargetColumn.resolve(child) == :error
    end

    test "returns :error when the goal has no live children" do
      {_board, [ready, done]} = board_with_columns(["Ready", "Done"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      child = task_fixture(ready, %{title: "Archived child", parent_id: goal.id})
      child = put!(child, column_id: done.id, archived_at: DateTime.utc_now(:second))
      put!(goal, column_id: ready.id)

      assert GoalTargetColumn.resolve(child) == :error
    end
  end

  describe "find_done_column/1" do
    test "matches Done case-insensitively" do
      {_board, [ready, done]} = board_with_columns(["Ready", "DONE"])

      assert GoalTargetColumn.find_done_column([ready, done]).id == done.id
    end

    test "returns nil when no column is named Done" do
      {_board, columns} = board_with_columns(["Ready", "Doing"])

      assert GoalTargetColumn.find_done_column(columns) == nil
      assert GoalTargetColumn.find_done_column([]) == nil
    end
  end

  describe "Goals.update_parent_goal_position/4 wiring" do
    test "moves the goal to the resolved column" do
      {_board, [ready, done]} = board_with_columns(["Ready", "Done"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      child = put!(child, column_id: done.id)
      put!(goal, column_id: ready.id)

      assert Goals.update_parent_goal_position(child, ready.id, done.id) == :ok
      assert Repo.reload!(goal).column_id == done.id
    end

    test "returns :ok and moves nothing when resolve/1 returns :error" do
      {_board, [ready, done]} = board_with_columns(["Ready", "Done"])

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      child = task_fixture(ready, %{title: "Archived child", parent_id: goal.id})
      child = put!(child, column_id: done.id, archived_at: DateTime.utc_now(:second))
      put!(goal, column_id: ready.id)

      assert Goals.update_parent_goal_position(child, ready.id, done.id) == :ok
      assert Repo.reload!(goal).column_id == ready.id
    end
  end
end
