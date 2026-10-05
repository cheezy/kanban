defmodule Kanban.Tasks.Task.HierarchyValidationsTest do
  @moduledoc """
  Unit tests for the two-level hierarchy rule (D354): a goal never has a parent.
  The create and update paths that call it are covered in creation_test.exs and
  the API controller tests.
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [cast: 3, change: 2]

  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.HierarchyValidations

  doctest HierarchyValidations

  @message HierarchyValidations.nested_goal_message()

  defp validate(task, attrs) do
    task
    |> cast(attrs, [:type, :parent_id, :title])
    |> HierarchyValidations.validate_goal_has_no_parent()
  end

  describe "validate_goal_has_no_parent/1" do
    test "a goal cannot have a parent: a new goal with a parent is rejected" do
      changeset = validate(%Task{}, %{type: :goal, parent_id: 7})

      assert changeset.errors[:type] == {@message, []}
    end

    test "rejects giving an existing goal a parent" do
      changeset = validate(%Task{type: :goal}, %{parent_id: 7})

      assert changeset.errors[:type] == {@message, []}
    end

    test "rejects turning a child task into a goal" do
      changeset = validate(%Task{type: :work, parent_id: 7}, %{type: :goal})

      assert changeset.errors[:type] == {@message, []}
    end

    test "allows a goal with no parent and children of work or defect type" do
      for {task, attrs} <- [
            {%Task{}, %{type: :goal}},
            {%Task{}, %{type: :work, parent_id: 7}},
            {%Task{}, %{type: :defect, parent_id: 7}},
            {%Task{type: :goal, parent_id: 7}, %{type: :work}},
            {%Task{type: :goal}, %{parent_id: nil}}
          ] do
        assert validate(task, attrs).errors == [], "rejected #{inspect(attrs)}"
      end
    end

    test "leaves an existing nested goal editable when neither type nor parent changes" do
      changeset = validate(%Task{type: :goal, parent_id: 7}, %{title: "renamed"})

      assert changeset.errors == []
    end

    test "the message is translated in every locale the task form renders it in" do
      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            KanbanWeb.CoreComponents.translate_error({@message, []})
          end)

        assert translated != @message, "no #{locale} translation"
        assert translated =~ "'work'"
      end
    end

    test "fires on a changed parent even when the type is unchanged" do
      changeset =
        %Task{type: :goal, parent_id: 7}
        |> change(parent_id: 8)
        |> HierarchyValidations.validate_goal_has_no_parent()

      assert changeset.errors[:type] == {@message, []}
    end
  end

  describe "child_task_error/1" do
    test "accepts work and defect children, including an empty tasks list" do
      assert HierarchyValidations.child_task_error([
               %{"type" => "work"},
               %{type: :defect},
               %{"title" => "no type"},
               %{"type" => "work", "tasks" => []},
               %{tasks: nil}
             ]) == nil

      assert HierarchyValidations.child_task_error([]) == nil
    end

    test "names the first child of type goal, as a string or an atom" do
      message = HierarchyValidations.nested_goal_message()

      assert HierarchyValidations.child_task_error([%{"type" => "goal"}]) == {0, :type, message}

      assert HierarchyValidations.child_task_error([%{}, %{type: :goal}, %{"type" => "goal"}]) ==
               {1, :type, message}
    end

    test "names a child that carries tasks of its own" do
      message = HierarchyValidations.nested_tasks_message()

      assert HierarchyValidations.child_task_error([%{"tasks" => [%{"title" => "x"}]}]) ==
               {0, :tasks, message}

      assert HierarchyValidations.child_task_error([%{}, %{tasks: [%{}]}]) == {1, :tasks, message}
    end

    test "ignores entries that are not maps and input that is not a list" do
      assert HierarchyValidations.child_task_error(["goal", nil, 3]) == nil
      assert HierarchyValidations.child_task_error(%{"type" => "goal"}) == nil
    end
  end
end
