defmodule KanbanWeb.API.TaskLabelsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.LabelsFixtures

  alias Kanban.Accounts.Scope
  alias KanbanWeb.API.TaskLabels

  @shape_error "must be an array of label names, each 1 to 40 characters"

  setup do
    user = user_fixture()
    board = board_fixture(user)
    bug = label_fixture(board, %{name: "Bug"})
    %{scope: Scope.for_user(user), board: board, bug: bug}
  end

  describe "validate_names/1" do
    test "accepts a list of 1 to 40 character names, including an empty list" do
      assert TaskLabels.validate_names([]) == {:ok, []}
      assert TaskLabels.validate_names(["Bug", " docs "]) == {:ok, ["Bug", " docs "]}
      assert TaskLabels.validate_names([String.duplicate("x", 40)]) |> elem(0) == :ok
    end

    test "rejects non-lists, nil, non-string, blank, over-long and invalid UTF-8 names" do
      for bad <- [
            nil,
            "Bug",
            %{"0" => "Bug"},
            [1],
            [nil],
            [""],
            ["  "],
            [String.duplicate("x", 41)],
            [<<255>>]
          ] do
        assert TaskLabels.validate_names(bad) == {:error, @shape_error}, inspect(bad)
      end
    end
  end

  describe "resolve/3" do
    test "returns ids for known names and names the unknown ones", ctx do
      assert TaskLabels.resolve(ctx.scope, ctx.board, ["bug"]) == {:ok, [ctx.bug.id]}

      assert TaskLabels.resolve(ctx.scope, ctx.board, ["Bug", "Nope", ~s(Quo"te)]) ==
               {:error, ~s(unknown labels: "Nope", "Quo\\"te")}

      assert TaskLabels.resolve(ctx.scope, ctx.board, "Bug") == {:error, @shape_error}
    end
  end

  describe "prepare_create/4" do
    test "strips labels from the task and each child and returns the plan", ctx do
      params = %{"title" => "T", "labels" => ["Bug"]}
      children = [%{"title" => "C1", "labels" => []}, %{"title" => "C2"}]

      assert {:ok, %{"title" => "T"}, [%{"title" => "C1"}, %{"title" => "C2"}], plan} =
               TaskLabels.prepare_create(ctx.scope, ctx.board, params, children)

      assert plan == %{task: [ctx.bug.id], children: [[], nil]}
    end

    test "absent labels plan nothing; non-list children pass through", ctx do
      assert {:ok, %{"title" => "T"}, nil, %{task: nil, children: []}} =
               TaskLabels.prepare_create(ctx.scope, ctx.board, %{"title" => "T"}, nil)
    end

    test "collects every label error, prefixing child errors with their index", ctx do
      params = %{"labels" => ["Nope"]}
      children = [%{"labels" => ["Bug"]}, %{"labels" => "Bug"}, %{"labels" => ["Gone"]}]

      assert {:error, changeset} =
               TaskLabels.prepare_create(ctx.scope, ctx.board, params, children)

      assert Kanban.DataCase.errors_on(changeset) == %{
               labels: [
                 ~s(unknown labels: "Nope"),
                 "tasks[1] " <> @shape_error,
                 ~s(tasks[2] unknown labels: "Gone")
               ]
             }
    end
  end

  describe "prepare_batch/3" do
    test "returns stripped goals and children with their plans", ctx do
      goals = [
        %{
          "title" => "G1",
          "labels" => ["Bug"],
          "tasks" => [%{"title" => "C", "labels" => ["bug"]}]
        },
        %{"title" => "G2"}
      ]

      assert {:ok, [{goal_one, plan_one}, {goal_two, plan_two}]} =
               TaskLabels.prepare_batch(ctx.scope, ctx.board, goals)

      assert goal_one == %{"title" => "G1", "tasks" => [%{"title" => "C"}]}
      assert plan_one == %{task: [ctx.bug.id], children: [[ctx.bug.id]]}
      assert goal_two == %{"title" => "G2"}
      assert plan_two == %{task: nil, children: []}
    end

    test "returns the index of the first goal with a label error", ctx do
      goals = [%{"title" => "ok"}, %{"tasks" => [%{"labels" => ["Nope"]}]}, %{"labels" => ["x"]}]

      assert {:error, 1, changeset} = TaskLabels.prepare_batch(ctx.scope, ctx.board, goals)

      assert Kanban.DataCase.errors_on(changeset) == %{
               labels: [~s(tasks[0] unknown labels: "Nope")]
             }
    end

    test "skips a non-list goals value", ctx do
      assert TaskLabels.prepare_batch(ctx.scope, ctx.board, %{"0" => %{}}) == :skip
    end
  end

  describe "apply_plan/3 and apply_children/3" do
    setup %{board: board} do
      column = Kanban.ColumnsFixtures.column_fixture(board)
      %{column: column}
    end

    test "nil does nothing, a list replaces and [] clears", ctx do
      {:ok, task} = Kanban.Tasks.create_task(ctx.column, %{"title" => "Apply"})

      assert TaskLabels.apply_plan(ctx.scope, task, nil) == :ok
      assert Kanban.Labels.list_task_label_ids(ctx.scope, task) == []

      assert TaskLabels.apply_plan(ctx.scope, task, [ctx.bug.id]) == :ok
      assert Kanban.Labels.list_task_label_ids(ctx.scope, task) == [ctx.bug.id]

      assert TaskLabels.apply_plan(ctx.scope, task, []) == :ok
      assert Kanban.Labels.list_task_label_ids(ctx.scope, task) == []
    end

    test "a label deleted after resolution is logged, not raised", ctx do
      {:ok, task} = Kanban.Tasks.create_task(ctx.column, %{"title" => "Deleted label"})
      {:ok, _} = Kanban.Repo.delete(ctx.bug)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert TaskLabels.apply_plan(ctx.scope, task, [ctx.bug.id]) == :ok
        end)

      assert log =~ "API labels not applied"
      assert Kanban.Labels.list_task_label_ids(ctx.scope, task) == []
    end

    test "children are paired with their plans by position", ctx do
      {:ok, first} = Kanban.Tasks.create_task(ctx.column, %{"title" => "First"})
      {:ok, second} = Kanban.Tasks.create_task(ctx.column, %{"title" => "Second"})

      assert TaskLabels.apply_children(ctx.scope, [second, first], [[ctx.bug.id], nil]) == :ok
      assert Kanban.Labels.list_task_label_ids(ctx.scope, first) == [ctx.bug.id]
      assert Kanban.Labels.list_task_label_ids(ctx.scope, second) == []
    end
  end

  describe "validate_filter_name/1" do
    test "trims a valid name and rejects anything else" do
      assert TaskLabels.validate_filter_name(" Bug ") == {:ok, "Bug"}

      for bad <- ["", "  ", String.duplicate("x", 41), ["Bug"], nil, <<255>>],
          do: assert(TaskLabels.validate_filter_name(bad) == :error)
    end
  end
end
