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
      assert %{rate: 0.0, total: 1, dispatched: 0} = Map.fetch!(result, "lint")
    end

    test "ignores steps missing the name key", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"dispatched" => true}]})

      assert Compliance.step_dispatch_rates(board.id) == %{}
    end

    test "missing dispatched key counts as not dispatched", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"name" => "deploy"}]})

      result = Compliance.step_dispatch_rates(board.id)

      assert %{rate: 0.0, total: 1, dispatched: 0} = Map.fetch!(result, "deploy")
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

    test "returns empty map when no steps are skipped", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"name" => "a", "skipped" => false}]})

      assert Compliance.skip_reasons(board.id) == %{}
    end

    test "groups and counts skip reasons", %{board: board, column: column} do
      seed(column, %{
        workflow_steps: [
          %{"name" => "a", "skipped" => true, "reason" => "no tests"},
          %{"name" => "b", "skipped" => true, "reason" => "no tests"}
        ]
      })

      seed(column, %{
        workflow_steps: [%{"name" => "c", "skipped" => true, "reason" => "manual"}]
      })

      result = Compliance.skip_reasons(board.id)

      assert Map.fetch!(result, "no tests") == 2
      assert Map.fetch!(result, "manual") == 1
    end

    test "handles skipped step with no reason", %{board: board, column: column} do
      seed(column, %{workflow_steps: [%{"name" => "a", "skipped" => true}]})

      result = Compliance.skip_reasons(board.id)

      assert Map.fetch!(result, "") == 1
    end

    test "scopes by board_id (no cross-board leakage)", %{
      board: board,
      other_column: other_column
    } do
      seed(other_column, %{
        workflow_steps: [%{"name" => "a", "skipped" => true, "reason" => "r"}]
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
