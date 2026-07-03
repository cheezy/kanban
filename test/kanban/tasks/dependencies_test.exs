defmodule Kanban.Tasks.DependenciesTest do
  @moduledoc """
  Direct unit tests for the dependency logic module (W1448): multi-hop circular
  detection, blocking-status recomputation, and the dependency/dependent trees.
  Dependency *format* and *self-reference* validation live in Kanban.Tasks.Task's
  changeset, not here, and are covered by the task-schema tests.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  defp set_deps(task, deps),
    do: task |> Ecto.Changeset.change(%{dependencies: deps}) |> Repo.update!()

  defp set_status(task, status),
    do: task |> Ecto.Changeset.change(%{status: status}) |> Repo.update!()

  describe "validate_circular_dependencies/1" do
    test "flags a multi-hop cycle (A -> B -> A)", %{column: column} do
      task_a = task_fixture(column)
      task_b = task_fixture(column)
      # Persist B depends on A (no cycle yet), then try to make A depend on B.
      set_deps(task_b, [task_a.identifier])

      changeset =
        task_a
        |> Task.changeset(%{dependencies: [task_b.identifier]})
        |> Dependencies.validate_circular_dependencies()

      assert "creates a circular dependency" in errors_on(changeset).dependencies
    end

    test "allows a non-cyclic dependency", %{column: column} do
      task_a = task_fixture(column)
      task_b = task_fixture(column)

      changeset =
        task_b
        |> Task.changeset(%{dependencies: [task_a.identifier]})
        |> Dependencies.validate_circular_dependencies()

      errors = errors_on(changeset)
      refute Map.has_key?(errors, :dependencies)
    end

    test "skips the check when :dependencies is not in the changeset changes", %{column: column} do
      task_a = task_fixture(column)

      changeset =
        task_a
        |> Task.changeset(%{title: "A renamed title"})
        |> Dependencies.validate_circular_dependencies()

      errors = errors_on(changeset)
      refute Map.has_key?(errors, :dependencies)
    end

    test "skips the check when dependencies are explicitly cleared to []", %{column: column} do
      task_a = task_fixture(column)
      task_b = task_fixture(column)
      set_deps(task_b, [task_a.identifier])

      changeset =
        task_b
        |> Task.changeset(%{dependencies: []})
        |> Dependencies.validate_circular_dependencies()

      errors = errors_on(changeset)
      refute Map.has_key?(errors, :dependencies)
    end

    test "does not run the DB cycle check for an unpersisted task (no id)" do
      changeset =
        %Task{}
        |> Task.changeset(%{dependencies: ["W999"]})
        |> Dependencies.validate_circular_dependencies()

      errors = errors_on(changeset)
      refute Map.has_key?(errors, :dependencies)
    end
  end

  describe "update_task_blocking_status/1" do
    test "leaves a task with no dependencies unchanged", %{column: column} do
      task = task_fixture(column)
      assert {:ok, result} = Dependencies.update_task_blocking_status(task)
      assert result.status == task.status
    end

    test "marks a task :blocked when a dependency is incomplete", %{column: column} do
      dep = task_fixture(column)
      main = set_deps(task_fixture(column), [dep.identifier])

      assert {:ok, updated} = Dependencies.update_task_blocking_status(main)
      assert updated.status == :blocked
    end

    test "marks a blocked task :open once every dependency is completed", %{column: column} do
      dep = set_status(task_fixture(column), :completed)

      main =
        task_fixture(column)
        |> set_deps([dep.identifier])
        |> set_status(:blocked)

      assert {:ok, updated} = Dependencies.update_task_blocking_status(main)
      assert updated.status == :open
    end
  end

  describe "get_dependency_tree/1 and get_dependent_tasks/1" do
    test "a task with no dependencies has an empty dependency tree", %{column: column} do
      task = task_fixture(column)
      assert %{task: _, dependencies: []} = Dependencies.get_dependency_tree(task)
    end

    test "get_dependent_tasks returns tasks that depend on the given task", %{column: column} do
      dep = task_fixture(column)
      dependent = set_deps(task_fixture(column), [dep.identifier])

      result = Dependencies.get_dependent_tasks(dep)

      assert Enum.any?(result, &(&1.id == dependent.id))
    end
  end

  describe "unblock_dependent_tasks/2" do
    test "returns :ok even when nothing depends on the identifier", %{board: board} do
      assert Dependencies.unblock_dependent_tasks("W-nonexistent", board.id) == :ok
    end
  end
end
