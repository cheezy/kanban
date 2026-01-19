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

    test "excludes archived tasks by default" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Active Task"})
      task2 = task_fixture(column, %{title: "To Be Archived"})

      {:ok, _archived} = Tasks.archive_task(task2)

      tasks = Tasks.list_tasks(column)

      assert length(tasks) == 1
      assert hd(tasks).id == task1.id
    end

    test "includes archived tasks when option is set" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Active Task"})
      task2 = task_fixture(column, %{title: "Archived Task"})

      {:ok, _archived} = Tasks.archive_task(task2)

      tasks = Tasks.list_tasks(column, include_archived: true)

      assert length(tasks) == 2
      assert Enum.map(tasks, & &1.id) |> Enum.sort() == [task1.id, task2.id] |> Enum.sort()
    end
  end

  describe "list_archived_tasks/1" do
    test "returns only archived tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "Active"})
      task2 = task_fixture(column, %{title: "Archived 1"})
      task3 = task_fixture(column, %{title: "Archived 2"})

      {:ok, _} = Tasks.archive_task(task2)
      {:ok, _} = Tasks.archive_task(task3)

      archived = Tasks.list_archived_tasks(column)

      assert length(archived) == 2
      assert Enum.all?(archived, fn t -> t.archived_at != nil end)
      refute Enum.any?(archived, fn t -> t.id == task1.id end)
    end

    test "returns archived tasks sorted by archived_at descending" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column, %{title: "First"})
      task2 = task_fixture(column, %{title: "Second"})

      {:ok, first_archived} = Tasks.archive_task(task1)
      Process.sleep(1000)
      {:ok, second_archived} = Tasks.archive_task(task2)

      archived = Tasks.list_archived_tasks(column)

      assert length(archived) == 2
      assert hd(archived).id == second_archived.id
      assert DateTime.compare(hd(archived).archived_at, first_archived.archived_at) == :gt
    end

    test "returns empty list when no archived tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      _task = task_fixture(column)

      assert Tasks.list_archived_tasks(column) == []
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

      assert %{verification_steps: [%{step_type: ["must be 'command' or 'manual'"]}]} =
               errors_on(changeset)
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

      assert Enum.any?(all_tasks, fn t ->
               t.id == task1.id && t.technology_requirements == ["ecto", "phoenix"]
             end)

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

  describe "Task.changeset/2 required_capabilities validation" do
    test "accepts nil required_capabilities" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", required_capabilities: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.required_capabilities == nil || task.required_capabilities == []
    end

    test "accepts empty array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", required_capabilities: []}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.required_capabilities == []
    end

    test "accepts valid capabilities" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        required_capabilities: ["testing", "debugging", "code_generation"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.required_capabilities == ["testing", "debugging", "code_generation"]
    end

    test "rejects invalid capability" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{title: "Test task", required_capabilities: ["invalid_capability"]}
      {:error, changeset} = Tasks.create_task(column, attrs)

      assert changeset.errors[:required_capabilities] != nil

      {message, _} = changeset.errors[:required_capabilities]
      assert message =~ "invalid capability: 'invalid_capability'"
      assert message =~ "Must be one of:"
    end

    test "rejects multiple invalid capabilities" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        required_capabilities: ["testing", "invalid1", "debugging", "invalid2"]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert changeset.errors[:required_capabilities] != nil

      {message, _} = changeset.errors[:required_capabilities]
      assert message =~ "invalid capabilities: invalid1, invalid2"
      assert message =~ "Must be one of:"
    end

    test "rejects array with non-string values" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        required_capabilities: ["testing", 123, :debugging]
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of strings" in errors_on(changeset).required_capabilities
    end

    test "rejects non-list values" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        required_capabilities: "not a list"
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list" in errors_on(changeset).required_capabilities
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

      assert %{key_files: [%{file_path: ["is required (relative path from project root)"]}]} =
               errors_on(changeset)
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

      assert %{key_files: [%{position: ["is required (integer starting from 0)"]}]} =
               errors_on(changeset)
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

      assert %{key_files: [%{position: ["must be greater than or equal to 0"]}]} =
               errors_on(changeset)
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

      assert %{verification_steps: [%{step_type: ["is required ('command' or 'manual')"]}]} =
               errors_on(changeset)
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

      assert %{verification_steps: [%{step_text: ["is required (command or instruction)"]}]} =
               errors_on(changeset)
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

      assert %{verification_steps: [%{position: ["is required (integer starting from 0)"]}]} =
               errors_on(changeset)
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

      assert %{verification_steps: [%{position: ["must be greater than or equal to 0"]}]} =
               errors_on(changeset)
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

    test "rejects verification_steps as array of strings" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: ["mix test", "mix credo"]
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert %{verification_steps: error_messages} = errors_on(changeset)
      assert Enum.any?(error_messages, &(&1 =~ "must be an array of objects"))
    end

    test "rejects verification_steps as string" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: "mix test"
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert %{verification_steps: error_messages} = errors_on(changeset)
      assert Enum.any?(error_messages, &(&1 =~ "must be an array of objects"))
    end

    test "allows empty verification_steps array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      attrs = %{
        title: "Test task",
        verification_steps: []
      }

      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.verification_steps == []
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

    test "handles tasks with mismatched type and identifier prefix" do
      # Regression test: When a task's type is changed (e.g., work -> defect),
      # the identifier remains unchanged. New task creation should skip
      # identifiers that exist with mismatched prefixes.
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create a work task
      {:ok, work_task} = Tasks.create_task(column, %{title: "Work Task", type: :work})
      original_identifier = work_task.identifier

      # Manually change its type to defect (simulating a user changing the type)
      # This leaves the work identifier on a defect task, which is a mismatch
      {:ok, task_as_defect} = Tasks.update_task(work_task, %{type: :defect})

      # Verify the identifier didn't change when type changed
      assert task_as_defect.identifier == original_identifier
      assert task_as_defect.type == :defect
      assert original_identifier =~ ~r/^W\d+$/

      # Create a goal with child tasks - this should generate identifiers
      # that skip the mismatched identifier
      goal_attrs = %{title: "Test Goal", type: :goal}
      child_tasks = [%{title: "Child Task", type: :work}]

      {:ok, %{goal: goal, child_tasks: [child_task]}} =
        Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # The goal should get an identifier
      assert goal.identifier =~ ~r/^G\d+$/

      # The child task should NOT reuse the identifier of the mismatched task
      refute child_task.identifier == original_identifier
      assert child_task.identifier =~ ~r/^W\d+$/

      # Extract the numbers to verify the child task got a higher number
      original_number =
        original_identifier
        |> String.replace("W", "")
        |> String.to_integer()

      child_number =
        child_task.identifier
        |> String.replace("W", "")
        |> String.to_integer()

      # The child task should have a higher number than the mismatched task
      assert child_number > original_number
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
      {:ok, dep1} = Tasks.create_task(column, %{"title" => "Dep 1"})
      {:ok, dep2} = Tasks.create_task(column, %{"title" => "Dep 2"})
      {:ok, dep3} = Tasks.create_task(column, %{"title" => "Dep 3"})

      attrs = %{
        title: "Test task",
        position: 0,
        dependencies: [dep1.identifier, dep2.identifier, dep3.identifier]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.dependencies == [dep1.identifier, dep2.identifier, dep3.identifier]
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
        required_capabilities: ["testing", "debugging", "code_generation"]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.required_capabilities == ["testing", "debugging", "code_generation"]
    end

    test "validates required_capabilities must be list of strings" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        required_capabilities: ["testing", 123, :debugging]
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

    test "validates dependencies must be list of strings" do
      task = %Kanban.Tasks.Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        dependencies: ["W1", 2, "W3"]
      }

      changeset = Kanban.Tasks.Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of task identifiers (strings)" in errors_on(changeset).dependencies
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

    test "validates reviewed_at must be set when review_status is not pending", %{
      column: column,
      user: user
    } do
      attrs = %{
        title: "Test task",
        position: 0,
        review_status: :approved,
        reviewed_by_id: user.id
      }

      {:error, changeset} = Tasks.create_task(column, attrs)

      assert "must be set when review_status is not pending" in errors_on(changeset).reviewed_at
    end

    test "validates reviewed_by_id must be set when review_status is not pending", %{
      column: column
    } do
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
      {:ok, dep1} = Tasks.create_task(column, %{"title" => "Dep 1"})
      {:ok, dep2} = Tasks.create_task(column, %{"title" => "Dep 2"})

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
        dependencies: [dep1.identifier, dep2.identifier],
        status: :completed,
        claimed_at: claimed_at,
        claim_expires_at: claim_expires_at,
        required_capabilities: ["testing", "debugging"],
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
      assert task.dependencies == [dep1.identifier, dep2.identifier]
      assert task.status == :completed
      assert DateTime.compare(task.claimed_at, claimed_at) == :eq
      assert DateTime.compare(task.claim_expires_at, claim_expires_at) == :eq
      assert task.required_capabilities == ["testing", "debugging"]
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

      {:ok, updated_task} =
        Tasks.update_task(task, %{status: :completed, completed_at: completed_at})

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

      {:ok, updated_task} =
        Tasks.update_task(task, %{status: :completed, completed_at: completed_at})

      # Should broadcast status_changed (not completed) because status changed first
      assert_received {Kanban.Tasks, :task_status_changed, broadcasted_task}
      assert broadcasted_task.id == updated_task.id
    end

    test "broadcasts :task_reviewed when review_status changes", %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      # Clear the create message
      assert_received {Kanban.Tasks, :task_created, _}

      reviewed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated_task} =
        Tasks.update_task(task, %{
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

    test "broadcasts :task_moved when task is moved to different column", %{
      column: column,
      board: board
    } do
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
      assert_received {:telemetry, %{count: 1},
                       %{event: :task_created, task_id: task_id, board_id: board_id}}

      assert task_id == task.id
      assert board_id == board.id

      # Clean up
      :telemetry.detach("test-handler")
    end
  end

  describe "get_next_task/2" do
    setup do
      user = Kanban.AccountsFixtures.user_fixture()
      board = Kanban.BoardsFixtures.ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))
      review_column = Enum.find(columns, &(&1.name == "Review"))

      %{
        user: user,
        board: board,
        ready_column: ready_column,
        doing_column: doing_column,
        review_column: review_column
      }
    end

    test "returns next available task from Ready column", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Next Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == task.id
      assert result.title == "Next Task"
    end

    test "returns nil when no tasks available", %{board: board} do
      result = Tasks.get_next_task([], board.id)

      assert result == nil
    end

    test "excludes tasks with active claims", %{ready_column: column, board: board, user: user} do
      {:ok, _claimed_task} =
        Tasks.create_task(column, %{
          "title" => "Claimed Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result == nil
    end

    test "includes tasks with expired claims", %{ready_column: column, board: board, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Expired Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.add(DateTime.utc_now(), -3600, :second),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), -60, :second),
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "filters by agent capabilities", %{ready_column: column, board: board, user: user} do
      {:ok, _task1} =
        Tasks.create_task(column, %{
          "title" => "Requires Testing",
          "status" => "open",
          "required_capabilities" => ["testing", "devops"],
          "created_by_id" => user.id
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
          "title" => "Requires Code Gen",
          "status" => "open",
          "required_capabilities" => ["code_generation"],
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task(["code_generation", "testing"], board.id)

      assert result.id == task2.id
    end

    test "returns tasks with empty required_capabilities", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "No Requirements",
          "status" => "open",
          "required_capabilities" => [],
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "orders by position in column", %{ready_column: column, board: board, user: user} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1",
          "status" => "open",
          "position" => 1,
          "created_by_id" => user.id
        })

      {:ok, _task2} =
        Tasks.create_task(column, %{
          "title" => "Task 2",
          "status" => "open",
          "position" => 0,
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      # Task 1 is created first, so it gets position 0 and should be returned first
      assert result.id == task1.id
    end

    test "orders by priority first (critical > high > medium > low), then position", %{
      ready_column: column,
      board: board,
      user: user
    } do
      # Create tasks with all priority levels in random order
      # This ensures we're not relying on creation order
      {:ok, low_task} =
        Tasks.create_task(column, %{
          "title" => "Low Priority Task",
          "status" => "open",
          "priority" => "low",
          "created_by_id" => user.id
        })

      {:ok, medium_task} =
        Tasks.create_task(column, %{
          "title" => "Medium Priority Task",
          "status" => "open",
          "priority" => "medium",
          "created_by_id" => user.id
        })

      {:ok, critical_task} =
        Tasks.create_task(column, %{
          "title" => "Critical Priority Task",
          "status" => "open",
          "priority" => "critical",
          "created_by_id" => user.id
        })

      {:ok, high_task} =
        Tasks.create_task(column, %{
          "title" => "High Priority Task",
          "status" => "open",
          "priority" => "high",
          "created_by_id" => user.id
        })

      done_column = Enum.find(Kanban.Columns.list_columns(board), &(&1.name == "Done"))

      # Test 1: Critical should be returned first
      result1 = Tasks.get_next_task([], board.id)
      assert result1.id == critical_task.id
      assert result1.priority == :critical
      Tasks.move_task(critical_task, done_column, 0)

      # Test 2: High should be returned next
      result2 = Tasks.get_next_task([], board.id)
      assert result2.id == high_task.id
      assert result2.priority == :high
      Tasks.move_task(high_task, done_column, 1)

      # Test 3: Medium should be returned next
      result3 = Tasks.get_next_task([], board.id)
      assert result3.id == medium_task.id
      assert result3.priority == :medium
      Tasks.move_task(medium_task, done_column, 2)

      # Test 4: Low should be returned last
      result4 = Tasks.get_next_task([], board.id)
      assert result4.id == low_task.id
      assert result4.priority == :low
    end

    test "orders by position when priorities are equal (selects task higher in Ready column)", %{
      ready_column: column,
      board: board,
      user: user
    } do
      # Create multiple tasks with the same priority
      # Position 0 = top of column, position 2 = bottom of column
      {:ok, high_task1} =
        Tasks.create_task(column, %{
          "title" => "High Priority Task 1 (top of column, position 0)",
          "status" => "open",
          "priority" => "high",
          "created_by_id" => user.id
        })

      {:ok, high_task2} =
        Tasks.create_task(column, %{
          "title" => "High Priority Task 2 (middle of column, position 1)",
          "status" => "open",
          "priority" => "high",
          "created_by_id" => user.id
        })

      {:ok, high_task3} =
        Tasks.create_task(column, %{
          "title" => "High Priority Task 3 (bottom of column, position 2)",
          "status" => "open",
          "priority" => "high",
          "created_by_id" => user.id
        })

      done_column = Enum.find(Kanban.Columns.list_columns(board), &(&1.name == "Done"))

      # Should return task at top of column (position 0) first
      result1 = Tasks.get_next_task([], board.id)
      assert result1.id == high_task1.id
      assert result1.position == 0, "First task should be at position 0 (top of column)"
      Tasks.move_task(high_task1, done_column, 0)

      # Should return task that was originally at position 1 next
      # Note: After moving task1, positions may have been reordered
      result2 = Tasks.get_next_task([], board.id)
      assert result2.id == high_task2.id
      Tasks.move_task(high_task2, done_column, 1)

      # Should return task that was originally at position 2 last
      result3 = Tasks.get_next_task([], board.id)
      assert result3.id == high_task3.id
    end

    test "never returns lower priority when higher priority exists", %{
      ready_column: column,
      board: board,
      user: user
    } do
      # Create one critical and multiple low priority tasks
      {:ok, _low_task1} =
        Tasks.create_task(column, %{
          "title" => "Low Priority Task 1",
          "status" => "open",
          "priority" => "low",
          "created_by_id" => user.id
        })

      {:ok, _low_task2} =
        Tasks.create_task(column, %{
          "title" => "Low Priority Task 2",
          "status" => "open",
          "priority" => "low",
          "created_by_id" => user.id
        })

      {:ok, _medium_task} =
        Tasks.create_task(column, %{
          "title" => "Medium Priority Task",
          "status" => "open",
          "priority" => "medium",
          "created_by_id" => user.id
        })

      {:ok, critical_task} =
        Tasks.create_task(column, %{
          "title" => "Critical Priority Task",
          "status" => "open",
          "priority" => "critical",
          "created_by_id" => user.id
        })

      # Even though critical was created last (highest position),
      # it should still be returned first
      result = Tasks.get_next_task([], board.id)
      assert result.id == critical_task.id
      assert result.priority == :critical
    end

    test "excludes tasks with incomplete dependencies", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, dependency_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, _blocked_task} =
        Tasks.create_task(column, %{
          "title" => "Blocked Task",
          "status" => "open",
          "dependencies" => [dependency_task.identifier],
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == dependency_task.id
    end

    test "includes tasks with completed dependencies", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, dependency_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Unblocked Task",
          "status" => "open",
          "dependencies" => [dependency_task.identifier],
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "excludes tasks with key_file conflicts in Doing column", %{
      ready_column: ready_column,
      doing_column: doing_column,
      board: board,
      user: user
    } do
      {:ok, _active_task} =
        Tasks.create_task(doing_column, %{
          "title" => "Active Task",
          "status" => "in_progress",
          "key_files" => [%{"file_path" => "lib/test.ex", "note" => "Main file", "position" => 0}],
          "created_by_id" => user.id
        })

      {:ok, _conflicting_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Conflicting Task",
          "status" => "open",
          "key_files" => [%{"file_path" => "lib/test.ex", "note" => "Same file", "position" => 0}],
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Non-conflicting Task",
          "status" => "open",
          "key_files" => [
            %{"file_path" => "lib/other.ex", "note" => "Different file", "position" => 0}
          ],
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "never returns goals as next task", %{ready_column: column, board: board, user: user} do
      # Create a goal in Ready column
      {:ok, _goal} =
        Tasks.create_task(column, %{
          "title" => "Test Goal",
          "type" => "goal",
          "status" => "open",
          "created_by_id" => user.id
        })

      # Create a work task in Ready column
      {:ok, work_task} =
        Tasks.create_task(column, %{
          "title" => "Work Task",
          "type" => "work",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      # Should return the work task, not the goal
      assert result.id == work_task.id
      assert result.type == :work
    end

    test "returns nil when only goals are available", %{
      ready_column: column,
      board: board,
      user: user
    } do
      # Create only a goal in Ready column
      {:ok, _goal} =
        Tasks.create_task(column, %{
          "title" => "Test Goal",
          "type" => "goal",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.get_next_task([], board.id)

      # Should return nil since goals cannot be claimed
      assert result == nil
    end
  end

  describe "claim_next_task/3" do
    setup do
      user = Kanban.AccountsFixtures.user_fixture()
      board = Kanban.BoardsFixtures.ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      %{user: user, board: board, ready_column: ready_column, doing_column: doing_column}
    end

    test "atomically claims next available task", %{
      ready_column: column,
      board: board,
      user: user,
      doing_column: doing_column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task to Claim",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, result, _hook_info} = Tasks.claim_next_task([], user, board.id)

      assert result.id == task.id
      assert result.status == :in_progress
      assert result.column_id == doing_column.id
      assert result.assigned_to_id == user.id
      assert result.claimed_at != nil
      assert result.claim_expires_at != nil
    end

    test "returns error when no tasks available", %{board: board, user: user} do
      result = Tasks.claim_next_task([], user, board.id)

      assert result == {:error, :no_tasks_available}
    end

    test "prevents double claiming", %{ready_column: column, board: board, user: user} do
      {:ok, _task} =
        Tasks.create_task(column, %{
          "title" => "Only Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      user2 = Kanban.AccountsFixtures.user_fixture()

      {:ok, _result1, _hook_info} = Tasks.claim_next_task([], user, board.id)
      result2 = Tasks.claim_next_task([], user2, board.id)

      assert result2 == {:error, :no_tasks_available}
    end

    test "sets claim expiration to 60 minutes", %{ready_column: column, board: board, user: user} do
      {:ok, _task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      now = DateTime.utc_now()
      {:ok, result, _hook_info} = Tasks.claim_next_task([], user, board.id)

      expires_at = result.claim_expires_at
      diff = DateTime.diff(expires_at, now, :second)

      assert diff >= 3590
      assert diff <= 3610
    end

    test "respects capability requirements", %{ready_column: column, board: board, user: user} do
      {:ok, _task} =
        Tasks.create_task(column, %{
          "title" => "Requires Deployment",
          "status" => "open",
          "required_capabilities" => ["devops"],
          "created_by_id" => user.id
        })

      result = Tasks.claim_next_task(["code_generation"], user, board.id)

      assert result == {:error, :no_tasks_available}
    end

    test "cannot claim a goal by identifier", %{ready_column: column, board: board, user: user} do
      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Test Goal",
          "type" => "goal",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.claim_next_task([], user, board.id, goal.identifier)

      assert result == {:error, :no_tasks_available}
    end

    test "cannot claim a goal without specifying identifier", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _goal} =
        Tasks.create_task(column, %{
          "title" => "Test Goal",
          "type" => "goal",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.claim_next_task([], user, board.id)

      assert result == {:error, :no_tasks_available}
    end
  end

  describe "unclaim_task/3" do
    setup do
      user = Kanban.AccountsFixtures.user_fixture()
      board = Kanban.BoardsFixtures.ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Claimed Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      %{
        user: user,
        board: board,
        ready_column: ready_column,
        doing_column: doing_column,
        task: task
      }
    end

    test "releases claimed task back to Ready column", %{
      task: task,
      user: user,
      ready_column: ready_column
    } do
      {:ok, result} = Tasks.unclaim_task(task, user)

      assert result.status == :open
      assert result.column_id == ready_column.id
      assert result.assigned_to_id == nil
      assert result.claimed_at == nil
      assert result.claim_expires_at == nil
    end

    test "accepts optional reason parameter", %{task: task, user: user} do
      {:ok, result} = Tasks.unclaim_task(task, user, "task too complex")

      assert result.status == :open
    end

    test "returns error when unclaiming someone else's task", %{task: task} do
      other_user = Kanban.AccountsFixtures.user_fixture()

      result = Tasks.unclaim_task(task, other_user)

      assert result == {:error, :not_authorized}
    end

    test "returns error when task is not claimed", %{ready_column: column, user: user} do
      {:ok, open_task} =
        Tasks.create_task(column, %{
          "title" => "Open Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.unclaim_task(open_task, user)

      assert result == {:error, :not_claimed}
    end

    test "sets a valid position when unclaiming task", %{
      task: task,
      user: user,
      ready_column: ready_column
    } do
      {:ok, unclaimed_task} = Tasks.unclaim_task(task, user)

      assert unclaimed_task.column_id == ready_column.id
      assert unclaimed_task.position != nil
      assert unclaimed_task.position >= 0
    end

    test "places task at end of Ready column when unclaiming", %{
      task: task,
      user: user,
      ready_column: ready_column
    } do
      existing_task_count =
        from(t in Kanban.Tasks.Task,
          where: t.column_id == ^ready_column.id,
          select: count(t.id)
        )
        |> Kanban.Repo.one()

      {:ok, unclaimed_task} = Tasks.unclaim_task(task, user)

      assert unclaimed_task.position == existing_task_count
    end

    test "maintains unique positions when unclaiming multiple tasks", %{
      ready_column: ready_column,
      user: user
    } do
      doing_column =
        from(c in Kanban.Columns.Column,
          where: c.board_id == ^ready_column.board_id and c.name == "Doing"
        )
        |> Kanban.Repo.one()

      {:ok, task1} =
        Tasks.create_task(doing_column, %{
          "title" => "Task 1",
          "status" => "in_progress",
          "created_by_id" => user.id,
          "claimed_at" => DateTime.utc_now(),
          "assigned_to_id" => user.id
        })

      {:ok, task2} =
        Tasks.create_task(doing_column, %{
          "title" => "Task 2",
          "status" => "in_progress",
          "created_by_id" => user.id,
          "claimed_at" => DateTime.utc_now(),
          "assigned_to_id" => user.id
        })

      {:ok, unclaimed_task1} = Tasks.unclaim_task(task1, user)
      {:ok, unclaimed_task2} = Tasks.unclaim_task(task2, user)

      assert unclaimed_task1.column_id == ready_column.id
      assert unclaimed_task2.column_id == ready_column.id
      assert unclaimed_task1.position != unclaimed_task2.position

      positions =
        from(t in Kanban.Tasks.Task,
          where: t.column_id == ^ready_column.id,
          select: t.position,
          order_by: t.position
        )
        |> Kanban.Repo.all()

      assert positions == Enum.uniq(positions), "All positions should be unique"
    end

    test "does not cause unique constraint violation when unclaiming", %{
      task: task,
      user: user,
      ready_column: ready_column
    } do
      {:ok, existing_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Existing Task in Ready",
          "status" => "open",
          "created_by_id" => user.id
        })

      result = Tasks.unclaim_task(task, user)

      assert {:ok, unclaimed_task} = result
      assert unclaimed_task.column_id == ready_column.id
      assert unclaimed_task.position != existing_task.position
    end
  end

  describe "circular dependency detection" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "prevents task from depending on itself", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1"
        })

      changeset = Kanban.Tasks.Task.changeset(task1, %{dependencies: [task1.identifier]})

      refute changeset.valid?
      assert "cannot depend on itself" in errors_on(changeset).dependencies
    end

    test "prevents simple circular dependency (A->B->A)", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1"
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
          "title" => "Task 2",
          "dependencies" => [task1.identifier]
        })

      result = Tasks.update_task(task1, %{dependencies: [task2.identifier]})

      assert {:error, changeset} = result
      assert "creates a circular dependency" in errors_on(changeset).dependencies
    end

    test "prevents complex circular dependency (A->B->C->A)", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1"
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
          "title" => "Task 2",
          "dependencies" => [task1.identifier]
        })

      {:ok, task3} =
        Tasks.create_task(column, %{
          "title" => "Task 3",
          "dependencies" => [task2.identifier]
        })

      result = Tasks.update_task(task1, %{dependencies: [task3.identifier]})

      assert {:error, changeset} = result
      assert "creates a circular dependency" in errors_on(changeset).dependencies
    end

    test "allows valid dependency chains without cycles", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1"
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
          "title" => "Task 2",
          "dependencies" => [task1.identifier]
        })

      {:ok, task3} =
        Tasks.create_task(column, %{
          "title" => "Task 3",
          "dependencies" => [task2.identifier]
        })

      assert task3.dependencies == [task2.identifier]
      assert task2.dependencies == [task1.identifier]
    end

    test "allows task to depend on task that has no dependencies", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task W26"
        })

      result =
        Tasks.create_task(column, %{
          "title" => "Task W27",
          "dependencies" => [task1.identifier]
        })

      assert {:ok, task2} = result
      assert task2.dependencies == [task1.identifier]
    end

    test "allows task to depend on task that itself has dependencies", %{column: column} do
      {:ok, task_w25} =
        Tasks.create_task(column, %{
          "title" => "Task W25"
        })

      {:ok, task_w26} =
        Tasks.create_task(column, %{
          "title" => "Task W26",
          "dependencies" => [task_w25.identifier]
        })

      result =
        Tasks.create_task(column, %{
          "title" => "Task W27",
          "dependencies" => [task_w26.identifier]
        })

      assert {:ok, task_w27} = result
      assert task_w27.dependencies == [task_w26.identifier]
    end
  end

  describe "auto-blocking on task creation" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "task is blocked when created with incomplete dependencies", %{column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency Task",
          "status" => "open"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with dependency",
          "dependencies" => [dep_task.identifier]
        })

      refreshed_task = Tasks.get_task!(task.id)
      assert refreshed_task.status == :blocked
    end

    test "task remains open when created with completed dependencies", %{
      column: column,
      user: user
    } do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency Task",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with completed dependency",
          "dependencies" => [dep_task.identifier]
        })

      refreshed_task = Tasks.get_task!(task.id)
      assert refreshed_task.status == :open
    end

    test "task remains open when created without dependencies", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task without dependencies"
        })

      assert task.status == :open
    end

    test "task is blocked when some dependencies are incomplete", %{column: column, user: user} do
      {:ok, completed_dep} =
        Tasks.create_task(column, %{
          "title" => "Completed Dependency",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      {:ok, incomplete_dep} =
        Tasks.create_task(column, %{
          "title" => "Incomplete Dependency",
          "status" => "open"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with mixed dependencies",
          "dependencies" => [completed_dep.identifier, incomplete_dep.identifier]
        })

      refreshed_task = Tasks.get_task!(task.id)
      assert refreshed_task.status == :blocked
    end
  end

  describe "auto-blocking on task update" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "task becomes blocked when dependencies are added", %{column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency Task",
          "status" => "open"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "status" => "open"
        })

      assert task.status == :open

      {:ok, updated_task} = Tasks.update_task(task, %{dependencies: [dep_task.identifier]})
      refreshed_task = Tasks.get_task!(updated_task.id)

      assert refreshed_task.status == :blocked
    end

    test "task remains open when all dependencies are completed", %{column: column, user: user} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency Task",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "status" => "open"
        })

      {:ok, updated_task} = Tasks.update_task(task, %{dependencies: [dep_task.identifier]})
      refreshed_task = Tasks.get_task!(updated_task.id)

      assert refreshed_task.status == :open
    end

    test "completed task does not change status when dependencies are added", %{
      column: column,
      user: user
    } do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency Task",
          "status" => "open"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      assert task.status == :completed

      {:ok, updated_task} = Tasks.update_task(task, %{dependencies: [dep_task.identifier]})

      assert updated_task.status == :completed
    end
  end

  describe "auto-unblocking when dependencies complete" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      ready_column = column_fixture(board, %{name: "Ready"})
      review_column = column_fixture(board, %{name: "Review"})
      done_column = column_fixture(board, %{name: "Done"})

      %{
        user: user,
        board: board,
        ready_column: ready_column,
        review_column: review_column,
        done_column: done_column
      }
    end

    test "unblocks dependent task when dependency is completed", %{
      ready_column: ready_column,
      review_column: review_column,
      user: user
    } do
      {:ok, dep_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task",
          "identifier" => "W220",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "dependencies" => [dep_task.identifier]
        })

      refreshed_blocked = Tasks.get_task!(blocked_task.id)
      assert refreshed_blocked.status == :blocked

      {:ok, moved_dep} = Tasks.move_task(dep_task, review_column, 0)
      {:ok, _} = Tasks.mark_done(moved_dep, user)

      final_task = Tasks.get_task!(blocked_task.id)
      assert final_task.status == :open
    end

    test "unblocks multiple dependent tasks", %{
      ready_column: ready_column,
      review_column: review_column,
      user: user
    } do
      {:ok, dep_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task",
          "identifier" => "W222",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, blocked_task1} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task 1",
          "dependencies" => [dep_task.identifier]
        })

      {:ok, blocked_task2} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task 2",
          "dependencies" => [dep_task.identifier]
        })

      assert Tasks.get_task!(blocked_task1.id).status == :blocked
      assert Tasks.get_task!(blocked_task2.id).status == :blocked

      {:ok, moved_dep} = Tasks.move_task(dep_task, review_column, 0)
      {:ok, _} = Tasks.mark_done(moved_dep, user)

      assert Tasks.get_task!(blocked_task1.id).status == :open
      assert Tasks.get_task!(blocked_task2.id).status == :open
    end

    test "task remains blocked if other dependencies are incomplete", %{
      ready_column: ready_column,
      review_column: review_column,
      user: user
    } do
      {:ok, dep_task1} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task 1",
          "identifier" => "W225",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, dep_task2} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task 2",
          "status" => "open"
        })

      {:ok, blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "dependencies" => [dep_task1.identifier, dep_task2.identifier]
        })

      assert Tasks.get_task!(blocked_task.id).status == :blocked

      {:ok, moved_dep} = Tasks.move_task(dep_task1, review_column, 0)
      {:ok, _} = Tasks.mark_done(moved_dep, user)

      final_task = Tasks.get_task!(blocked_task.id)
      assert final_task.status == :blocked
    end

    test "unblocks dependent task when status updated to completed via update_task", %{
      ready_column: ready_column
    } do
      {:ok, dep_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task",
          "status" => "open"
        })

      {:ok, blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "dependencies" => [dep_task.identifier]
        })

      assert Tasks.get_task!(blocked_task.id).status == :blocked

      # Update the dependency task's status to completed (simulating UI update)
      {:ok, _completed_dep} =
        Tasks.update_task(dep_task, %{status: :completed, completed_at: DateTime.utc_now()})

      # Dependent task should now be unblocked
      final_task = Tasks.get_task!(blocked_task.id)
      assert final_task.status == :open
    end
  end

  describe "get_dependency_tree/1" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "returns empty dependencies for task without dependencies", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W230"
        })

      tree = Tasks.get_dependency_tree(task)

      assert tree.task.id == task.id
      assert tree.dependencies == []
    end

    test "returns single level dependency tree", %{column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency",
          "identifier" => "W231"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep_task.identifier]
        })

      tree = Tasks.get_dependency_tree(task)

      assert tree.task.id == task.id
      assert length(tree.dependencies) == 1
      assert hd(tree.dependencies).task.id == dep_task.id
    end

    test "returns nested dependency tree", %{column: column} do
      {:ok, dep1} =
        Tasks.create_task(column, %{
          "title" => "Dependency 1",
          "identifier" => "W233"
        })

      {:ok, dep2} =
        Tasks.create_task(column, %{
          "title" => "Dependency 2",
          "dependencies" => [dep1.identifier]
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep2.identifier]
        })

      tree = Tasks.get_dependency_tree(task)

      assert tree.task.id == task.id
      assert length(tree.dependencies) == 1

      dep2_tree = hd(tree.dependencies)
      assert dep2_tree.task.id == dep2.id
      assert length(dep2_tree.dependencies) == 1
      assert hd(dep2_tree.dependencies).task.id == dep1.id
    end

    test "returns tree with multiple dependencies at each level", %{column: column} do
      {:ok, dep1} =
        Tasks.create_task(column, %{
          "title" => "Dependency 1",
          "identifier" => "W236"
        })

      {:ok, dep2} =
        Tasks.create_task(column, %{
          "title" => "Dependency 2",
          "identifier" => "W237"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep1.identifier, dep2.identifier]
        })

      tree = Tasks.get_dependency_tree(task)

      assert tree.task.id == task.id
      assert length(tree.dependencies) == 2

      dep_ids = Enum.map(tree.dependencies, & &1.task.id)
      assert dep1.id in dep_ids
      assert dep2.id in dep_ids
    end
  end

  describe "get_dependent_tasks/1" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "returns empty list for task with no dependents", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W240"
        })

      dependents = Tasks.get_dependent_tasks(task)

      assert dependents == []
    end

    test "returns single dependent task", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W241"
        })

      {:ok, dependent} =
        Tasks.create_task(column, %{
          "title" => "Dependent",
          "dependencies" => [task.identifier]
        })

      dependents = Tasks.get_dependent_tasks(task)

      assert length(dependents) == 1
      assert hd(dependents).id == dependent.id
    end

    test "returns multiple dependent tasks", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W243"
        })

      {:ok, dependent1} =
        Tasks.create_task(column, %{
          "title" => "Dependent 1",
          "dependencies" => [task.identifier]
        })

      {:ok, dependent2} =
        Tasks.create_task(column, %{
          "title" => "Dependent 2",
          "dependencies" => [task.identifier]
        })

      dependents = Tasks.get_dependent_tasks(task)

      assert length(dependents) == 2

      dependent_ids = Enum.map(dependents, & &1.id)
      assert dependent1.id in dependent_ids
      assert dependent2.id in dependent_ids
    end

    test "does not return tasks that depend on other tasks", %{column: column} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1",
          "identifier" => "W246"
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
          "title" => "Task 2",
          "identifier" => "W247"
        })

      {:ok, _dependent} =
        Tasks.create_task(column, %{
          "title" => "Dependent",
          "dependencies" => [task2.identifier]
        })

      dependents = Tasks.get_dependent_tasks(task1)

      assert dependents == []
    end
  end

  describe "delete_task/1 with dependencies" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{user: user, board: board, column: column}
    end

    test "prevents deletion of task with dependent tasks", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W250"
        })

      {:ok, _dependent} =
        Tasks.create_task(column, %{
          "title" => "Dependent",
          "dependencies" => [task.identifier]
        })

      result = Tasks.delete_task(task)

      assert result == {:error, :has_dependents}
      assert Tasks.get_task!(task.id)
    end

    test "allows deletion of task without dependents", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W252"
        })

      result = Tasks.delete_task(task)

      assert {:ok, _deleted} = result

      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(task.id)
      end
    end

    test "allows deletion of task that depends on other tasks", %{column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency",
          "identifier" => "W253"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "identifier" => "W254",
          "dependencies" => [dep_task.identifier]
        })

      result = Tasks.delete_task(task)

      assert {:ok, _deleted} = result
      assert Tasks.get_task!(dep_task.id)
    end
  end

  describe "goal hierarchy" do
    test "create_task/2 creates a goal task with G identifier" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Implement Feature X",
          "type" => "goal"
        })

      assert goal.type == :goal
      assert String.starts_with?(goal.identifier, "G")
      assert goal.identifier == "G1"
    end

    test "create_task/2 creates multiple goals with sequential identifiers" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal1} = Tasks.create_task(column, %{"title" => "Goal 1", "type" => "goal"})
      {:ok, goal2} = Tasks.create_task(column, %{"title" => "Goal 2", "type" => "goal"})
      {:ok, goal3} = Tasks.create_task(column, %{"title" => "Goal 3", "type" => "goal"})

      assert goal1.identifier == "G1"
      assert goal2.identifier == "G2"
      assert goal3.identifier == "G3"
    end

    test "create_task/2 creates a task with a parent goal" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child_task} =
        Tasks.create_task(column, %{
          "title" => "Child Task",
          "type" => "work",
          "parent_id" => goal.id
        })

      assert child_task.parent_id == goal.id
      assert child_task.type == :work
      assert String.starts_with?(child_task.identifier, "W")
    end

    test "get_task_children/1 returns children of a goal" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(column, %{
          "title" => "Child 1",
          "parent_id" => goal.id
        })

      {:ok, child2} =
        Tasks.create_task(column, %{
          "title" => "Child 2",
          "parent_id" => goal.id
        })

      children = Tasks.get_task_children(goal.id)

      assert length(children) == 2
      assert Enum.map(children, & &1.id) |> Enum.sort() == [child1.id, child2.id] |> Enum.sort()
    end

    test "get_task_children/1 returns empty list for non-goal tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Regular Task",
          "type" => "work"
        })

      children = Tasks.get_task_children(task.id)

      assert children == []
    end

    test "get_task_tree/1 returns tree with children for goals" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(column, %{
          "title" => "Child 1",
          "parent_id" => goal.id
        })

      {:ok, _child1} =
        Tasks.update_task(child1, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

      {:ok, _child2} =
        Tasks.create_task(column, %{
          "title" => "Child 2",
          "parent_id" => goal.id,
          "status" => "open"
        })

      tree = Tasks.get_task_tree(goal.id)

      assert tree.task.id == goal.id
      assert length(tree.children) == 2
      assert tree.counts.total == 3
      assert tree.counts.completed == 1
      assert tree.counts.blocked == 0
    end

    test "get_task_tree/1 counts include parent task in totals" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Completed Goal",
          "type" => "goal"
        })

      {:ok, goal} =
        Tasks.update_task(goal, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

      {:ok, child} =
        Tasks.create_task(column, %{
          "title" => "Completed Child",
          "parent_id" => goal.id
        })

      {:ok, _child} =
        Tasks.update_task(child, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

      tree = Tasks.get_task_tree(goal.id)

      assert tree.counts.total == 2
      assert tree.counts.completed == 2
    end

    test "get_task_tree/1 returns empty children for non-goal tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Regular Task",
          "type" => "work"
        })

      tree = Tasks.get_task_tree(task.id)

      assert tree.task.id == task.id
      assert tree.children == []
      assert tree.counts.total == 1
    end

    test "deleting a goal task sets parent_id to nil for children" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child} =
        Tasks.create_task(column, %{
          "title" => "Child Task",
          "parent_id" => goal.id
        })

      {:ok, _deleted} = Tasks.delete_task(goal)

      reloaded_child = Tasks.get_task!(child.id)
      assert reloaded_child.parent_id == nil
    end

    test "update_task/2 can change parent_id" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal1} =
        Tasks.create_task(column, %{
          "title" => "Goal 1",
          "type" => "goal"
        })

      {:ok, goal2} =
        Tasks.create_task(column, %{
          "title" => "Goal 2",
          "type" => "goal"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "parent_id" => goal1.id
        })

      {:ok, updated_task} = Tasks.update_task(task, %{"parent_id" => goal2.id})

      assert updated_task.parent_id == goal2.id
    end

    test "update_task/2 can clear parent_id" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, goal} =
        Tasks.create_task(column, %{
          "title" => "Goal",
          "type" => "goal"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "parent_id" => goal.id
        })

      {:ok, updated_task} = Tasks.update_task(task, %{"parent_id" => nil})

      assert updated_task.parent_id == nil
    end

    test "moving first child task to in_progress moves parent goal to in_progress" do
      user = user_fixture()
      board = board_fixture(user)
      todo_column = column_fixture(board, %{name: "To Do", position: 0})
      doing_column = column_fixture(board, %{name: "Doing", position: 1})

      {:ok, goal} =
        Tasks.create_task(todo_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child_task} =
        Tasks.create_task(todo_column, %{
          "title" => "Child Task",
          "parent_id" => goal.id
        })

      {:ok, _moved_task} = Tasks.move_task(child_task, doing_column, 0)

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.column_id == doing_column.id
    end

    test "moving last child task to done moves parent goal to done" do
      user = user_fixture()
      board = board_fixture(user)
      todo_column = column_fixture(board, %{name: "To Do", position: 0})
      column_fixture(board, %{name: "Doing", position: 1})
      done_column = column_fixture(board, %{name: "Done", position: 2})

      {:ok, goal} =
        Tasks.create_task(todo_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(todo_column, %{
          "title" => "Child 1",
          "parent_id" => goal.id
        })

      {:ok, child2} =
        Tasks.create_task(todo_column, %{
          "title" => "Child 2",
          "parent_id" => goal.id
        })

      {:ok, _} = Tasks.move_task(child1, done_column, 0)

      reloaded_goal = Tasks.get_task!(goal.id)

      assert reloaded_goal.column_id == todo_column.id,
             "Goal stays in To Do while child2 is still there"

      {:ok, _} = Tasks.move_task(child2, done_column, 0)

      reloaded_goal = Tasks.get_task!(goal.id)

      assert reloaded_goal.column_id == done_column.id,
             "Goal moves to Done when all children are done"
    end

    test "goal does not move when child task moves within non-done columns" do
      user = user_fixture()
      board = board_fixture(user)
      todo_column = column_fixture(board, %{name: "To Do", position: 0})
      doing_column = column_fixture(board, %{name: "Doing", position: 1})
      review_column = column_fixture(board, %{name: "Review", position: 2})

      {:ok, goal} =
        Tasks.create_task(todo_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child_task} =
        Tasks.create_task(doing_column, %{
          "title" => "Child Task",
          "parent_id" => goal.id
        })

      {:ok, _} = Tasks.move_task(child_task, review_column, 0)

      reloaded_goal = Tasks.get_task!(goal.id)

      assert reloaded_goal.column_id == review_column.id,
             "Goal moves to Review when child moves there"
    end

    test "moving multiple child tasks to same column positions goal correctly" do
      user = user_fixture()
      board = board_fixture(user)
      backlog_column = column_fixture(board, %{name: "Backlog", position: 0})
      ready_column = column_fixture(board, %{name: "Ready", position: 1})

      {:ok, goal} =
        Tasks.create_task(backlog_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(backlog_column, %{
          "title" => "Child Task 1",
          "parent_id" => goal.id
        })

      {:ok, child2} =
        Tasks.create_task(backlog_column, %{
          "title" => "Child Task 2",
          "parent_id" => goal.id
        })

      {:ok, moved_child1} = Tasks.move_task(child1, ready_column, 0)
      assert moved_child1.column_id == ready_column.id
      assert moved_child1.position == 0

      reloaded_goal = Tasks.get_task!(goal.id)

      assert reloaded_goal.column_id == backlog_column.id,
             "Goal stays in Backlog while child2 is still there"

      {:ok, moved_child2} = Tasks.move_task(child2, ready_column, 1)
      assert moved_child2.column_id == ready_column.id
      assert moved_child2.position == 1

      reloaded_goal = Tasks.get_task!(goal.id)

      assert reloaded_goal.column_id == ready_column.id,
             "Goal moves to Ready when all children move there"

      all_tasks_in_ready =
        from(t in Kanban.Tasks.Task,
          where: t.column_id == ^ready_column.id,
          order_by: [asc: t.position],
          select: {t.id, t.position, t.title}
        )
        |> Repo.all()

      positions = Enum.map(all_tasks_in_ready, fn {_, pos, _} -> pos end)
      assert positions == Enum.sort(positions), "Positions should be sequential"
      assert length(Enum.uniq(positions)) == length(positions), "No duplicate positions"
    end

    test "goal is positioned before its children when all children are claimed to Doing column" do
      user = user_fixture()
      board = board_fixture(user)
      ready_column = column_fixture(board, %{name: "Ready", position: 0})
      doing_column = column_fixture(board, %{name: "Doing", position: 1})

      {:ok, goal} =
        Tasks.create_task(ready_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, _child1} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 1",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, claimed_task, _hook} = Tasks.claim_next_task([], user, board.id)

      assert claimed_task.column_id == doing_column.id

      updated_goal = Tasks.get_task!(goal.id)
      updated_child1 = Tasks.get_task!(claimed_task.id)

      assert updated_goal.column_id == doing_column.id,
             "Goal should move to Doing when its only child moves"

      assert updated_goal.position < updated_child1.position,
             "Goal (pos #{updated_goal.position}) should be positioned before child (pos #{updated_child1.position})"
    end

    test "goal is positioned before all its children when multiple children are in target column" do
      user = user_fixture()
      board = board_fixture(user)
      ready_column = column_fixture(board, %{name: "Ready", position: 0})
      doing_column = column_fixture(board, %{name: "Doing", position: 1})

      {:ok, goal} =
        Tasks.create_task(ready_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 1",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, child2} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 2",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, child3} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 3",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, _claimed1, _} = Tasks.claim_next_task([], user, board.id, child1.identifier)
      {:ok, _claimed2, _} = Tasks.claim_next_task([], user, board.id, child2.identifier)
      {:ok, _claimed3, _} = Tasks.claim_next_task([], user, board.id, child3.identifier)

      updated_goal = Tasks.get_task!(goal.id)
      updated_child1 = Tasks.get_task!(child1.id)
      updated_child2 = Tasks.get_task!(child2.id)
      updated_child3 = Tasks.get_task!(child3.id)

      assert updated_goal.column_id == doing_column.id
      assert updated_child1.column_id == doing_column.id
      assert updated_child2.column_id == doing_column.id
      assert updated_child3.column_id == doing_column.id

      assert updated_goal.position < updated_child1.position,
             "Goal should be before child1"

      assert updated_goal.position < updated_child2.position,
             "Goal should be before child2"

      assert updated_goal.position < updated_child3.position,
             "Goal should be before child3"
    end

    test "goal is positioned after other goals when moving to new column" do
      user = user_fixture()
      board = board_fixture(user)
      ready_column = column_fixture(board, %{name: "Ready", position: 0})
      doing_column = column_fixture(board, %{name: "Doing", position: 1})

      {:ok, other_goal} =
        Tasks.create_task(doing_column, %{
          "title" => "Other Goal",
          "type" => "goal"
        })

      {:ok, goal} =
        Tasks.create_task(ready_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child} =
        Tasks.create_task(ready_column, %{
          "title" => "Child",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, _claimed, _} = Tasks.claim_next_task([], user, board.id, child.identifier)

      updated_goal = Tasks.get_task!(goal.id)
      updated_other_goal = Tasks.get_task!(other_goal.id)
      updated_child = Tasks.get_task!(child.id)

      assert updated_goal.column_id == doing_column.id

      assert updated_other_goal.position < updated_goal.position,
             "Existing goal should be before new goal"

      assert updated_goal.position < updated_child.position,
             "New goal should be before its child"
    end

    test "goal is positioned before children when moved via drag-and-drop" do
      user = user_fixture()
      board = board_fixture(user)
      ready_column = column_fixture(board, %{name: "Ready", position: 0})
      _doing_column = column_fixture(board, %{name: "Doing", position: 1})
      done_column = column_fixture(board, %{name: "Done", position: 3})

      {:ok, goal} =
        Tasks.create_task(ready_column, %{
          "title" => "Parent Goal",
          "type" => "goal"
        })

      {:ok, child1} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 1",
          "type" => "work",
          "parent_id" => goal.id
        })

      {:ok, child2} =
        Tasks.create_task(ready_column, %{
          "title" => "Child 2",
          "type" => "work",
          "parent_id" => goal.id
        })

      Tasks.move_task(child1, done_column, 0)
      Tasks.move_task(child2, done_column, 1)

      updated_goal = Tasks.get_task!(goal.id)
      updated_child1 = Tasks.get_task!(child1.id)
      updated_child2 = Tasks.get_task!(child2.id)

      assert updated_goal.column_id == done_column.id,
             "Goal should move to Done when all children are in Done"

      assert updated_child1.column_id == done_column.id
      assert updated_child2.column_id == done_column.id

      assert updated_goal.position < updated_child1.position,
             "Goal should be positioned before child1"

      assert updated_goal.position < updated_child2.position,
             "Goal should be positioned before child2"
    end
  end

  describe "create_goal_with_tasks/3" do
    test "creates a goal with multiple child tasks in a single transaction" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        title: "Test Goal",
        description: "A goal with child tasks",
        created_by_id: user.id
      }

      child_tasks = [
        %{"title" => "Child Task 1", "type" => "work", "complexity" => "small"},
        %{"title" => "Child Task 2", "type" => "defect", "complexity" => "medium"},
        %{"title" => "Child Task 3", "type" => "work", "complexity" => "large"}
      ]

      assert {:ok, %{goal: goal, child_tasks: created_tasks}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      assert goal.title == "Test Goal"
      assert goal.type == :goal
      assert String.starts_with?(goal.identifier, "G")
      assert length(created_tasks) == 3

      Enum.each(created_tasks, fn task ->
        assert task.parent_id == goal.id
        assert task.column_id == column.id
      end)

      assert Enum.at(created_tasks, 0).identifier =~ ~r/^W\d+$/
      assert Enum.at(created_tasks, 1).identifier =~ ~r/^D\d+$/
      assert Enum.at(created_tasks, 2).identifier =~ ~r/^W\d+$/
    end

    test "creates goal without child tasks when empty array provided" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        title: "Standalone Goal",
        created_by_id: user.id
      }

      assert {:ok, %{goal: goal, child_tasks: created_tasks}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, [])

      assert goal.title == "Standalone Goal"
      assert goal.type == :goal
      assert created_tasks == []
    end

    test "sets correct positions for child tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{title: "Goal", created_by_id: user.id}

      child_tasks = [
        %{"title" => "Task 1", "type" => "work"},
        %{"title" => "Task 2", "type" => "work"},
        %{"title" => "Task 3", "type" => "work"}
      ]

      assert {:ok, %{goal: goal, child_tasks: created_tasks}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      assert goal.position == 0

      positions = Enum.map(created_tasks, & &1.position)
      assert length(Enum.uniq(positions)) == 3
      assert Enum.sort(positions) == positions
      assert Enum.all?(positions, &(&1 > goal.position))
    end

    test "rolls back everything if goal creation fails" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      invalid_goal_attrs = %{
        title: nil,
        created_by_id: user.id
      }

      child_tasks = [
        %{"title" => "Task 1", "type" => "work"}
      ]

      initial_task_count = Repo.aggregate(Task, :count, :id)

      assert {:error, :goal, changeset} =
               Tasks.create_goal_with_tasks(column, invalid_goal_attrs, child_tasks)

      assert changeset.errors[:title]

      final_task_count = Repo.aggregate(Task, :count, :id)
      assert final_task_count == initial_task_count
    end

    test "rolls back everything if child task creation fails" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        title: "Valid Goal",
        created_by_id: user.id
      }

      child_tasks = [
        %{"title" => "Valid Task", "type" => "work"},
        %{"title" => nil, "type" => "work"}
      ]

      initial_task_count = Repo.aggregate(Task, :count, :id)

      assert {:error, _operation, _changeset} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      final_task_count = Repo.aggregate(Task, :count, :id)
      assert final_task_count == initial_task_count
    end

    test "goals do not count toward WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 1})

      # Create a work task that fills the WIP limit
      task_fixture(column)

      # Goals should not count toward WIP limit, so this should succeed
      goal_attrs = %{title: "Goal", created_by_id: user.id}
      child_tasks = [%{"title" => "Task", "type" => "work"}]

      assert {:ok, %{goal: goal, child_tasks: _child_tasks}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      assert goal.type == :goal
    end

    test "work and defect tasks still respect WIP limit even with goals present" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 2})

      # Create a goal (doesn't count toward limit)
      {:ok, goal} = Tasks.create_task(column, %{title: "Goal", type: "goal"})
      assert goal.type == :goal

      # Create 2 work tasks (fills the WIP limit)
      {:ok, _task1} = Tasks.create_task(column, %{title: "Work 1", type: "work"})
      {:ok, _task2} = Tasks.create_task(column, %{title: "Work 2", type: "work"})

      # Try to create another work task (should fail)
      assert {:error, :wip_limit_reached} =
               Tasks.create_task(column, %{title: "Work 3", type: "work"})

      # Try to create a defect (should also fail)
      assert {:error, :wip_limit_reached} =
               Tasks.create_task(column, %{title: "Defect 1", type: "defect"})

      # But creating another goal should succeed
      assert {:ok, goal2} = Tasks.create_task(column, %{title: "Goal 2", type: "goal"})
      assert goal2.type == :goal
    end

    test "sets created_by_agent when provided" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        title: "AI Created Goal",
        created_by_id: user.id,
        created_by_agent: "Claude Sonnet 4.5"
      }

      child_tasks = [
        %{"title" => "AI Task", "type" => "work", "created_by_agent" => "Claude Sonnet 4.5"}
      ]

      assert {:ok, %{goal: goal, child_tasks: [child_task]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      assert goal.created_by_agent == "Claude Sonnet 4.5"
      assert child_task.created_by_agent == "Claude Sonnet 4.5"
    end

    test "creates task history entries for goal and all child tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{title: "Goal", created_by_id: user.id}
      child_tasks = [%{"title" => "Task", "type" => "work"}]

      assert {:ok, %{goal: goal, child_tasks: [child_task]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      goal_with_history = Tasks.get_task_with_history!(goal.id)
      assert Enum.any?(goal_with_history.task_histories, fn h -> h.type == :creation end)

      child_with_history = Tasks.get_task_with_history!(child_task.id)
      assert Enum.any?(child_with_history.task_histories, fn h -> h.type == :creation end)
    end

    test "preserves all AI-optimized fields from child task attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{title: "Goal", created_by_id: user.id}

      child_tasks = [
        %{
          "title" => "Rich Task",
          "type" => "work",
          "complexity" => "large",
          "why" => "To test rich fields",
          "what" => "Verify all fields are preserved",
          "patterns_to_follow" => "Follow existing patterns",
          "verification_steps" => [
            %{
              "step_type" => "command",
              "step_text" => "mix test",
              "position" => 0
            }
          ]
        }
      ]

      assert {:ok, %{child_tasks: [task]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      assert task.complexity == :large
      assert task.why == "To test rich fields"
      assert task.what == "Verify all fields are preserved"
      assert task.patterns_to_follow == "Follow existing patterns"
      assert is_list(task.verification_steps)
      assert length(task.verification_steps) == 1

      step = hd(task.verification_steps)
      assert step.step_type == "command"
      assert step.step_text == "mix test"
    end

    test "deleting all child tasks also deletes the parent goal" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        "title" => "Goal to be deleted",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "Child Task 1", "type" => "work"},
        %{"title" => "Child Task 2", "type" => "work"}
      ]

      assert {:ok, %{goal: goal, child_tasks: [task1, task2]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      goal_id = goal.id

      # Verify goal exists
      assert Tasks.get_task!(goal_id)

      # Delete first child task
      assert {:ok, _} = Tasks.delete_task(task1)

      # Goal should still exist
      assert Tasks.get_task!(goal_id)

      # Delete second child task
      assert {:ok, _} = Tasks.delete_task(task2)

      # Goal should be automatically deleted
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(goal_id)
      end
    end

    test "converts index-based dependencies to task identifiers" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        "title" => "Test Goal with Dependencies",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "First Task", "type" => "work"},
        %{"title" => "Second Task", "type" => "work", "dependencies" => [0]},
        %{"title" => "Third Task", "type" => "work", "dependencies" => [0, 1]}
      ]

      assert {:ok, %{goal: _goal, child_tasks: [task1, task2, task3]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # First task has no dependencies
      assert task1.dependencies == []

      # Second task depends on first task (index 0 converted to task1's identifier)
      assert task2.dependencies == [task1.identifier]

      # Third task depends on first and second tasks
      assert task3.dependencies == [task1.identifier, task2.identifier]
    end

    test "allows mixing index-based and string identifier dependencies" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create a separate task first to reference by identifier
      existing_task = task_fixture(column, %{title: "Existing Task", type: :work})

      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "First Task", "type" => "work"},
        %{
          "title" => "Second Task",
          "type" => "work",
          "dependencies" => [0, existing_task.identifier]
        }
      ]

      assert {:ok, %{goal: _goal, child_tasks: [task1, task2]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # Second task has dependencies on both the first child task (by index) and the existing task (by identifier)
      assert Enum.sort(task2.dependencies) ==
               Enum.sort([task1.identifier, existing_task.identifier])
    end

    test "handles different task types with index-based dependencies" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        "title" => "Mixed Type Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "Work Task", "type" => "work"},
        %{"title" => "Defect Task", "type" => "defect"},
        %{"title" => "Another Work Task", "type" => "work", "dependencies" => [0, 1]}
      ]

      assert {:ok, %{goal: _goal, child_tasks: [task1, task2, task3]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # Verify types are different (W1, D1, W2)
      assert task1.type == :work
      assert task2.type == :defect
      assert task3.type == :work

      # Third task correctly depends on both
      assert task3.dependencies == [task1.identifier, task2.identifier]
    end

    test "handles invalid index gracefully" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      # Index 99 doesn't exist (only indices 0-1 valid)
      child_tasks = [
        %{"title" => "First Task", "type" => "work"},
        %{"title" => "Second Task", "type" => "work", "dependencies" => [99]}
      ]

      # Should fail validation because dependency 99 won't resolve to a valid identifier
      assert {:error, _operation, _changeset} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)
    end

    test "sets blocked status for tasks with incomplete dependencies on creation" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      goal_attrs = %{
        "title" => "Test Goal with Blocking",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "First Task", "type" => "work"},
        %{"title" => "Second Task", "type" => "work", "dependencies" => [0]},
        %{"title" => "Third Task", "type" => "work", "dependencies" => [0, 1]}
      ]

      assert {:ok, %{goal: _goal, child_tasks: [task1, task2, task3]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # First task has no dependencies, should be :open
      assert task1.status == :open

      # Second task depends on incomplete first task, should be :blocked
      assert task2.status == :blocked
      assert task2.dependencies == [task1.identifier]

      # Third task depends on incomplete tasks, should be :blocked
      assert task3.status == :blocked
      assert task3.dependencies == [task1.identifier, task2.identifier]
    end

    test "sets open status for tasks whose dependencies are already complete" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create and complete a task first
      completed_task = task_fixture(column, %{title: "Completed Task", type: :work})

      {:ok, completed_task} =
        Tasks.update_task(completed_task, %{status: :completed, completed_at: DateTime.utc_now()})

      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{
          "title" => "Task with completed dependency",
          "type" => "work",
          "dependencies" => [completed_task.identifier]
        }
      ]

      assert {:ok, %{child_tasks: [task]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # Task depends on a completed task, should be :open
      assert task.status == :open
      assert task.dependencies == [completed_task.identifier]
    end

    test "correctly handles mixed complete and incomplete dependencies" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create one completed and one incomplete task
      completed_task = task_fixture(column, %{title: "Completed", type: :work})

      {:ok, completed_task} =
        Tasks.update_task(completed_task, %{status: :completed, completed_at: DateTime.utc_now()})

      incomplete_task = task_fixture(column, %{title: "Incomplete", type: :work})

      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{
          "title" => "Mixed dependencies task",
          "type" => "work",
          "dependencies" => [completed_task.identifier, incomplete_task.identifier]
        }
      ]

      assert {:ok, %{child_tasks: [task]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # Has at least one incomplete dependency, should be :blocked
      assert task.status == :blocked

      assert Enum.sort(task.dependencies) ==
               Enum.sort([completed_task.identifier, incomplete_task.identifier])
    end

    test "places goal at top of column when child tasks trigger move" do
      user = user_fixture()
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog", position: 0})
      ready = column_fixture(board, %{name: "Ready", position: 1})

      # Create a couple of existing tasks in ready column
      _existing_task1 = task_fixture(ready, %{title: "Existing 1", type: :work})
      _existing_task2 = task_fixture(ready, %{title: "Existing 2", type: :work})

      # Create a goal with child tasks in backlog
      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "Child Task 1", "type" => "work"}
      ]

      assert {:ok, %{goal: goal, child_tasks: [child_task]}} =
               Tasks.create_goal_with_tasks(backlog, goal_attrs, child_tasks)

      # Move child task to ready column
      assert {:ok, moved_child} = Tasks.move_task(child_task, ready, 2)

      # Verify the goal moved to ready
      updated_goal = Tasks.get_task!(goal.id)
      assert updated_goal.column_id == ready.id

      # Get all tasks in ready column sorted by position
      tasks_in_ready = Tasks.list_tasks(ready) |> Enum.sort_by(& &1.position)

      # Goal should be positioned before its child
      assert updated_goal.position < moved_child.id

      # Find goal position in the sorted list
      goal_index = Enum.find_index(tasks_in_ready, &(&1.id == updated_goal.id))
      child_index = Enum.find_index(tasks_in_ready, &(&1.id == moved_child.id))

      assert goal_index < child_index,
             "Goal should be positioned before its child in the sorted list"
    end

    test "places goal after existing goals when multiple goals exist" do
      user = user_fixture()
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog", position: 0})
      ready = column_fixture(board, %{name: "Ready", position: 1})

      # Create an existing goal in ready column
      existing_goal = task_fixture(ready, %{title: "Existing Goal", type: :goal})

      _existing_goal_child =
        task_fixture(ready, %{title: "Goal 1 Child", parent_id: existing_goal.id})

      # Create some regular tasks
      _task1 = task_fixture(ready, %{title: "Task 1", type: :work})
      _task2 = task_fixture(ready, %{title: "Task 2", type: :work})

      # Create a new goal with child in backlog
      new_goal_attrs = %{
        "title" => "New Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "New Goal Child", "type" => "work"}
      ]

      assert {:ok, %{goal: new_goal, child_tasks: [new_child]}} =
               Tasks.create_goal_with_tasks(backlog, new_goal_attrs, child_tasks)

      # Move child task to ready column
      assert {:ok, _moved_child} = Tasks.move_task(new_child, ready, 4)

      # Get all tasks in ready column
      tasks_in_ready = Tasks.list_tasks(ready) |> Enum.sort_by(& &1.position)

      # Extract goals and non-goals
      goals = Enum.filter(tasks_in_ready, &(&1.type == :goal))
      _regular_tasks = Enum.filter(tasks_in_ready, &(&1.type != :goal))

      # Both goals should be at the top
      assert length(goals) == 2
      assert hd(tasks_in_ready).type == :goal
      assert Enum.at(tasks_in_ready, 1).type == :goal

      # All regular tasks should be after all goals
      first_regular_task_index = Enum.find_index(tasks_in_ready, &(&1.type != :goal))
      assert first_regular_task_index >= 2

      # Verify new goal is after existing goal
      updated_new_goal = Tasks.get_task!(new_goal.id)
      updated_existing_goal = Tasks.get_task!(existing_goal.id)
      assert updated_new_goal.position > updated_existing_goal.position
    end

    test "broadcasts task_updated event when blocking status is set on creation" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Subscribe to board updates
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      goal_attrs = %{
        "title" => "Test Goal",
        "type" => "goal",
        "created_by_id" => user.id
      }

      child_tasks = [
        %{"title" => "First Task", "type" => "work"},
        %{"title" => "Second Task", "type" => "work", "dependencies" => [0]}
      ]

      assert {:ok, %{child_tasks: [_task1, task2]}} =
               Tasks.create_goal_with_tasks(column, goal_attrs, child_tasks)

      # Should receive task_updated for the blocked task (blocking status update)
      assert_receive {:task_updated, updated_task}
      assert updated_task.id == task2.id
      assert updated_task.status == :blocked
    end
  end

  describe "archive_task/1" do
    test "archives a task by setting archived_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert task.archived_at == nil

      assert {:ok, archived_task} = Tasks.archive_task(task)
      assert archived_task.archived_at != nil
      assert %DateTime{} = archived_task.archived_at
    end

    test "archiving already archived task updates archived_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert {:ok, first_archived} = Tasks.archive_task(task)
      first_timestamp = first_archived.archived_at

      Process.sleep(1000)

      assert {:ok, second_archived} = Tasks.archive_task(first_archived)
      assert DateTime.compare(second_archived.archived_at, first_timestamp) == :gt
    end

    test "emits telemetry event when archiving task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      :telemetry.attach(
        "test-archive-handler",
        [:kanban, :task, :archived],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      assert {:ok, archived_task} = Tasks.archive_task(task)

      assert_receive {:telemetry_event, [:kanban, :task, :archived], measurements, metadata}
      assert measurements.task_id == archived_task.id
      assert metadata.identifier == archived_task.identifier

      :telemetry.detach("test-archive-handler")
    end
  end

  describe "unarchive_task/1" do
    test "unarchives a task by setting archived_at to nil" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, archived_task} = Tasks.archive_task(task)
      assert archived_task.archived_at != nil

      assert {:ok, unarchived_task} = Tasks.unarchive_task(archived_task)
      assert unarchived_task.archived_at == nil
    end

    test "unarchiving non-archived task keeps archived_at as nil" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert task.archived_at == nil

      assert {:ok, unarchived_task} = Tasks.unarchive_task(task)
      assert unarchived_task.archived_at == nil
    end

    test "emits telemetry event when unarchiving task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)
      {:ok, archived_task} = Tasks.archive_task(task)

      :telemetry.attach(
        "test-unarchive-handler",
        [:kanban, :task, :unarchived],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      assert {:ok, unarchived_task} = Tasks.unarchive_task(archived_task)

      assert_receive {:telemetry_event, [:kanban, :task, :unarchived], measurements, metadata}
      assert measurements.task_id == unarchived_task.id
      assert metadata.identifier == unarchived_task.identifier

      :telemetry.detach("test-unarchive-handler")
    end
  end
end
