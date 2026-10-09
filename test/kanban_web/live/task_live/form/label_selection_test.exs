defmodule KanbanWeb.TaskLive.Form.LabelSelectionTest do
  @moduledoc """
  Unit tests for the task form's label selection helper (W2234): parsing the
  posted ids, resolving them against the offered labels, and writing them
  for a saved task — including a label deleted while the form was open.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Labels
  alias KanbanWeb.TaskLive.Form.LabelSelection

  doctest LabelSelection, import: true

  describe "parse_ids/1" do
    test "drops the sentinel, keeps order and collapses duplicates" do
      assert LabelSelection.parse_ids(["", "7", "3", "7"]) == {:ok, [7, 3]}
      assert LabelSelection.parse_ids([""]) == {:ok, []}
      assert LabelSelection.parse_ids([]) == {:ok, []}
    end

    test "rejects anything that is not a whole positive integer" do
      assert LabelSelection.parse_ids(["3", "3abc"]) == :error
      assert LabelSelection.parse_ids(["-1"]) == :error
      assert LabelSelection.parse_ids(["0"]) == :error
      assert LabelSelection.parse_ids([%{"id" => "1"}]) == :error
      assert LabelSelection.parse_ids("3") == :error
    end
  end

  describe "pop/3" do
    test "no label_ids key is :unchanged and leaves the params alone" do
      assert LabelSelection.pop(%{"title" => "T"}, [1, 2], [1]) == {:unchanged, %{"title" => "T"}}
    end

    test "a new selection of offered ids is a :set, with label_ids removed" do
      assert LabelSelection.pop(%{"title" => "T", "label_ids" => ["", "2", "1"]}, [1, 2], []) ==
               {{:set, [2, 1]}, %{"title" => "T"}}
    end

    test "the sentinel alone clears a task's labels" do
      assert LabelSelection.pop(%{"label_ids" => [""]}, [1, 2], [1]) == {{:set, []}, %{}}
    end

    test "a selection equal to the labels the form opened with is :unchanged" do
      assert LabelSelection.pop(%{"label_ids" => ["", "2", "1"]}, [1, 2], [1, 2]) ==
               {:unchanged, %{}}
    end

    test "an id the picker never offered is :invalid" do
      assert LabelSelection.pop(%{"label_ids" => ["", "1", "99"]}, [1, 2], []) == {:invalid, %{}}
    end

    test "a malformed id is :invalid" do
      assert LabelSelection.pop(%{"label_ids" => ["1 OR 1=1"]}, [1], []) == {:invalid, %{}}
    end
  end

  describe "write/4" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      scope = Scope.for_user(user)

      %{
        scope: scope,
        board: board,
        task: task_fixture(column),
        a: label_fixture(board, %{name: "A"}),
        b: label_fixture(board, %{name: "B"})
      }
    end

    test ":unchanged writes nothing and keeps the task's labels", ctx do
      {:ok, _} = Labels.set_task_labels(ctx.scope, ctx.task, [ctx.a.id])

      assert LabelSelection.write(ctx.scope, ctx.board, ctx.task, :unchanged) == :ok
      assert Labels.list_task_label_ids(ctx.scope, ctx.task) == [ctx.a.id]
    end

    test "{:set, ids} writes the labels", ctx do
      assert LabelSelection.write(ctx.scope, ctx.board, ctx.task, {:set, [ctx.a.id, ctx.b.id]}) ==
               :ok

      assert Labels.list_task_label_ids(ctx.scope, ctx.task) == Enum.sort([ctx.a.id, ctx.b.id])
    end

    test "a label deleted since the form opened is dropped and reported", ctx do
      {:ok, _} = Labels.delete_label(ctx.scope, ctx.b)

      assert {:error, message} =
               LabelSelection.write(ctx.scope, ctx.board, ctx.task, {:set, [ctx.a.id, ctx.b.id]})

      assert message =~ "deleted"
      assert Labels.list_task_label_ids(ctx.scope, ctx.task) == [ctx.a.id]
    end

    test "a scope that cannot modify the board reports a failed write", ctx do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.scope.user)

      reader_scope = Scope.for_user(reader)

      assert {:error, message} =
               LabelSelection.write(reader_scope, ctx.board, ctx.task, {:set, [ctx.a.id]})

      assert message =~ "could not be updated"
      assert Labels.list_task_label_ids(ctx.scope, ctx.task) == []
    end
  end
end
