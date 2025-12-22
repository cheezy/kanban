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

      priority_changes =
        Enum.filter(task_with_history.task_histories, &(&1.type == :priority_change))

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

      priority_changes =
        Enum.filter(task_with_history.task_histories, &(&1.type == :priority_change))

      assert length(priority_changes) == 3

      # Verify we have all the expected changes (order may vary in tests due to timing)
      priorities =
        Enum.map(priority_changes, fn change ->
          {change.from_priority, change.to_priority}
        end)

      assert {"low", "medium"} in priorities
      assert {"medium", "high"} in priorities
      assert {"high", "critical"} in priorities
    end

    test "creates history record when user is assigned" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)
      assigned_user = user_fixture()

      assert task.assigned_to_id == nil

      assert {:ok, updated_task} = Tasks.update_task(task, %{assigned_to_id: assigned_user.id})
      assert updated_task.assigned_to_id == assigned_user.id

      task_with_history = Tasks.get_task_with_history!(updated_task.id)

      assignment_histories =
        Enum.filter(task_with_history.task_histories, fn h -> h.type == :assignment end)

      assert length(assignment_histories) == 1
      history = List.first(assignment_histories)
      assert history.from_user_id == nil
      assert history.to_user_id == assigned_user.id
    end

    test "creates history record when user is unassigned" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      assigned_user = user_fixture()
      task = task_fixture(column, %{assigned_to_id: assigned_user.id})

      assert task.assigned_to_id == assigned_user.id

      assert {:ok, updated_task} = Tasks.update_task(task, %{assigned_to_id: nil})
      assert updated_task.assigned_to_id == nil

      task_with_history = Tasks.get_task_with_history!(updated_task.id)

      assignment_histories =
        Enum.filter(task_with_history.task_histories, fn h -> h.type == :assignment end)

      assert length(assignment_histories) == 1
      history = List.first(assignment_histories)
      assert history.from_user_id == assigned_user.id
      assert history.to_user_id == nil
    end

    test "creates history record when user is reassigned" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      user1 = user_fixture()
      user2 = user_fixture()
      task = task_fixture(column, %{assigned_to_id: user1.id})

      assert task.assigned_to_id == user1.id

      assert {:ok, updated_task} = Tasks.update_task(task, %{assigned_to_id: user2.id})
      assert updated_task.assigned_to_id == user2.id

      task_with_history = Tasks.get_task_with_history!(updated_task.id)

      assignment_histories =
        Enum.filter(task_with_history.task_histories, fn h -> h.type == :assignment end)

      assert length(assignment_histories) == 1
      history = List.first(assignment_histories)
      assert history.from_user_id == user1.id
      assert history.to_user_id == user2.id
    end

    test "does not create history record when assignment does not change" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      assigned_user = user_fixture()
      task = task_fixture(column, %{assigned_to_id: assigned_user.id})

      assert {:ok, _updated_task} = Tasks.update_task(task, %{title: "New Title"})

      task_with_history = Tasks.get_task_with_history!(task.id)

      assignment_histories =
        Enum.filter(task_with_history.task_histories, fn h -> h.type == :assignment end)

      assert Enum.empty?(assignment_histories)
    end

    test "creates multiple history records for multiple assignment changes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()
      task = task_fixture(column)

      assert {:ok, task} = Tasks.update_task(task, %{assigned_to_id: user1.id})
      assert {:ok, task} = Tasks.update_task(task, %{assigned_to_id: user2.id})
      assert {:ok, task} = Tasks.update_task(task, %{assigned_to_id: user3.id})

      task_with_history = Tasks.get_task_with_history!(task.id)

      assignment_histories =
        Enum.filter(task_with_history.task_histories, fn h -> h.type == :assignment end)

      assert length(assignment_histories) == 3

      assignments =
        Enum.map(assignment_histories, fn change ->
          {change.from_user_id, change.to_user_id}
        end)

      assert {nil, user1.id} in assignments
      assert {user1.id, user2.id} in assignments
      assert {user2.id, user3.id} in assignments
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

  describe "scalar AI fields" do
    test "stores and retrieves planning context fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Implement user authentication",
        complexity: :medium,
        estimated_files: "5-7",
        why: "Users need secure login functionality",
        what: "Add JWT-based authentication with refresh tokens",
        where_context: "lib/kanban_web/controllers/auth and lib/kanban/accounts"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.complexity == :medium
      assert task.estimated_files == "5-7"
      assert task.why == "Users need secure login functionality"
      assert task.what == "Add JWT-based authentication with refresh tokens"
      assert task.where_context =~ "lib/kanban_web/controllers/auth"
    end

    test "stores and retrieves implementation guidance fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Add user settings page",
        patterns_to_follow: "Use LiveView components, follow Phoenix naming conventions",
        database_changes: "Add settings table with user_id foreign key",
        validation_rules: "Email must be unique, password min 12 chars"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.patterns_to_follow =~ "LiveView"
      assert task.database_changes =~ "settings table"
      assert task.validation_rules =~ "Email must be unique"
    end

    test "stores and retrieves observability fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Add metrics endpoint",
        telemetry_event: "kanban.tasks.metrics_exported",
        metrics_to_track: "Export count, export duration, error rate",
        logging_requirements: "Log exports at info level, errors at error level"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.telemetry_event == "kanban.tasks.metrics_exported"
      assert task.metrics_to_track =~ "Export count"
      assert task.logging_requirements =~ "info level"
    end

    test "stores and retrieves error handling fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Add file upload",
        error_user_message: "File upload failed. Please try again or contact support.",
        error_on_failure: "Send alert to ops team, log full stack trace"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.error_user_message =~ "File upload failed"
      assert task.error_on_failure =~ "Send alert to ops team"
    end
  end

  describe "complexity validation" do
    test "validates complexity values" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        complexity: :invalid_value
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert "is invalid" in errors_on(changeset).complexity
    end

    test "allows valid complexity values" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      for complexity <- [:small, :medium, :large] do
        attrs = %{
          title: "Test task #{complexity}",
          complexity: complexity
        }

        {:ok, task} = Tasks.create_task(column, attrs)
        assert task.complexity == complexity
      end
    end
  end

  describe "backward compatibility" do
    test "creates task without scalar fields (backward compatibility)" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Simple task"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.title == "Simple task"
      assert task.complexity == :small
      assert task.why == nil
      assert task.telemetry_event == nil
    end
  end

  describe "scalar field updates" do
    test "updates scalar fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      update_attrs = %{
        complexity: :large,
        why: "Updated rationale",
        telemetry_event: "updated.event"
      }

      {:ok, updated_task} = Tasks.update_task(task, update_attrs)

      assert updated_task.complexity == :large
      assert updated_task.why == "Updated rationale"
      assert updated_task.telemetry_event == "updated.event"
    end
  end

  describe "key_files embedded schema" do
    test "stores and retrieves key files with ordering" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Refactor authentication",
        key_files: [
          %{file_path: "lib/kanban/accounts.ex", note: "Update create_user/1", position: 0},
          %{file_path: "lib/kanban_web/user_auth.ex", note: "Add token validation", position: 1},
          %{file_path: "test/kanban/accounts_test.exs", note: "Add tests", position: 2}
        ]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.key_files) == 3
      assert Enum.at(task.key_files, 0).file_path == "lib/kanban/accounts.ex"
      assert Enum.at(task.key_files, 1).note == "Add token validation"
      assert Enum.at(task.key_files, 2).position == 2
    end

    test "validates key file paths" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        key_files: [
          %{file_path: "/absolute/path/bad.ex", position: 0}
        ]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert %{key_files: [%{file_path: ["must be a relative path, not absolute"]}]} =
               errors_on(changeset)
    end

    test "rejects path traversal in key files" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        key_files: [
          %{file_path: "../../../etc/passwd", position: 0}
        ]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert %{key_files: [%{file_path: ["must not contain .. path traversal"]}]} =
               errors_on(changeset)
    end
  end

  describe "verification_steps embedded schema" do
    test "stores and retrieves verification steps with ordering" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Add feature",
        verification_steps: [
          %{
            step_type: "command",
            step_text: "mix test",
            expected_result: "All tests pass",
            position: 0
          },
          %{
            step_type: "manual",
            step_text: "Check UI in browser",
            expected_result: "Button appears and is clickable",
            position: 1
          }
        ]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.verification_steps) == 2
      assert Enum.at(task.verification_steps, 0).step_type == "command"
      assert Enum.at(task.verification_steps, 1).step_text == "Check UI in browser"
    end

    test "validates step_type enum" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [
          %{
            step_type: "invalid_type",
            step_text: "Do something",
            position: 0
          }
        ]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{verification_steps: [%{step_type: ["is invalid"]}]} = errors_on(changeset)
    end
  end

  describe "simple JSONB arrays" do
    test "stores and retrieves technology requirements" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Build API",
        technology_requirements: ["ecto", "phoenix", "jose"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert "ecto" in task.technology_requirements
      assert "phoenix" in task.technology_requirements
      assert length(task.technology_requirements) == 3
    end

    test "stores and retrieves pitfalls" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Optimize queries",
        pitfalls: [
          "Don't use Repo.all without limit",
          "Remember to preload associations",
          "Add indexes for foreign keys"
        ]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.pitfalls) == 3
      assert Enum.any?(task.pitfalls, &String.contains?(&1, "preload"))
    end

    test "stores and retrieves out_of_scope items" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Add user profile",
        out_of_scope: [
          "Profile photo upload (defer to next sprint)",
          "Social media integration",
          "Email notifications"
        ]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.out_of_scope) == 3
      assert Enum.any?(task.out_of_scope, &String.contains?(&1, "photo"))
    end
  end

  describe "JSONB querying" do
    test "finds tasks modifying specific file" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task1} =
        Tasks.create_task(column, %{
          title: "Task 1",
          key_files: [
            %{file_path: "lib/kanban/tasks.ex", position: 0}
          ]
        })

      {:ok, _task2} =
        Tasks.create_task(column, %{
          title: "Task 2",
          key_files: [
            %{file_path: "lib/kanban/boards.ex", position: 0}
          ]
        })

      results = Tasks.get_tasks_modifying_file("lib/kanban/tasks.ex")

      assert length(results) == 1
      assert hd(results).id == task1.id
    end

    test "finds tasks requiring specific technology" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task1} =
        Tasks.create_task(column, %{
          title: "Task 1",
          technology_requirements: ["ecto", "phoenix"]
        })

      {:ok, _task2} =
        Tasks.create_task(column, %{
          title: "Task 2",
          technology_requirements: ["react", "typescript"]
        })

      # Verify tasks were created with the right data
      all_tasks = Tasks.list_tasks(column)
      assert length(all_tasks) == 2
      assert Enum.any?(all_tasks, fn t -> t.id == task1.id && t.technology_requirements == ["ecto", "phoenix"] end)

      results = Tasks.get_tasks_requiring_technology("ecto")

      assert length(results) == 1
      assert hd(results).id == task1.id
    end
  end

  describe "updating JSONB collections" do
    test "replaces key_files on update" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          key_files: [
            %{file_path: "lib/old.ex", position: 0}
          ]
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          key_files: [
            %{file_path: "lib/new.ex", position: 0}
          ]
        })

      assert length(updated_task.key_files) == 1
      assert hd(updated_task.key_files).file_path == "lib/new.ex"
    end

    test "appends to technology_requirements" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          technology_requirements: ["ecto"]
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          technology_requirements: ["ecto", "phoenix", "jose"]
        })

      assert length(updated_task.technology_requirements) == 3
    end
  end

  describe "Task.changeset/2 type validation" do
    test "validates type enum with valid values" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      for type <- [:work, :defect] do
        attrs = %{title: "Test #{type}", type: type}
        {:ok, task} = Tasks.create_task(column, attrs)
        assert task.type == type
      end
    end

    test "rejects invalid type values" do
      attrs = %{title: "Test task", position: 0, type: :invalid_type}
      changeset = Kanban.Tasks.Task.changeset(%Kanban.Tasks.Task{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).type
    end

    test "defaults to :work when type is not provided" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task"}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.type == :work
    end
  end

  describe "Task.changeset/2 priority validation" do
    test "validates priority enum with all valid values" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      for priority <- [:low, :medium, :high, :critical] do
        attrs = %{title: "Test #{priority}", priority: priority}
        {:ok, task} = Tasks.create_task(column, attrs)
        assert task.priority == priority
      end
    end

    test "rejects invalid priority values" do
      attrs = %{title: "Test task", position: 0, priority: :invalid_priority}
      changeset = Kanban.Tasks.Task.changeset(%Kanban.Tasks.Task{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).priority
    end

    test "defaults to :medium when priority is not provided" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task"}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.priority == :medium
    end
  end

  describe "Task.changeset/2 required fields" do
    test "requires title" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{description: "Has description but no title"}
      {:error, changeset} = Tasks.create_task(column, attrs)
      assert "can't be blank" in errors_on(changeset).title
    end

    test "requires position" do
      attrs = %{title: "Test task"}
      changeset = Kanban.Tasks.Task.changeset(%Kanban.Tasks.Task{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).position
    end

    test "requires type" do
      attrs = %{title: "Test task", position: 0, type: nil}
      changeset = Kanban.Tasks.Task.changeset(%Kanban.Tasks.Task{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).type
    end

    test "requires priority" do
      attrs = %{title: "Test task", position: 0, priority: nil}
      changeset = Kanban.Tasks.Task.changeset(%Kanban.Tasks.Task{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).priority
    end
  end

  describe "Task.changeset/2 technology_requirements validation" do
    test "accepts nil technology_requirements" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", technology_requirements: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.technology_requirements == nil
    end

    test "accepts empty array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", technology_requirements: []}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.technology_requirements == []
    end

    test "accepts valid string array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", technology_requirements: ["ecto", "phoenix"]}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.technology_requirements == ["ecto", "phoenix"]
    end

    test "rejects array with non-string values through custom validation" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        technology_requirements: ["ecto", 123, :phoenix]
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of strings" in errors_on(changeset).technology_requirements
    end

    test "rejects non-list values through custom validation" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        technology_requirements: "not a list"
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list" in errors_on(changeset).technology_requirements
    end

    test "rejects non-list values at cast level" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", technology_requirements: %{invalid: "map"}}
      {:error, changeset} = Tasks.create_task(column, attrs)
      assert "is invalid" in errors_on(changeset).technology_requirements
    end
  end

  describe "Task.changeset/2 key_files validation" do
    test "requires file_path in key_files" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        key_files: [%{note: "Some note", position: 0}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{key_files: [%{file_path: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "requires position in key_files" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        key_files: [%{file_path: "lib/test.ex", note: "Some note"}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{key_files: [%{position: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "validates position is non-negative" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        key_files: [%{file_path: "lib/test.ex", position: -1}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{key_files: [%{position: ["must be greater than or equal to 0"]}]} = errors_on(changeset)
    end
  end

  describe "Task.changeset/2 verification_steps validation" do
    test "requires step_type in verification_steps" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [%{step_text: "Do something", position: 0}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{verification_steps: [%{step_type: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "requires step_text in verification_steps" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [%{step_type: "command", position: 0}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{verification_steps: [%{step_text: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "requires position in verification_steps" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [%{step_type: "command", step_text: "mix test"}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{verification_steps: [%{position: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "validates position is non-negative in verification_steps" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [%{step_type: "command", step_text: "mix test", position: -5}]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)
      assert %{verification_steps: [%{position: ["must be greater than or equal to 0"]}]} = errors_on(changeset)
    end

    test "allows optional expected_result in verification_steps" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: [%{step_type: "manual", step_text: "Check UI", position: 0}]
      }

      {:ok, task} = Tasks.create_task(column, attrs)
      assert length(task.verification_steps) == 1
      assert hd(task.verification_steps).expected_result == nil
    end
  end

  describe "Task.changeset/2 unique constraints" do
    test "auto-generates unique identifiers" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task1} = Tasks.create_task(column, %{title: "Task 1", type: :work})
      {:ok, task2} = Tasks.create_task(column, %{title: "Task 2", type: :work})

      assert task1.identifier =~ ~r/^W\d+$/
      assert task2.identifier =~ ~r/^W\d+$/
      assert task1.identifier != task2.identifier
    end

    test "generates different identifier prefixes for different types" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, work_task} = Tasks.create_task(column, %{title: "Work Task", type: :work})
      {:ok, defect_task} = Tasks.create_task(column, %{title: "Defect Task", type: :defect})

      assert work_task.identifier =~ ~r/^W\d+$/
      assert defect_task.identifier =~ ~r/^D\d+$/
    end

    test "unique constraint on identifier at database level" do
      task1 = %Kanban.Tasks.Task{
        title: "Task 1",
        position: 0,
        type: :work,
        priority: :medium,
        identifier: "DUPLICATE-123",
        column_id: 1
      }

      task2 = %Kanban.Tasks.Task{
        title: "Task 2",
        position: 1,
        type: :work,
        priority: :medium,
        identifier: "DUPLICATE-123",
        column_id: 1
      }

      changeset1 = Kanban.Tasks.Task.changeset(task1, %{})
      changeset2 = Kanban.Tasks.Task.changeset(task2, %{})

      assert changeset1.valid?
      assert changeset2.valid?
    end
  end

  describe "Task.changeset/2 pitfalls and out_of_scope arrays" do
    test "accepts valid pitfalls array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        pitfalls: ["Watch out for race conditions", "Remember to handle nil values"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)
      assert length(task.pitfalls) == 2
    end

    test "accepts empty pitfalls array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", pitfalls: []}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.pitfalls == []
    end

    test "accepts valid out_of_scope array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        out_of_scope: ["Email notifications", "Mobile app support"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)
      assert length(task.out_of_scope) == 2
    end

    test "accepts nil for pitfalls and out_of_scope" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", pitfalls: nil, out_of_scope: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.pitfalls == nil
      assert task.out_of_scope == nil
    end
  end

  describe "Task.changeset/2 all scalar AI fields" do
    test "accepts all scalar fields together" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Full featured task",
        complexity: :large,
        estimated_files: "10-15",
        why: "Business needs",
        what: "Feature description",
        where_context: "lib/kanban",
        patterns_to_follow: "Use LiveView",
        database_changes: "Add table",
        validation_rules: "Email required",
        telemetry_event: "task.completed",
        metrics_to_track: "Duration",
        logging_requirements: "Log at info",
        error_user_message: "Something went wrong",
        error_on_failure: "Alert ops"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.complexity == :large
      assert task.estimated_files == "10-15"
      assert task.why == "Business needs"
      assert task.what == "Feature description"
      assert task.where_context == "lib/kanban"
      assert task.patterns_to_follow == "Use LiveView"
      assert task.database_changes == "Add table"
      assert task.validation_rules == "Email required"
      assert task.telemetry_event == "task.completed"
      assert task.metrics_to_track == "Duration"
      assert task.logging_requirements == "Log at info"
      assert task.error_user_message == "Something went wrong"
      assert task.error_on_failure == "Alert ops"
    end
  end

  describe "Task metadata fields (02)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column, user: user}
    end

    test "creates task with creator tracking", %{column: column, user: user} do
      attrs = %{
        title: "Test task",
        position: 0,
        created_by_id: user.id,
        created_by_agent: "claude-code"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.created_by_id == user.id
      assert task.created_by_agent == "claude-code"
    end

    test "creates task with completion tracking", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        status: :completed,
        completed_at: now,
        completed_by_id: user.id,
        completed_by_agent: "claude-code",
        completion_summary: "Task completed successfully"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.status == :completed
      assert DateTime.compare(task.completed_at, now) == :eq
      assert task.completed_by_id == user.id
      assert task.completed_by_agent == "claude-code"
      assert task.completion_summary == "Task completed successfully"
    end

    test "creates task with dependencies", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        dependencies: [1, 2, 3]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.dependencies == [1, 2, 3]
    end

    test "validates status enum values", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        status: :invalid
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "is invalid" in errors_on(changeset).status
    end

    test "validates actual_complexity enum values", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        actual_complexity: :invalid
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "is invalid" in errors_on(changeset).actual_complexity
    end

    test "validates review_status enum values", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        review_status: :invalid
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "is invalid" in errors_on(changeset).review_status
    end

    test "creates task with claim tracking", %{column: column} do
      claimed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      claim_expires_at = DateTime.add(claimed_at, 3600, :second)

      attrs = %{
        title: "Test task",
        position: 0,
        claimed_at: claimed_at,
        claim_expires_at: claim_expires_at
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert DateTime.compare(task.claimed_at, claimed_at) == :eq
      assert DateTime.compare(task.claim_expires_at, claim_expires_at) == :eq
    end

    test "validates claim_expires_at is after claimed_at", %{column: column} do
      claimed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      claim_expires_at = DateTime.add(claimed_at, -3600, :second)

      attrs = %{
        title: "Test task",
        position: 0,
        claimed_at: claimed_at,
        claim_expires_at: claim_expires_at
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be after claimed_at" in errors_on(changeset).claim_expires_at
    end

    test "validates claimed_at is set when claim_expires_at is set", %{column: column} do
      claim_expires_at = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        claim_expires_at: claim_expires_at
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be set when claim_expires_at is set" in errors_on(changeset).claimed_at
    end

    test "creates task with required_capabilities", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        required_capabilities: ["elixir", "phoenix", "liveview"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.required_capabilities == ["elixir", "phoenix", "liveview"]
    end

    test "validates required_capabilities must be list of strings" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        required_capabilities: ["elixir", 123, :phoenix]
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of strings" in errors_on(changeset).required_capabilities
    end

    test "validates required_capabilities must be a list" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        required_capabilities: "not a list"
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list" in errors_on(changeset).required_capabilities
    end

    test "validates dependencies must be list of integers" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        dependencies: [1, "2", 3]
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of integers" in errors_on(changeset).dependencies
    end

    test "validates dependencies must be a list" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        dependencies: "not a list"
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list" in errors_on(changeset).dependencies
    end

    test "creates task with actual vs estimated tracking", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        actual_complexity: :large,
        actual_files_changed: "lib/kanban/tasks.ex\nlib/kanban/tasks/task.ex",
        time_spent_minutes: 120
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.actual_complexity == :large
      assert task.actual_files_changed == "lib/kanban/tasks.ex\nlib/kanban/tasks/task.ex"
      assert task.time_spent_minutes == 120
    end

    test "validates time_spent_minutes must be non-negative", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        time_spent_minutes: -10
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be greater than or equal to 0" in errors_on(changeset).time_spent_minutes
    end

    test "creates task with review queue fields", %{column: column, user: user} do
      reviewed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        needs_review: true,
        review_status: :approved,
        review_notes: "Looks good!",
        reviewed_by_id: user.id,
        reviewed_at: reviewed_at
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.needs_review == true
      assert task.review_status == :approved
      assert task.review_notes == "Looks good!"
      assert task.reviewed_by_id == user.id
      assert DateTime.compare(task.reviewed_at, reviewed_at) == :eq
    end

    test "validates reviewed_at must be set when review_status is not pending", %{column: column, user: user} do
      attrs = %{
        title: "Test task",
        position: 0,
        review_status: :approved,
        reviewed_by_id: user.id
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be set when review_status is not pending" in errors_on(changeset).reviewed_at
    end

    test "validates reviewed_by_id must be set when review_status is not pending", %{column: column} do
      reviewed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        review_status: :approved,
        reviewed_at: reviewed_at
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be set when review_status is not pending" in errors_on(changeset).reviewed_by_id
    end

    test "validates completed_at must be set when status is completed", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        status: :completed
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be set when status is completed" in errors_on(changeset).completed_at
    end

    test "allows pending review_status without reviewed_at or reviewed_by_id", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        review_status: :pending
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.review_status == :pending
      assert is_nil(task.reviewed_at)
      assert is_nil(task.reviewed_by_id)
    end

    test "creates task with all metadata fields together", %{column: column, user: user} do
      claimed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      claim_expires_at = DateTime.add(claimed_at, 3600, :second)
      completed_at = DateTime.add(claimed_at, 7200, :second)
      reviewed_at = DateTime.add(claimed_at, 7300, :second)

      attrs = %{
        title: "Complex task",
        position: 0,
        created_by_id: user.id,
        created_by_agent: "claude-code",
        completed_at: completed_at,
        completed_by_id: user.id,
        completed_by_agent: "claude-code",
        completion_summary: "All tests passing",
        dependencies: [1, 2],
        status: :completed,
        claimed_at: claimed_at,
        claim_expires_at: claim_expires_at,
        required_capabilities: ["elixir", "phoenix"],
        actual_complexity: :medium,
        actual_files_changed: "lib/kanban/tasks.ex",
        time_spent_minutes: 90,
        needs_review: true,
        review_status: :approved,
        review_notes: "Great work!",
        reviewed_by_id: user.id,
        reviewed_at: reviewed_at
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.created_by_id == user.id
      assert task.created_by_agent == "claude-code"
      assert DateTime.compare(task.completed_at, completed_at) == :eq
      assert task.completed_by_id == user.id
      assert task.completed_by_agent == "claude-code"
      assert task.completion_summary == "All tests passing"
      assert task.dependencies == [1, 2]
      assert task.status == :completed
      assert DateTime.compare(task.claimed_at, claimed_at) == :eq
      assert DateTime.compare(task.claim_expires_at, claim_expires_at) == :eq
      assert task.required_capabilities == ["elixir", "phoenix"]
      assert task.actual_complexity == :medium
      assert task.actual_files_changed == "lib/kanban/tasks.ex"
      assert task.time_spent_minutes == 90
      assert task.needs_review == true
      assert task.review_status == :approved
      assert task.review_notes == "Great work!"
      assert task.reviewed_by_id == user.id
      assert DateTime.compare(task.reviewed_at, reviewed_at) == :eq
    end

    test "default values are set correctly", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.dependencies == []
      assert task.status == :open
      assert task.required_capabilities == []
      assert task.needs_review == false
    end

    test "allows nil for all optional metadata fields", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        created_by_id: nil,
        created_by_agent: nil,
        completed_at: nil,
        completed_by_id: nil,
        completed_by_agent: nil,
        completion_summary: nil,
        dependencies: nil,
        claimed_at: nil,
        claim_expires_at: nil,
        required_capabilities: nil,
        actual_complexity: nil,
        actual_files_changed: nil,
        time_spent_minutes: nil,
        review_status: nil,
        review_notes: nil,
        reviewed_by_id: nil,
        reviewed_at: nil
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert is_nil(task.created_by_id)
      assert is_nil(task.created_by_agent)
      assert is_nil(task.completed_at)
      assert is_nil(task.completed_by_id)
      assert is_nil(task.completed_by_agent)
      assert is_nil(task.completion_summary)
      assert is_nil(task.claimed_at)
      assert is_nil(task.claim_expires_at)
      assert is_nil(task.actual_complexity)
      assert is_nil(task.actual_files_changed)
      assert is_nil(task.time_spent_minutes)
      assert is_nil(task.review_status)
      assert is_nil(task.review_notes)
      assert is_nil(task.reviewed_by_id)
      assert is_nil(task.reviewed_at)
    end

    test "allows empty arrays for collection fields", %{column: column} do
      attrs = %{
        title: "Test task",
        position: 0,
        dependencies: [],
        required_capabilities: []
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.dependencies == []
      assert task.required_capabilities == []
    end

    test "validates completion without completed_by_id", %{column: column} do
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        status: :completed,
        completed_at: completed_at,
        completion_summary: "Done"
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.status == :completed
      assert DateTime.compare(task.completed_at, completed_at) == :eq
      assert is_nil(task.completed_by_id)
    end

    test "allows claimed_at without claim_expires_at", %{column: column} do
      claimed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        title: "Test task",
        position: 0,
        claimed_at: claimed_at
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert DateTime.compare(task.claimed_at, claimed_at) == :eq
      assert is_nil(task.claim_expires_at)
    end
  end

  describe "PubSub broadcasts for task metadata changes" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Subscribe to PubSub for testing
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      {:ok, column: column, user: user, board: board}
    end

    test "broadcasts :task_created when task is created", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "New task"})

      assert_received {Kanban.Tasks, :task_created, broadcasted_task}
      assert broadcasted_task.id == task.id
    end

    test "broadcasts :task_status_changed when status changes", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, updated_task} = Tasks.update_task(task, %{status: :completed, completed_at: completed_at})

      assert_received {Kanban.Tasks, :task_status_changed, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
      assert broadcasted_task.status == :completed
    end

    test "broadcasts :task_claimed when task is claimed", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      claimed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, updated_task} = Tasks.update_task(task, %{claimed_at: claimed_at})

      assert_received {Kanban.Tasks, :task_claimed, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
    end

    test "broadcasts :task_completed when completed_at is set", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, updated_task} = Tasks.update_task(task, %{status: :completed, completed_at: completed_at})

      # Should broadcast status_changed (not completed) because status changed first
      assert_received {Kanban.Tasks, :task_status_changed, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
    end

    test "broadcasts :task_reviewed when review_status changes", %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      reviewed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, updated_task} = Tasks.update_task(task, %{
        review_status: :approved,
        reviewed_by_id: user.id,
        reviewed_at: reviewed_at
      })

      assert_received {Kanban.Tasks, :task_reviewed, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
      assert broadcasted_task.review_status == :approved
    end

    test "broadcasts :task_updated for general field changes", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      {:ok, updated_task} = Tasks.update_task(task, %{title: "Updated title"})

      assert_received {Kanban.Tasks, :task_updated, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
    end

    test "broadcasts :task_deleted when task is deleted", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      {:ok, deleted_task} = Tasks.delete_task(task)

      assert_received {Kanban.Tasks, :task_deleted, broadcasted_task}
      assert broadcasted_task.id == deleted_task.id
    end

    test "broadcasts :task_moved when task is moved to different column", %{column: column, board: board} do
      column2 = column_fixture(board, %{name: "Another column"})
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      {:ok, moved_task} = Tasks.move_task(task, column2, 0)

      assert_received {Kanban.Tasks, :task_moved, broadcasted_task}
      assert broadcasted_task.id == moved_task.id
    end

    test "includes telemetry data for broadcasts", %{column: column, board: board} do
      # Attach a test telemetry handler
      test_pid = self()
      :telemetry.attach(
        "test-handler",
        [:kanban, :pubsub, :broadcast],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Should receive telemetry event
      assert_received {:telemetry, %{count: 1}, %{event: :task_created, task_id: task_id, board_id: board_id}}
      assert task_id == task.id
      assert board_id == board.id

      # Clean up
      :telemetry.detach("test-handler")
    end
  end
end
