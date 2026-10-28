defmodule Kanban.Tasks.AgentWorkflow.CompletionNotesTest do
  @moduledoc """
  The completion_notes (D188) tests for `Kanban.Tasks.AgentWorkflow.complete_task/4`.
  Split out of `agent_workflow_test.exs` (W2356) with every test moved unchanged,
  and kept apart from `completion_test.exs` so that file stays under ~600 lines.
  """
  use Kanban.DataCase, async: true

  import Kanban.AgentWorkflowHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

  describe "complete_task/4 — completion_notes (D188)" do
    setup :setup_board

    test "persists a submitted completion_notes value", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      params =
        Map.put(valid_complete_params(), "completion_notes", "Parser rejects UTF-16 input.")

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert completed.completion_notes == "Parser rejects UTF-16 input."
      assert Repo.get!(Task, task.id).completion_notes == "Parser rejects UTF-16 input."
    end

    test "leaves an existing completion_notes value unchanged when the key is omitted", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, seeded} =
        claimed
        |> Ecto.Changeset.change(completion_notes: "Recorded on an earlier pass.")
        |> Repo.update()

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(seeded, ctx.user, valid_complete_params(), "Claude")

      assert completed.completion_notes == "Recorded on an earlier pass."
    end

    test "accepts a very long completion_notes value without truncating it", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      long_notes = String.duplicate("finding ", 2_000)
      params = Map.put(valid_complete_params(), "completion_notes", long_notes)

      assert {:ok, _completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert Repo.get!(Task, task.id).completion_notes == long_notes
    end

    test "rejects a completion_notes value beyond the length bound", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      params = Map.put(valid_complete_params(), "completion_notes", String.duplicate("a", 65_536))

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert :completion_notes in Keyword.keys(cs.errors)
    end

    # D383: Postgres cannot store a NUL byte or invalid UTF-8, so the agent's
    # completion text gets a changeset error instead of a database error.
    test "refuses a NUL byte or invalid UTF-8 in the completion text fields", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      # Every text-bearing field completion_changeset/5 checks, each with a NUL
      # byte and with invalid UTF-8; list and map fields carry it nested.
      wrap = %{
        "workflow_steps" => &[%{"name" => "explorer", "reason" => &1}],
        "explorer_result" => &%{"summary" => &1},
        "reviewer_result" =>
          &%{
            "dispatched" => true,
            "summary" => &1,
            "issues" => [%{"description" => &1}],
            "testing_strategy" => %{"status" => "failed", "note" => &1}
          }
      }

      for field <- ~w(completion_summary completion_notes actual_files_changed
                      completed_by_agent review_report workflow_steps explorer_result
                      reviewer_result),
          bad <- [<<"bad", 0, "text">>, <<"bad", 0xFF, "text">>] do
        value = Map.get(wrap, field, & &1).(bad)
        params = Map.put(valid_complete_params(), field, value)

        assert {:error, %Ecto.Changeset{valid?: false} = cs} =
                 AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

        assert {"contains characters that are not allowed", []} in Keyword.get_values(
                 cs.errors,
                 String.to_existing_atom(field)
               ),
               "#{field}: #{inspect(cs.errors)}"
      end
    end

    test "emits a security audit event when completion_notes looks credential-bearing", ctx do
      ref = make_ref()
      test_pid = self()
      handler = "aw-completion-notes-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:kanban, :audit, :completion_notes_credential_suspected],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      task_id = task.id

      params =
        Map.put(
          valid_complete_params(),
          "completion_notes",
          "the fixture hard-codes ghp_abcdefghij0123456789"
        )

      assert {:ok, _completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      # Detect-only: the completion still succeeds and the narrative is kept.
      assert_receive {:telemetry, ^ref, %{task_id: ^task_id}}
      assert Repo.get!(Task, task_id).completion_notes =~ "ghp_"
    end

    test "completion emits :security_considerations_credential_suspected for a credential-shaped verdict string and still completes",
         ctx do
      event = [:kanban, :audit, :security_considerations_credential_suspected]
      attach_telemetry(event)

      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      task_id = task.id
      # Fake value only.
      token = "ghp_abcdefghij0123456789"

      params =
        Map.put(valid_complete_params(), "reviewer_result", %{
          "dispatched" => true,
          "summary" => String.duplicate("a", 40),
          "duration_ms" => 500,
          "acceptance_criteria_checked" => 3,
          "issues_found" => 0,
          "security_considerations" => %{
            "status" => "passed",
            "considerations" => [
              %{"consideration" => "the fixture hard-codes #{token}", "status" => "mitigated"}
            ]
          }
        })

      # Detect-only: the completion still succeeds.
      assert {:ok, _completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert_receive {:telemetry_event, ^event, %{count: 1},
                      %{task_id: ^task_id, agent_name: "Claude"} = metadata}

      refute inspect(metadata) =~ token
      refute_receive {:telemetry_event, ^event, _measurements, _metadata}
    end

    test "a reviewer_result with clean considerations raises no security audit event", ctx do
      event = [:kanban, :audit, :security_considerations_credential_suspected]
      attach_telemetry(event)

      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      params =
        Map.put(valid_complete_params(), "reviewer_result", %{
          "dispatched" => true,
          "summary" => String.duplicate("a", 40),
          "duration_ms" => 500,
          "acceptance_criteria_checked" => 3,
          "issues_found" => 0,
          "security_considerations" => %{
            "status" => "passed",
            "considerations" => [
              %{"consideration" => "API tokens are never logged", "status" => "mitigated"}
            ]
          }
        })

      assert {:ok, _completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      refute_receive {:telemetry_event, ^event, _measurements, _metadata}
    end

    test "a task whose stored consideration is credential-shaped can still be claimed and completed",
         ctx do
      task = create_open_task(ctx.ready, ctx.user)

      # Written before W2382's check existed: bypass the changeset to seed it.
      task
      |> Ecto.Changeset.change(
        security_considerations: ["stride_dev_" <> "AbCdEfGhIjKlMnOpQrSt0123"]
      )
      |> Repo.update!()

      claimed = claim_for(task, ctx.user, ctx.board)
      assert claimed.status == :in_progress

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert completed.completion_summary == "Did the work"
      assert completed.security_considerations == ["stride_dev_" <> "AbCdEfGhIjKlMnOpQrSt0123"]
    end

    test "is optional — a completion without it still succeeds", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert is_nil(completed.completion_notes)
    end
  end
end
