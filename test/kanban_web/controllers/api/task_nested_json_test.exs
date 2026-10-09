defmodule KanbanWeb.API.TaskNestedJSONTest do
  use ExUnit.Case, async: true

  alias Kanban.Labels.Label
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.TaskNestedJSON

  describe "labels/1" do
    test "renders name and color only, ordered by name ignoring case then id" do
      task = %Task{
        labels: [
          %Label{id: 3, name: "beta", color: :blue, board_id: 9},
          %Label{id: 2, name: "Alpha", color: :red, board_id: 9},
          %Label{id: 1, name: "BETA", color: :green, board_id: 9}
        ]
      }

      assert TaskNestedJSON.labels(task) == [
               %{name: "Alpha", color: :red},
               %{name: "BETA", color: :green},
               %{name: "beta", color: :blue}
             ]
    end

    test "renders [] for an unloaded association or anything that is not a task" do
      assert TaskNestedJSON.labels(%Task{}) == []
      assert TaskNestedJSON.labels(nil) == []
    end
  end

  describe "the moved nested renderers" do
    test "render [] for a nil collection" do
      task = %Task{key_files: nil, verification_steps: nil, behaviour_test_matrix: nil}

      assert TaskNestedJSON.key_files(task) == []
      assert TaskNestedJSON.verification_steps(task) == []
      assert TaskNestedJSON.behaviour_test_matrix(task) == []
    end
  end
end
