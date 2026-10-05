defmodule Kanban.Tasks.TaskTypeTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskType

  doctest Kanban.Tasks.TaskType

  describe "from_value/1" do
    test "resolves every Ecto.Enum value from its atom and its string form" do
      for {atom, string} <- Ecto.Enum.mappings(Task, :type) do
        assert TaskType.from_value(atom) == atom
        assert TaskType.from_value(string) == atom
      end
    end

    test "returns :unknown for unrecognised strings without creating an atom" do
      unique = "no_such_type_d352_#{System.unique_integer([:positive])}"

      for value <- [unique, "task", "bug", "Work", "WORK", " work", "work ", ""] do
        assert TaskType.from_value(value) == :unknown
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    end

    test "returns :unknown for nil, numbers, lists, maps and unknown atoms" do
      for value <- [nil, 42, 1.5, ["work"], %{"v" => "work"}, :task, true] do
        assert TaskType.from_value(value) == :unknown
      end
    end
  end

  describe "from_attrs/1" do
    test "reads the atom key, then the string key" do
      assert TaskType.from_attrs(%{type: :defect}) == :defect
      assert TaskType.from_attrs(%{"type" => "goal"}) == :goal
    end

    test "an omitted type is :work, a present nil is :unknown" do
      assert TaskType.from_attrs(%{}) == :work
      assert TaskType.from_attrs(%{"type" => nil}) == :unknown
      assert TaskType.from_attrs(%{type: nil}) == :unknown
    end
  end

  describe "blank_to_nil/1" do
    test "replaces empty and whitespace-only string types with nil under either key" do
      for blank <- ["", " ", "\t\n "] do
        assert TaskType.blank_to_nil(%{"type" => blank, "title" => "t"}) ==
                 %{"type" => nil, "title" => "t"}

        assert TaskType.blank_to_nil(%{type: blank}) == %{type: nil}
      end
    end

    test "leaves non-blank, non-string and missing types untouched" do
      for attrs <- [
            %{"type" => " work"},
            %{"type" => "bug"},
            %{type: :work},
            %{"type" => 42},
            %{}
          ] do
        assert TaskType.blank_to_nil(attrs) == attrs
      end
    end
  end
end
