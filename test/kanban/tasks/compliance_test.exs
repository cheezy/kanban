defmodule Kanban.Tasks.ComplianceTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks.Compliance

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    other_board = board_fixture(user)
    other_column = column_fixture(other_board)

    %{
      board: board,
      column: column,
      other_board: other_board,
      other_column: other_column
    }
  end

  defp seed(column, attrs), do: task_fixture(column, attrs)

  describe "step_dispatch_rates/1" do
    test "returns empty map when board has no tasks", %{board: board} do
      assert Compliance.step_dispatch_rates(board.id) == %{}
    end

    test "returns empty map when tasks have empty workflow_steps", %{
      board: board,
      column: column
    } do
      seed(column, %{workflow_steps: []})
      assert Compliance.step_dispatch_rates(board.id) == %{}
    end

    test "computes dispatch rate per step name", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"name" => "build", "dispatched" => true}]})
      seed(column, %{workflow_steps: [%{"name" => "build", "dispatched" => false}]})
      seed(column, %{workflow_steps: [%{"name" => "build", "dispatched" => true}]})

      result = Compliance.step_dispatch_rates(board.id)

      assert %{rate: rate, total: 3, dispatched: 2} = Map.fetch!(result, "build")
      assert_in_delta rate, 66.666, 0.01
    end

    test "handles multiple distinct step names", %{board: board, column: column} do
      seed(column, %{
        workflow_steps: [
          %{"name" => "build", "dispatched" => true},
          %{"name" => "lint", "dispatched" => false}
        ]
      })

      result = Compliance.step_dispatch_rates(board.id)

      assert %{rate: 100.0, total: 1, dispatched: 1} = Map.fetch!(result, "build")
      assert %{rate: +0.0, total: 1, dispatched: 0} = Map.fetch!(result, "lint")
    end

    test "ignores steps missing the name key", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"dispatched" => true}]})

      assert Compliance.step_dispatch_rates(board.id) == %{}
    end

    test "missing dispatched key counts as not dispatched", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"name" => "deploy"}]})

      result = Compliance.step_dispatch_rates(board.id)

      assert %{rate: +0.0, total: 1, dispatched: 0} = Map.fetch!(result, "deploy")
    end

    test "scopes by board_id (no cross-board leakage)", %{
      board: board,
      other_column: other_column
    } do
      seed(other_column, %{
        workflow_steps: [%{"name" => "build", "dispatched" => true}]
      })

      assert Compliance.step_dispatch_rates(board.id) == %{}
    end
  end

  describe "skip_reasons/1" do
    test "returns empty map when board has no tasks", %{board: board} do
      assert Compliance.skip_reasons(board.id) == %{}
    end

    # (D233) These previously seeded `%{"skipped" => true}` — a shape no agent
    # has ever emitted. The query filtered on the same non-existent key, so the
    # tests and the query encoded the same wrong schema and validated each
    # other, which is why an always-empty panel looked like a working one.
    # Every case below now uses the real schema: dispatched false + reason.
    test "ignores dispatched steps", %{board: board, column: column} do
      seed(column, %{
        workflow_steps: [%{"name" => "explorer", "dispatched" => true, "duration_ms" => 100}]
      })

      assert Compliance.skip_reasons(board.id) == %{}
    end

    test "counts steps that agents actually emit as skipped", %{board: board, column: column} do
      seed(column, %{
        workflow_steps: [
          %{"name" => "planner", "dispatched" => false, "reason" => "no tests"},
          %{"name" => "implementation", "dispatched" => false, "reason" => "no tests"}
        ]
      })

      seed(column, %{
        workflow_steps: [%{"name" => "reviewer", "dispatched" => false, "reason" => "manual"}]
      })

      result = Compliance.skip_reasons(board.id)

      assert Map.fetch!(result, "no tests") == 2
      assert Map.fetch!(result, "manual") == 1
    end

    test "does not count a legacy `skipped` key on its own", %{board: board, column: column} do
      # The key the old query filtered on. It carries no meaning in the schema,
      # so on its own it must not produce a row — otherwise the defect could
      # quietly return via data rather than via code.
      seed(column, %{workflow_steps: [%{"name" => "planner", "skipped" => true}]})

      assert Compliance.skip_reasons(board.id) == %{}
    end

    test "counts a historical row that has no reason", %{board: board, column: column} do
      # Rows written before the validator required a reason. Grouped under ""
      # rather than dropped, so the count stays truthful even when the text is
      # missing.
      seed(column, %{workflow_steps: [%{"name" => "planner", "dispatched" => false}]})

      result = Compliance.skip_reasons(board.id)

      assert Map.fetch!(result, "") == 1
    end

    test "keeps differing text for the same logical skip as separate rows",
         %{board: board, column: column} do
      # The documented consequence of NOT canonicalising (see the moduledoc):
      # two agents describing the same skip differently produce two rows. This
      # pins the decision so a future change to it is deliberate rather than
      # accidental.
      seed(column, %{
        workflow_steps: [
          %{"name" => "planner", "dispatched" => false, "reason" => "planned inline"},
          %{"name" => "planner", "dispatched" => false, "reason" => "Planned inline."}
        ]
      })

      result = Compliance.skip_reasons(board.id)

      assert Map.fetch!(result, "planned inline") == 1
      assert Map.fetch!(result, "Planned inline.") == 1
    end

    test "counts an entry whose name is not one of the six canonical steps",
         %{board: board, column: column} do
      # `name` is unconstrained by the validator, so a typo or an invented step
      # still aggregates by reason. Counted rather than dropped: silently
      # discarding it would hide the very fragmentation worth noticing.
      seed(column, %{
        workflow_steps: [%{"name" => "revieweer", "dispatched" => false, "reason" => "typo"}]
      })

      assert Map.fetch!(Compliance.skip_reasons(board.id), "typo") == 1
    end

    test "scopes by board_id (no cross-board leakage)", %{
      board: board,
      other_column: other_column
    } do
      seed(other_column, %{
        workflow_steps: [%{"name" => "planner", "dispatched" => false, "reason" => "r"}]
      })

      assert Compliance.skip_reasons(board.id) == %{}
    end
  end

  describe "compliance_by_agent/1" do
    test "returns empty map when board has no tasks", %{board: board} do
      assert Compliance.compliance_by_agent(board.id) == %{}
    end

    test "ignores tasks without completed_by_agent", %{board: board, column: column} do
      seed(column, %{completed_by_agent: nil, workflow_steps: []})

      assert Compliance.compliance_by_agent(board.id) == %{}
    end

    test "groups by agent with metrics", %{board: board, column: column} do
      seed(column, %{
        completed_by_agent: "agent_a",
        workflow_steps: [
          %{"name" => "x"},
          %{"name" => "y"},
          %{"name" => "z"}
        ]
      })

      seed(column, %{
        completed_by_agent: "agent_a",
        workflow_steps: []
      })

      seed(column, %{
        completed_by_agent: "agent_b",
        workflow_steps: [%{"name" => "x"}, %{"name" => "y"}]
      })

      result = Compliance.compliance_by_agent(board.id)

      assert %{total_tasks: 2, tasks_with_steps: 1, avg_steps: avg_a} = result["agent_a"]
      assert_in_delta avg_a, 1.5, 0.001

      assert %{total_tasks: 1, tasks_with_steps: 1, avg_steps: avg_b} = result["agent_b"]
      assert_in_delta avg_b, 2.0, 0.001
    end

    test "scopes by board_id (no cross-board leakage)", %{
      board: board,
      other_column: other_column
    } do
      seed(other_column, %{
        completed_by_agent: "agent_a",
        workflow_steps: [%{"name" => "x"}]
      })

      assert Compliance.compliance_by_agent(board.id) == %{}
    end
  end
end
