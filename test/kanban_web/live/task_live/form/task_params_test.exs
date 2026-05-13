defmodule KanbanWeb.TaskLive.Form.TaskParamsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.Form.TaskParams

  describe "coerce_id/1" do
    test "returns {:ok, n} for a positive integer" do
      assert TaskParams.coerce_id(42) == {:ok, 42}
    end

    test "returns {:ok, n} for a negative integer" do
      assert TaskParams.coerce_id(-7) == {:ok, -7}
    end

    test "returns {:ok, 0} for zero" do
      assert TaskParams.coerce_id(0) == {:ok, 0}
    end

    test "parses a binary that is exactly an integer" do
      assert TaskParams.coerce_id("123") == {:ok, 123}
    end

    test "returns :error for a binary with trailing garbage" do
      assert TaskParams.coerce_id("123abc") == :error
    end

    test "returns :error for a binary that is not a number" do
      assert TaskParams.coerce_id("abc") == :error
    end

    test "returns :error for an empty string" do
      assert TaskParams.coerce_id("") == :error
    end

    test "returns :error for nil" do
      assert TaskParams.coerce_id(nil) == :error
    end

    test "returns :error for a float" do
      assert TaskParams.coerce_id(1.5) == :error
    end

    test "returns :error for a list" do
      assert TaskParams.coerce_id([1]) == :error
    end

    test "returns :error for a map" do
      assert TaskParams.coerce_id(%{}) == :error
    end
  end

  describe "scope_error_label/1" do
    test "returns a string for :column_id" do
      assert is_binary(TaskParams.scope_error_label(:column_id))
      assert TaskParams.scope_error_label(:column_id) =~ "column"
    end

    test "returns a string for :parent_id" do
      assert is_binary(TaskParams.scope_error_label(:parent_id))
      assert TaskParams.scope_error_label(:parent_id) =~ "parent"
    end

    test "returns a string for :assigned_to_id" do
      assert is_binary(TaskParams.scope_error_label(:assigned_to_id))
      assert TaskParams.scope_error_label(:assigned_to_id) =~ "assignee"
    end

    test "labels for different fields are distinct" do
      labels = [
        TaskParams.scope_error_label(:column_id),
        TaskParams.scope_error_label(:parent_id),
        TaskParams.scope_error_label(:assigned_to_id)
      ]

      assert Enum.uniq(labels) == labels
    end
  end

  describe "compute_cascade_count/2" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "returns 0 for a non-goal task even when assigned_to_id is in params", %{column: column} do
      task = task_fixture(column, %{type: :work})

      assert TaskParams.compute_cascade_count(task, %{"assigned_to_id" => "1"}) == 0
    end

    test "returns 0 for a defect task even when assigned_to_id is in params", %{column: column} do
      task = task_fixture(column, %{type: :defect})

      assert TaskParams.compute_cascade_count(task, %{"assigned_to_id" => "1"}) == 0
    end

    test "returns 0 for a goal task when params do not include assigned_to_id", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      assert TaskParams.compute_cascade_count(goal, %{"title" => "Updated"}) == 0
    end

    test "returns 0 for a goal task with no children", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => ""}) == 0
    end

    test "counts eligible children when reassigning to a user id (string)", %{
      user: user,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal})
      other_user = user_fixture()

      # Two non-completed children currently assigned to `user`; reassigning to
      # `other_user` should count both.
      child_one = task_fixture(column, %{type: :work, parent_id: goal.id})
      child_two = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child_one, %{"assigned_to_id" => user.id})
      {:ok, _} = Tasks.update_task(child_two, %{"assigned_to_id" => user.id})

      count = TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => "#{other_user.id}"})
      assert count == 2
    end

    test "counts eligible children when reassigning to a user id (integer)", %{
      user: user,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal})
      other_user = user_fixture()
      child = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child, %{"assigned_to_id" => user.id})

      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => other_user.id}) == 1
    end

    test "treats empty string as nil (unassign cascade)", %{user: user, column: column} do
      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child, %{"assigned_to_id" => user.id})

      # Unassign cascade — child currently assigned, so it is eligible.
      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => ""}) == 1
    end

    test "treats nil value as unassign cascade", %{user: user, column: column} do
      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child, %{"assigned_to_id" => user.id})

      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => nil}) == 1
    end

    test "unparseable string is treated as nil (unassign cascade)", %{user: user, column: column} do
      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child, %{"assigned_to_id" => user.id})

      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => "not-an-id"}) == 1
    end

    test "completed children are excluded from the count", %{user: user, column: column} do
      goal = task_fixture(column, %{type: :goal})
      other_user = user_fixture()
      child = task_fixture(column, %{type: :work, parent_id: goal.id})

      {:ok, _} =
        Tasks.update_task(child, %{
          "assigned_to_id" => user.id,
          "status" => :completed,
          "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => "#{other_user.id}"}) ==
               0
    end

    test "children already assigned to the new target are excluded", %{
      user: user,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.update_task(child, %{"assigned_to_id" => user.id})

      # Reassigning to the same user — nothing changes.
      assert TaskParams.compute_cascade_count(goal, %{"assigned_to_id" => "#{user.id}"}) == 0
    end
  end

  describe "build_update_flash/1" do
    test "returns the no-cascade message for 0" do
      assert TaskParams.build_update_flash(0) =~ "updated successfully"
      refute TaskParams.build_update_flash(0) =~ "child"
    end

    test "returns the singular cascade message for 1" do
      flash = TaskParams.build_update_flash(1)
      assert flash =~ "1 child task"
      assert flash =~ "also updated"
    end

    test "returns the plural cascade message for n > 1" do
      flash = TaskParams.build_update_flash(5)
      assert flash =~ "5 child tasks"
      assert flash =~ "also updated"
    end

    test "plural and singular messages are distinct" do
      assert TaskParams.build_update_flash(1) != TaskParams.build_update_flash(2)
    end
  end
end
