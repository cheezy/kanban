defmodule KanbanWeb.TaskLive.Form.OptionBuildersTest do
  use ExUnit.Case, async: true

  alias Kanban.Labels.Label
  alias KanbanWeb.TaskLive.Form.OptionBuilders

  describe "build_label_options/1 (W2234)" do
    test "maps each label to an id/name/color option, keeping order" do
      labels = [
        %Label{id: 2, name: "Backend", color: :red, board_id: 1},
        %Label{id: 1, name: "Frontend", color: :blue, board_id: 1}
      ]

      assert OptionBuilders.build_label_options(labels) == [
               %{id: 2, name: "Backend", color: :red},
               %{id: 1, name: "Frontend", color: :blue}
             ]
    end

    test "returns [] for a board with no labels" do
      assert OptionBuilders.build_label_options([]) == []
    end
  end
end
