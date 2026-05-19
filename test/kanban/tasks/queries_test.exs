defmodule Kanban.Tasks.QueriesTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Queries

  # Within each test, ordering is driven by the relative `inserted_at`
  # values supplied via `at/1` — smaller integer = older, sorts first.
  # `sort_by_goal_hierarchy/1` now uses `inserted_at` instead of parsing
  # identifiers, so timestamps are the source of truth for expected order.
  defp at(seconds_offset) do
    NaiveDateTime.add(~N[2026-01-01 00:00:00], seconds_offset, :second)
  end

  defp task(attrs) do
    defaults = %{
      id: nil,
      identifier: nil,
      type: :work,
      parent_id: nil,
      inserted_at: ~N[2026-01-01 00:00:00]
    }

    struct!(Kanban.Tasks.Task, Map.merge(defaults, attrs))
  end

  describe "sort_by_goal_hierarchy/1" do
    test "returns empty list unchanged" do
      assert Queries.sort_by_goal_hierarchy([]) == []
    end

    test "standalone tasks come first, sorted by inserted_at" do
      t1 = task(%{id: 1, identifier: "W3", inserted_at: at(2)})
      t2 = task(%{id: 2, identifier: "W1", inserted_at: at(0)})
      t3 = task(%{id: 3, identifier: "W2", inserted_at: at(1)})

      result = Queries.sort_by_goal_hierarchy([t1, t2, t3])
      assert Enum.map(result, & &1.identifier) == ["W1", "W2", "W3"]
    end

    test "goals appear after standalone tasks with children underneath" do
      standalone = task(%{id: 1, identifier: "W5", inserted_at: at(0)})
      goal = task(%{id: 2, identifier: "G1", type: :goal, inserted_at: at(1)})
      child_a = task(%{id: 3, identifier: "W1", parent_id: 2, inserted_at: at(2)})
      child_b = task(%{id: 4, identifier: "W2", parent_id: 2, inserted_at: at(3)})

      result = Queries.sort_by_goal_hierarchy([child_b, goal, standalone, child_a])
      assert Enum.map(result, & &1.identifier) == ["W5", "G1", "W1", "W2"]
    end

    test "multiple goals sorted by inserted_at with children grouped" do
      g1 = task(%{id: 1, identifier: "G1", type: :goal, inserted_at: at(0)})
      g2 = task(%{id: 2, identifier: "G2", type: :goal, inserted_at: at(2)})
      g1_child = task(%{id: 3, identifier: "W5", parent_id: 1, inserted_at: at(1)})
      g2_child = task(%{id: 4, identifier: "W10", parent_id: 2, inserted_at: at(3)})

      result = Queries.sort_by_goal_hierarchy([g2_child, g2, g1_child, g1])
      assert Enum.map(result, & &1.identifier) == ["G1", "W5", "G2", "W10"]
    end

    test "goals with no children in the list still appear" do
      standalone = task(%{id: 1, identifier: "W1", inserted_at: at(0)})
      goal = task(%{id: 2, identifier: "G1", type: :goal, inserted_at: at(1)})

      result = Queries.sort_by_goal_hierarchy([standalone, goal])
      assert Enum.map(result, & &1.identifier) == ["W1", "G1"]
    end

    test "defects are treated as standalone tasks" do
      defect = task(%{id: 1, identifier: "D1", type: :defect, inserted_at: at(0)})
      work = task(%{id: 2, identifier: "W1", inserted_at: at(1)})

      result = Queries.sort_by_goal_hierarchy([work, defect])
      assert Enum.map(result, & &1.identifier) == ["D1", "W1"]
    end

    test "child tasks whose parent goal is not in the list still appear" do
      # Simulates the Done column: a goal has some children done and some
      # still in another column. The completed children must not vanish.
      standalone = task(%{id: 1, identifier: "W3", inserted_at: at(0)})
      orphan_child = task(%{id: 2, identifier: "W7", parent_id: 99, inserted_at: at(1)})

      result = Queries.sort_by_goal_hierarchy([orphan_child, standalone])
      assert Enum.map(result, & &1.identifier) == ["W3", "W7"]
    end

    test "mix of standalone, orphan children, and goals with children" do
      standalone = task(%{id: 1, identifier: "W1", inserted_at: at(0)})
      orphan_child = task(%{id: 2, identifier: "W2", parent_id: 99, inserted_at: at(1)})
      goal = task(%{id: 3, identifier: "G1", type: :goal, inserted_at: at(2)})
      goal_child = task(%{id: 4, identifier: "W5", parent_id: 3, inserted_at: at(3)})

      result =
        Queries.sort_by_goal_hierarchy([orphan_child, goal_child, goal, standalone])

      assert Enum.map(result, & &1.identifier) == ["W1", "W2", "G1", "W5"]
    end
  end
end
