defmodule Kanban.Tasks.AgentWorkflow.CompletionPayloadTest do
  @moduledoc """
  The W398 completion payload validation tests for
  `Kanban.Tasks.AgentWorkflow.complete_task/4`. Split out of
  `agent_workflow_test.exs` (W2356) with every test moved unchanged.
  """
  use Kanban.DataCase, async: true

  import Kanban.AgentWorkflowHelpers

  alias Kanban.Tasks.AgentWorkflow

  describe "complete_task/4 — W398 payload validation" do
    setup :setup_board

    setup ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      Map.put(ctx, :claimed, claimed)
    end

    test "rejects malformed explorer_result", %{claimed: claimed, user: user} do
      params =
        valid_complete_params()
        |> Map.put("explorer_result", %{"dispatched" => true, "summary" => "too short"})

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :explorer_result)
    end

    test "rejects malformed reviewer_result", %{claimed: claimed, user: user} do
      params =
        valid_complete_params()
        |> Map.put("explorer_result", %{
          "dispatched" => true,
          "summary" => String.duplicate("a", 40),
          "duration_ms" => 1000
        })
        |> Map.put("reviewer_result", %{"dispatched" => true, "summary" => "x"})

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :reviewer_result)
    end

    test "rejects workflow_steps that are not a list", %{claimed: claimed, user: user} do
      params = Map.put(valid_complete_params(), "workflow_steps", "not-a-list")

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :workflow_steps)
    end

    test "rejects workflow_steps list entries missing required keys",
         %{claimed: claimed, user: user} do
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{"name" => "before_doing"}
        ])

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :workflow_steps)
    end

    test "rejects workflow_steps list entries where name is not a binary",
         %{claimed: claimed, user: user} do
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{"name" => 42, "dispatched" => false, "reason" => "wrong type"}
        ])

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :workflow_steps)
    end

    test "rejects workflow_steps list entries that are not maps",
         %{claimed: claimed, user: user} do
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{
            "name" => "explorer",
            "dispatched" => true,
            "duration_ms" => 100
          },
          "string-not-a-map"
        ])

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :workflow_steps)
    end

    test "accepts atom-keyed workflow_steps via the fetch_step_field fallback",
         %{claimed: claimed, user: user} do
      # Real-world callers post string keys, but the schema accepts atom-keyed
      # maps too. fetch_step_field/2 tries the string key first, then falls
      # back to the existing-atom — exercise that fallback explicitly.
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{name: "explorer", dispatched: true, duration_ms: 500}
        ])

      assert {:ok, _task, _hooks} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")
    end

    test "accepts workflow_steps that mix exotic keys without crashing the safe-atom rescue",
         %{claimed: claimed, user: user} do
      # safe_existing_atom/1 rescues ArgumentError when the key is not an
      # existing atom. Bury a key that almost certainly does not exist as an
      # atom anywhere in the running VM into a step that is otherwise
      # well-formed via its string keys — the rescue path must not crash the
      # validator.
      bogus_key = "z_" <> (System.unique_integer([:positive]) |> Integer.to_string()) <> "_xyz"

      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{
            "name" => "explorer",
            "dispatched" => true,
            "duration_ms" => 100,
            bogus_key => "ignored"
          }
        ])

      assert {:ok, _task, _hooks} =
               AgentWorkflow.complete_task(claimed, user, params, "Claude")
    end

    test "accepts well-formed workflow_steps + explorer/reviewer payloads",
         %{claimed: claimed, user: user} do
      summary = String.duplicate("a", 40)

      params =
        valid_complete_params()
        |> Map.put("explorer_result", %{
          "dispatched" => true,
          "summary" => summary,
          "duration_ms" => 1000
        })
        |> Map.put("reviewer_result", %{
          "dispatched" => true,
          "summary" => summary,
          "duration_ms" => 500,
          "acceptance_criteria_checked" => 3,
          "issues_found" => 0
        })
        |> Map.put("workflow_steps", [
          %{"name" => "explorer", "dispatched" => true, "duration_ms" => 1000},
          %{"name" => "planner", "dispatched" => false, "reason" => "small task"}
        ])

      assert {:ok, _task, _hooks} = AgentWorkflow.complete_task(claimed, user, params, "Claude")
    end

    test "persists a canonical reason_code alongside the free-text reason (D239)",
         %{claimed: claimed, user: user} do
      prose = "Step 3 matrix row 'small, 2+ key_files' gives Plan = Skip"

      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{
            "name" => "planner",
            "dispatched" => false,
            "reason_code" => "decision_matrix_skip",
            "reason" => prose
          }
        ])

      assert {:ok, task, _hooks} = AgentWorkflow.complete_task(claimed, user, params, "Claude")

      # Both survive: the code is what the dashboard aggregates, the prose is
      # what a human reads on the task detail page.
      assert [step] = task.workflow_steps
      assert step["reason_code"] == "decision_matrix_skip"
      assert step["reason"] == prose
    end

    test "rejects a completion carrying an unrecognised reason_code",
         %{claimed: claimed, user: user} do
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{
            "name" => "planner",
            "dispatched" => false,
            "reason" => "prose",
            "reason_code" => "invented_bucket"
          }
        ])

      assert {:error, cs} = AgentWorkflow.complete_task(claimed, user, params, "Claude")
      assert Keyword.has_key?(cs.errors, :workflow_steps)
    end

    test "still accepts a skipped step with prose and no reason_code at all",
         %{claimed: claimed, user: user} do
      # The back-compat guarantee: an agent that predates D239 — including
      # another runtime's plugin — completes exactly as it did before.
      params =
        Map.put(valid_complete_params(), "workflow_steps", [
          %{
            "name" => "planner",
            "dispatched" => false,
            "reason" => "Planned inline; the explorer left no design space."
          }
        ])

      assert {:ok, _task, _hooks} = AgentWorkflow.complete_task(claimed, user, params, "Claude")
    end
  end
end
