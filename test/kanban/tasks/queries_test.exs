defmodule Kanban.Tasks.QueriesTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Queries

  defp task(attrs) do
    defaults = %{id: nil, identifier: nil, type: :work, parent_id: nil}
    struct!(Kanban.Tasks.Task, Map.merge(defaults, attrs))
  end

  describe "sort_by_goal_hierarchy/1" do
    test "returns empty list unchanged" do
      assert Queries.sort_by_goal_hierarchy([]) == []
    end

    test "standalone tasks come first, sorted by identifier" do
      t1 = task(%{id: 1, identifier: "W3", type: :work})
      t2 = task(%{id: 2, identifier: "W1", type: :work})
      t3 = task(%{id: 3, identifier: "W2", type: :work})

      result = Queries.sort_by_goal_hierarchy([t1, t2, t3])
      assert Enum.map(result, & &1.identifier) == ["W1", "W2", "W3"]
    end

    test "goals appear after standalone tasks with children underneath" do
      standalone = task(%{id: 1, identifier: "W5", type: :work})
      goal = task(%{id: 2, identifier: "G1", type: :goal})
      child1 = task(%{id: 3, identifier: "W2", type: :work, parent_id: 2})
      child2 = task(%{id: 4, identifier: "W1", type: :work, parent_id: 2})

      result = Queries.sort_by_goal_hierarchy([child1, goal, standalone, child2])
      assert Enum.map(result, & &1.identifier) == ["W5", "G1", "W1", "W2"]
    end

    test "multiple goals sorted by identifier with children grouped" do
      g2 = task(%{id: 1, identifier: "G2", type: :goal})
      g1 = task(%{id: 2, identifier: "G1", type: :goal})
      g2_child = task(%{id: 3, identifier: "W10", type: :work, parent_id: 1})
      g1_child = task(%{id: 4, identifier: "W5", type: :work, parent_id: 2})

      result = Queries.sort_by_goal_hierarchy([g2_child, g2, g1_child, g1])
      assert Enum.map(result, & &1.identifier) == ["G1", "W5", "G2", "W10"]
    end

    test "goals with no children in the list still appear" do
      standalone = task(%{id: 1, identifier: "W1", type: :work})
      goal = task(%{id: 2, identifier: "G1", type: :goal})

      result = Queries.sort_by_goal_hierarchy([standalone, goal])
      assert Enum.map(result, & &1.identifier) == ["W1", "G1"]
    end

    test "defects are treated as standalone tasks" do
      defect = task(%{id: 1, identifier: "D1", type: :defect})
      work = task(%{id: 2, identifier: "W1", type: :work})

      result = Queries.sort_by_goal_hierarchy([work, defect])
      assert Enum.map(result, & &1.identifier) == ["D1", "W1"]
    end
  end
end
