defmodule Kanban.Tasks.HumanTaskTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  describe "human_task field" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column}
    end

    test "defaults to false when not provided", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Test task"})

      assert task.human_task == false
    end

    test "accepts human_task as true", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Human only task", human_task: true})

      assert task.human_task == true
    end

    test "accepts human_task as false", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Agent task", human_task: false})

      assert task.human_task == false
    end

    test "changeset casts human_task field" do
      changeset = Task.changeset(%Task{}, %{human_task: true})

      assert Ecto.Changeset.get_change(changeset, :human_task) == true
    end

    test "can update human_task from false to true", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Task", human_task: false})

      {:ok, updated} = Tasks.update_task(task, %{human_task: true})

      assert updated.human_task == true
    end

    test "can update human_task from true to false", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Task", human_task: true})

      {:ok, updated} = Tasks.update_task(task, %{human_task: false})

      assert updated.human_task == false
    end
  end
end
