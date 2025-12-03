defmodule Kanban.Tasks.TaskHistoryTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.TaskHistory

  describe "changeset/2" do
    test "valid changeset for creation type" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :creation
        })

      assert changeset.valid?
      assert get_change(changeset, :type) == :creation
      assert get_change(changeset, :task_id) == task.id
    end

    test "valid changeset for move type with column names" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :move,
          from_column: "To Do",
          to_column: "In Progress"
        })

      assert changeset.valid?
      assert get_change(changeset, :type) == :move
      assert get_change(changeset, :from_column) == "To Do"
      assert get_change(changeset, :to_column) == "In Progress"
    end

    test "invalid when task_id is missing" do
      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          type: :creation
        })

      refute changeset.valid?
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when type is missing" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id
        })

      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when type is not :creation or :move" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :invalid_type
        })

      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid when move type is missing from_column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :move,
          to_column: "In Progress"
        })

      refute changeset.valid?
      assert %{from_column: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when move type is missing to_column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :move,
          from_column: "To Do"
        })

      refute changeset.valid?
      assert %{to_column: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when creation type has from_column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :creation,
          from_column: "To Do"
        })

      refute changeset.valid?

      assert %{type: ["creation events should not have any history fields"]} =
               errors_on(changeset)
    end

    test "invalid when creation type has to_column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :creation,
          to_column: "In Progress"
        })

      refute changeset.valid?

      assert %{type: ["creation events should not have any history fields"]} =
               errors_on(changeset)
    end

    test "invalid when creation type has both from_column and to_column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :creation,
          from_column: "To Do",
          to_column: "In Progress"
        })

      refute changeset.valid?

      assert %{type: ["creation events should not have any history fields"]} =
               errors_on(changeset)
    end

    test "valid priority_change type with required fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :priority_change,
          from_priority: "medium",
          to_priority: "high"
        })

      assert changeset.valid?
    end

    test "invalid when priority_change type missing from_priority" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :priority_change,
          to_priority: "high"
        })

      refute changeset.valid?
      assert %{from_priority: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when priority_change type missing to_priority" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :priority_change,
          from_priority: "medium"
        })

      refute changeset.valid?
      assert %{to_priority: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when priority_change type has column fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :priority_change,
          from_priority: "medium",
          to_priority: "high",
          from_column: "To Do"
        })

      refute changeset.valid?
      assert %{type: ["priority_change events should not have column fields"]} = errors_on(changeset)
    end

    test "invalid when move type has priority fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :move,
          from_column: "To Do",
          to_column: "In Progress",
          from_priority: "medium"
        })

      refute changeset.valid?
      assert %{type: ["move events should not have priority fields"]} = errors_on(changeset)
    end
  end

  describe "database constraints" do
    test "enforces foreign key constraint on task_id" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        %TaskHistory{}
        |> TaskHistory.changeset(%{
          task_id: 999_999,
          type: :creation
        })
        |> Repo.insert!()
      end
    end

    test "cascades delete when task is deleted" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      # Create a history record
      history =
        %TaskHistory{}
        |> TaskHistory.changeset(%{
          task_id: task.id,
          type: :creation
        })
        |> Repo.insert!()

      # Delete the task
      Repo.delete!(task)

      # History should be deleted
      refute Repo.get(TaskHistory, history.id)
    end
  end

  describe "timestamps" do
    test "sets inserted_at on creation" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      history =
        %TaskHistory{}
        |> TaskHistory.changeset(%{
          task_id: task.id,
          type: :creation
        })
        |> Repo.insert!()

      assert history.inserted_at
      # TaskHistory should not have updated_at
      refute Map.has_key?(history, :updated_at)
    end
  end

  describe "string type values" do
    test "accepts string 'creation' for type" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: "creation"
        })

      assert changeset.valid?
    end

    test "accepts string 'move' for type" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: "move",
          from_column: "To Do",
          to_column: "Done"
        })

      assert changeset.valid?
    end

    test "rejects invalid string for type" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      changeset =
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: "invalid"
        })

      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end
  end
end
