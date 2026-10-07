defmodule Kanban.Columns.StageTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns.Stage
  alias Kanban.Tasks

  defp col(id, name, position), do: %{id: id, name: name, position: position}

  describe "known_stage/1" do
    test "decides the five fixed names, ignoring case and spaces" do
      assert Stage.known_stage("Backlog") == :not_started
      assert Stage.known_stage(" ready ") == :not_started
      assert Stage.known_stage("DOING") == :in_progress
      assert Stage.known_stage("Review") == :in_progress
      assert Stage.known_stage("done") == :done
    end

    test "returns nil for a custom name or a non-string" do
      assert Stage.known_stage("To Do") == nil
      assert Stage.known_stage(nil) == nil
    end
  end

  describe "classify/1" do
    test "a custom column before the first Doing column has not started" do
      stages = Stage.classify([col(1, "To Do", 0), col(2, "Doing", 1), col(3, "Done", 2)])
      assert stages == %{1 => :not_started, 2 => :in_progress, 3 => :done}
    end

    test "custom columns after the first in-progress column are in progress" do
      stages =
        Stage.classify([
          col(1, "Backlog", 0),
          col(2, "Refinement", 1),
          col(3, "Review", 2),
          col(4, "QA", 3),
          col(5, "Done", 4)
        ])

      assert stages[2] == :not_started
      assert stages[4] == :in_progress
    end

    test "with no Doing or Review column only the first column has not started" do
      stages =
        Stage.classify([col(1, "Icebox", 0), col(2, "Working", 1), col(3, "Shipped", 2)])

      assert stages == %{1 => :not_started, 2 => :in_progress, 3 => :in_progress}
    end

    test "orders by position, not by list order" do
      stages = Stage.classify([col(3, "Doing", 5), col(1, "Inbox", 2), col(2, "Later", 9)])
      assert stages == %{1 => :not_started, 2 => :in_progress, 3 => :in_progress}
    end

    test "an empty board classifies nothing" do
      assert Stage.classify([]) == %{}
    end
  end

  describe "with a real board" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      todo = column_fixture(board, %{name: "To Do"})
      doing = column_fixture(board, %{name: "Doing"})
      done = column_fixture(board, %{name: "Done"})
      %{board: board, todo: todo, doing: doing, done: done}
    end

    test "for_column/1 and not_started_column_ids/1 read the board's columns", ctx do
      assert Stage.for_column(ctx.todo) == :not_started
      assert Stage.for_column(ctx.doing) == :in_progress
      assert Stage.for_column(ctx.done) == :done
      assert Stage.not_started_column_ids(ctx.board.id) == [ctx.todo.id]
    end

    test "moving a task back into a custom To Do column makes it open again", ctx do
      task = task_fixture(ctx.todo)

      {:ok, moved} = Tasks.move_task(task, ctx.doing, 0)
      assert Tasks.get_task!(moved.id).status == :in_progress

      {:ok, back} = task.id |> Tasks.get_task!() |> Tasks.move_task(ctx.todo, 0)
      assert Tasks.get_task!(back.id).status == :open
    end
  end
end
