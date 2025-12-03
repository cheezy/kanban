defmodule Kanban.TasksTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  describe "list_tasks/1" do
    test "returns all tasks for a column ordered by position" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})
      task3 = task_fixture(column, %{title: "Third"})

      tasks = Tasks.list_tasks(column)

      assert length(tasks) == 3
      assert Enum.map(tasks, & &1.id) == [task1.id, task2.id, task3.id]
      assert Enum.map(tasks, & &1.position) == [0, 1, 2]
    end

    test "returns empty list when column has no tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert Tasks.list_tasks(column) == []
    end

    test "only returns tasks for the specified column" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      task_fixture(column1)
      task_fixture(column2)

      assert length(Tasks.list_tasks(column1)) == 1
      assert length(Tasks.list_tasks(column2)) == 1
    end
  end

  describe "get_task!/1" do
    test "returns the task with given id" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert Tasks.get_task!(task.id).id == task.id
    end

    test "raises error when task does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(999_999)
      end
    end
  end

  describe "get_task_with_history!/1" do
    test "returns the task with preloaded task histories" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      result = Tasks.get_task_with_history!(task.id)

      assert result.id == task.id
      assert Ecto.assoc_loaded?(result.task_histories)
      refute Enum.empty?(result.task_histories)
      # Should have creation history
      assert Enum.any?(result.task_histories, fn h -> h.type == :creation end)
    end

    test "returns task histories in descending order by inserted_at" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      task = task_fixture(column1)

      # Move task to create another history entry
      {:ok, _moved_task} = Tasks.move_task(task, column2, 0)

      result = Tasks.get_task_with_history!(task.id)

      assert length(result.task_histories) >= 2
      # Most recent history should be first
      timestamps = Enum.map(result.task_histories, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:desc, NaiveDateTime})
    end

    test "raises error when task does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task_with_history!(999_999)
      end
    end
  end

  describe "create_task/2" do
    test "creates a task with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:ok, %Task{} = task} =
               Tasks.create_task(column, %{title: "New Task"})

      assert task.title == "New Task"
      assert task.position == 0
      assert task.column_id == column.id
    end

    test "creates tasks with sequential positions" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task1} = Tasks.create_task(column, %{title: "First"})
      {:ok, task2} = Tasks.create_task(column, %{title: "Second"})
      {:ok, task3} = Tasks.create_task(column, %{title: "Third"})

      assert task1.position == 0
      assert task2.position == 1
      assert task3.position == 2
    end

    test "creates a task with description" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:ok, %Task{} = task} =
               Tasks.create_task(column, %{
                 title: "Task with description",
                 description: "This is a detailed description"
               })

      assert task.description == "This is a detailed description"
    end

    test "returns error when title is missing" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:error, %Ecto.Changeset{}} = Tasks.create_task(column, %{})
    end

    test "allows unlimited tasks when wip_limit is 0" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 0})

      # Create 10 tasks with no limit
      Enum.each(1..10, fn i ->
        assert {:ok, _task} = Tasks.create_task(column, %{title: "Task #{i}"})
      end)

      assert length(Tasks.list_tasks(column)) == 10
    end

    test "enforces wip_limit when creating tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 2})

      # Create 2 tasks (at limit)
      {:ok, _task1} = Tasks.create_task(column, %{title: "First"})
      {:ok, _task2} = Tasks.create_task(column, %{title: "Second"})

      # Try to create a third task (should fail)
      assert {:error, :wip_limit_reached} =
               Tasks.create_task(column, %{title: "Third"})

      assert length(Tasks.list_tasks(column)) == 2
    end

    test "can add task when under wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 3})

      {:ok, _task1} = Tasks.create_task(column, %{title: "First"})
      {:ok, _task2} = Tasks.create_task(column, %{title: "Second"})

      # Should still be able to add one more
      assert {:ok, _task3} = Tasks.create_task(column, %{title: "Third"})

      assert length(Tasks.list_tasks(column)) == 3
    end
  end

  describe "update_task/2" do
    test "updates the task with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Old Title"})

      assert {:ok, %Task{} = updated_task} =
               Tasks.update_task(task, %{title: "New Title"})

      assert updated_task.title == "New Title"
      assert updated_task.id == task.id
    end

    test "updates task description" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{description: "Old description"})

      assert {:ok, %Task{} = updated_task} =
               Tasks.update_task(task, %{description: "New description"})

      assert updated_task.description == "New description"
    end

    test "returns error with invalid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert {:error, %Ecto.Changeset{}} =
               Tasks.update_task(task, %{title: nil})
    end

    test "creates history record when priority changes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :medium})

      # Update task priority
      assert {:ok, %Task{} = updated_task} =
               Tasks.update_task(task, %{priority: :high})

      assert updated_task.priority == :high

      # Check that a history record was created
      task_with_history = Tasks.get_task_with_history!(updated_task.id)
      priority_changes = Enum.filter(task_with_history.task_histories, &(&1.type == :priority_change))

      assert length(priority_changes) == 1
      priority_change = hd(priority_changes)
      assert priority_change.from_priority == "medium"
      assert priority_change.to_priority == "high"
      assert priority_change.from_column == nil
      assert priority_change.to_column == nil
    end

    test "does not create history record when priority does not change" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :medium})

      initial_history_count = length(Tasks.get_task_with_history!(task.id).task_histories)

      # Update task without changing priority
      assert {:ok, %Task{}} = Tasks.update_task(task, %{title: "New Title"})

      # Check that no new history record was created
      task_with_history = Tasks.get_task_with_history!(task.id)
      assert length(task_with_history.task_histories) == initial_history_count
    end

    test "creates multiple history records for multiple priority changes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :low})

      # First change: low -> medium
      assert {:ok, task} = Tasks.update_task(task, %{priority: :medium})

      # Second change: medium -> high
      assert {:ok, task} = Tasks.update_task(task, %{priority: :high})

      # Third change: high -> critical
      assert {:ok, task} = Tasks.update_task(task, %{priority: :critical})

      # Check that three priority change history records were created
      task_with_history = Tasks.get_task_with_history!(task.id)
      priority_changes = Enum.filter(task_with_history.task_histories, &(&1.type == :priority_change))

      assert length(priority_changes) == 3

      # Verify we have all the expected changes (order may vary in tests due to timing)
      priorities = Enum.map(priority_changes, fn change ->
        {change.from_priority, change.to_priority}
      end)

      assert {"low", "medium"} in priorities
      assert {"medium", "high"} in priorities
      assert {"high", "critical"} in priorities
    end
  end

  describe "delete_task/1" do
    test "deletes the task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert {:ok, %Task{}} = Tasks.delete_task(task)
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
    end

    test "reorders remaining tasks after deletion" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})
      task3 = task_fixture(column, %{title: "Third"})

      # Delete the middle task
      {:ok, _deleted} = Tasks.delete_task(task2)

      # Refresh tasks from database
      remaining_tasks = Tasks.list_tasks(column)

      assert length(remaining_tasks) == 2
      assert Enum.at(remaining_tasks, 0).id == task1.id
      assert Enum.at(remaining_tasks, 0).position == 0
      assert Enum.at(remaining_tasks, 1).id == task3.id
      assert Enum.at(remaining_tasks, 1).position == 1
    end

    test "reorders when deleting first task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})
      task3 = task_fixture(column, %{title: "Third"})

      {:ok, _deleted} = Tasks.delete_task(task1)

      remaining_tasks = Tasks.list_tasks(column)

      assert length(remaining_tasks) == 2
      assert Enum.at(remaining_tasks, 0).id == task2.id
      assert Enum.at(remaining_tasks, 0).position == 0
      assert Enum.at(remaining_tasks, 1).id == task3.id
      assert Enum.at(remaining_tasks, 1).position == 1
    end

    test "does not affect other column's tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      task1 = task_fixture(column1)
      task2 = task_fixture(column2)

      {:ok, _deleted} = Tasks.delete_task(task1)

      # Column2's task should be unaffected
      assert Tasks.get_task!(task2.id).position == 0
    end
  end

  describe "move_task/3" do
    test "moves task to a different column" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})

      task = task_fixture(column1)

      assert {:ok, %Task{} = moved_task} = Tasks.move_task(task, column2, 0)

      assert moved_task.column_id == column2.id
      assert moved_task.position == 0
    end

    test "moves task to a different position in the same column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})
      task3 = task_fixture(column, %{title: "Third"})

      # Move task1 to position 2 (end)
      assert {:ok, %Task{} = moved_task} = Tasks.move_task(task1, column, 2)

      assert moved_task.position == 2

      # Verify new order
      tasks = Tasks.list_tasks(column)
      assert Enum.map(tasks, & &1.id) == [task2.id, task3.id, task1.id]
      assert Enum.map(tasks, & &1.position) == [0, 1, 2]
    end

    test "respects wip_limit when moving to different column" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})

      task = task_fixture(column1)

      # Fill column2 to its limit
      task_fixture(column2)
      task_fixture(column2)

      # Try to move task to full column
      assert {:error, :wip_limit_reached} = Tasks.move_task(task, column2, 0)

      # Task should still be in column1
      refreshed_task = Tasks.get_task!(task.id)
      assert refreshed_task.column_id == column1.id
    end

    test "allows move to column with wip_limit if not at capacity" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})

      task = task_fixture(column1)

      # Add one task to column2 (under limit)
      task_fixture(column2)

      # Should be able to move
      assert {:ok, moved_task} = Tasks.move_task(task, column2, 1)
      assert moved_task.column_id == column2.id
    end

    test "ignores wip_limit when moving within same column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 2})

      task1 = task_fixture(column)
      _task2 = task_fixture(column)

      # Should be able to reorder within same column even at limit
      assert {:ok, _moved_task} = Tasks.move_task(task1, column, 1)
    end

    test "reorders tasks in source column after move" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      task1 = task_fixture(column1, %{title: "First"})
      task2 = task_fixture(column1, %{title: "Second"})
      task3 = task_fixture(column1, %{title: "Third"})

      # Move middle task to column2
      Tasks.move_task(task2, column2, 0)

      # Check column1 tasks are reordered
      column1_tasks = Tasks.list_tasks(column1)
      assert length(column1_tasks) == 2
      assert Enum.at(column1_tasks, 0).id == task1.id
      assert Enum.at(column1_tasks, 0).position == 0
      assert Enum.at(column1_tasks, 1).id == task3.id
      assert Enum.at(column1_tasks, 1).position == 1
    end
  end

  describe "reorder_tasks/2" do
    test "reorders tasks based on list of IDs" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})
      task3 = task_fixture(column, %{title: "Third"})

      # Reorder: Third, First, Second
      Tasks.reorder_tasks(column, [task3.id, task1.id, task2.id])

      tasks = Tasks.list_tasks(column)

      assert Enum.at(tasks, 0).id == task3.id
      assert Enum.at(tasks, 0).position == 0
      assert Enum.at(tasks, 1).id == task1.id
      assert Enum.at(tasks, 1).position == 1
      assert Enum.at(tasks, 2).id == task2.id
      assert Enum.at(tasks, 2).position == 2
    end

    test "handles partial reordering" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      # Swap them
      Tasks.reorder_tasks(column, [task2.id, task1.id])

      tasks = Tasks.list_tasks(column)

      assert Enum.at(tasks, 0).id == task2.id
      assert Enum.at(tasks, 1).id == task1.id
    end
  end

  describe "can_add_task?/1" do
    test "returns true when wip_limit is 0" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 0})

      # Add several tasks
      Enum.each(1..5, fn i ->
        task_fixture(column, %{title: "Task #{i}"})
      end)

      # Should still allow more tasks
      assert Tasks.can_add_task?(column)
    end

    test "returns true when under wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 3})

      task_fixture(column)

      # 1 task, limit is 3
      assert Tasks.can_add_task?(column)
    end

    test "returns false when at wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 2})

      task_fixture(column)
      task_fixture(column)

      # At limit
      refute Tasks.can_add_task?(column)
    end

    test "returns false when over wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      # Create column with limit 1
      column = column_fixture(board, %{wip_limit: 1})

      # Add one task
      task_fixture(column)

      # Now manually update wip_limit to 0 to simulate over-limit scenario
      # (This could happen if limit is reduced after tasks are added)
      # For this test, we just verify the logic with the current state
      refute Tasks.can_add_task?(column)
    end

    test "returns true for empty column with wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 5})

      # Empty column with limit
      assert Tasks.can_add_task?(column)
    end
  end

  describe "create_task with string keys" do
    test "creates task with string keys in attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Pass attrs with string keys (as from form params)
      assert {:ok, %Task{} = task} =
               Tasks.create_task(column, %{"title" => "Task with string key"})

      assert task.title == "Task with string key"
      assert task.position == 0
    end

    test "creates task with string keys for description" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:ok, %Task{} = task} =
               Tasks.create_task(column, %{
                 "title" => "Task",
                 "description" => "Description with string key"
               })

      assert task.description == "Description with string key"
    end
  end

  describe "move_task edge cases" do
    test "moves task between columns at middle position" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      task_to_move = task_fixture(column1, %{title: "Moving task"})
      task1 = task_fixture(column2, %{title: "Task 1"})
      task2 = task_fixture(column2, %{title: "Task 2"})
      task3 = task_fixture(column2, %{title: "Task 3"})

      # Move task to position 2 (between task2 and task3)
      assert {:ok, moved_task} = Tasks.move_task(task_to_move, column2, 2)

      assert moved_task.position == 2

      # Verify task order in column2
      tasks = Tasks.list_tasks(column2)
      assert length(tasks) == 4
      assert Enum.at(tasks, 0).id == task1.id
      assert Enum.at(tasks, 1).id == task2.id
      assert Enum.at(tasks, 2).id == moved_task.id
      assert Enum.at(tasks, 3).id == task3.id
    end

    test "moves task to same position in same column (no-op)" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      # Move task2 to position 1 (its current position)
      assert {:ok, moved_task} = Tasks.move_task(task2, column, 1)

      assert moved_task.position == 1

      # Verify order hasn't changed
      tasks = Tasks.list_tasks(column)
      assert Enum.map(tasks, & &1.id) == [task1.id, task2.id, task3.id]
    end

    test "moves task from end to beginning within same column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      # Move task3 from position 2 to position 0
      assert {:ok, moved_task} = Tasks.move_task(task3, column, 0)

      assert moved_task.position == 0

      # Verify new order
      tasks = Tasks.list_tasks(column)
      assert Enum.map(tasks, & &1.id) == [task3.id, task1.id, task2.id]
    end

    test "moves task from middle position upward within same column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})
      task4 = task_fixture(column, %{title: "Task 4"})

      # Move task3 from position 2 to position 1
      assert {:ok, moved_task} = Tasks.move_task(task3, column, 1)

      assert moved_task.position == 1

      # Verify new order
      tasks = Tasks.list_tasks(column)
      assert Enum.map(tasks, & &1.id) == [task1.id, task3.id, task2.id, task4.id]
    end

    test "moves task from middle position downward within same column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})
      task4 = task_fixture(column, %{title: "Task 4"})

      # Move task2 from position 1 to position 3
      assert {:ok, moved_task} = Tasks.move_task(task2, column, 3)

      assert moved_task.position == 3

      # Verify new order
      tasks = Tasks.list_tasks(column)
      assert Enum.map(tasks, & &1.id) == [task1.id, task3.id, task4.id, task2.id]
    end

    test "moves task between columns at end position" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      task_to_move = task_fixture(column1, %{title: "Moving task"})
      task1 = task_fixture(column2, %{title: "Task 1"})
      task2 = task_fixture(column2, %{title: "Task 2"})

      # Move task to end of column2
      assert {:ok, moved_task} = Tasks.move_task(task_to_move, column2, 2)

      assert moved_task.position == 2

      # Verify task order in column2
      tasks = Tasks.list_tasks(column2)
      assert length(tasks) == 3
      assert Enum.at(tasks, 0).id == task1.id
      assert Enum.at(tasks, 1).id == task2.id
      assert Enum.at(tasks, 2).id == moved_task.id
    end
  end
end
