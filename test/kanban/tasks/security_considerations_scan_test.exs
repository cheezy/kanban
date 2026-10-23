defmodule Kanban.Tasks.SecurityConsiderationsScanTest do
  @moduledoc """
  Unit tests for the W2382 detective control over the security-consideration
  strings a reviewer echoes into `reviewer_result`, and for the W2384 read-only
  report over the stored field.
  """

  use Kanban.DataCase, async: true

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Tasks.SecurityConsiderationsScan
  alias Kanban.Tasks.Task

  doctest Kanban.Tasks.SecurityConsiderationsScan

  # Fake values only.
  @token "ghp_abcdefghij0123456789"
  @other_token "ghp_zyxwvutsrq9876543210"
  @event [:kanban, :audit, :security_considerations_credential_suspected]

  defp result_with(section), do: %{"security_considerations" => section}

  defp result_with_entry(entry), do: result_with(%{"considerations" => [entry]})

  describe "credential_shaped?/1" do
    test "matches a credential in a string-keyed consideration" do
      result =
        result_with_entry(%{"consideration" => "fixture uses #{@token}", "status" => "mitigated"})

      assert SecurityConsiderationsScan.credential_shaped?(result)
    end

    test "matches a credential in an atom-keyed consideration" do
      assert SecurityConsiderationsScan.credential_shaped?(%{
               security_considerations: %{considerations: [%{consideration: "uses #{@token}"}]}
             })
    end

    test "matches a credential in an entry's evidence or note" do
      in_evidence =
        result_with_entry(%{"consideration" => "Scoped", "evidence" => "saw #{@token}"})

      in_note = result_with_entry(%{"consideration" => "Scoped", "note" => "saw #{@token}"})

      assert SecurityConsiderationsScan.credential_shaped?(in_evidence)
      assert SecurityConsiderationsScan.credential_shaped?(in_note)
    end

    test "matches a credential in the section-level note" do
      result = result_with(%{"note" => "saw #{@token}", "considerations" => []})

      assert SecurityConsiderationsScan.credential_shaped?(result)
    end

    test "does not match prose or the redaction sentinel" do
      result =
        result_with(%{
          "note" => "All considerations mitigated.",
          "considerations" => [
            %{"consideration" => "API tokens are never logged", "status" => "mitigated"},
            %{"consideration" => "[REDACTED — row text embedded a credential]"}
          ]
        })

      refute SecurityConsiderationsScan.credential_shaped?(result)
    end

    test "is false for every malformed or absent shape" do
      for value <- [
            nil,
            "x",
            42,
            %{},
            %{"dispatched" => false, "reason" => "small_task_0_1_key_files"},
            result_with("passed"),
            result_with(%{"considerations" => "nope"}),
            result_with(%{"considerations" => [nil, 5, "uses #{@token}"]}),
            result_with_entry(%{"consideration" => 123})
          ] do
        refute SecurityConsiderationsScan.credential_shaped?(value), "matched #{inspect(value)}"
      end
    end
  end

  describe "audit/3" do
    setup do
      attach_telemetry(@event)
      :ok
    end

    test "emits one security audit event for a credential-shaped consideration" do
      result =
        result_with(%{
          "note" => "also #{@token}",
          "considerations" => [
            %{"consideration" => "uses #{@token}"},
            %{"consideration" => "Scoped", "evidence" => "saw #{@token}"}
          ]
        })

      assert :ok = SecurityConsiderationsScan.audit(result, 123, "Claude Opus 5.5")

      assert_receive {:telemetry_event, @event, %{count: 1}, metadata}
      assert metadata.task_id == 123
      assert metadata.agent_name == "Claude Opus 5.5"
      refute_receive {:telemetry_event, @event, _measurements, _metadata}
    end

    test "never carries the suspected secret in the event or the log" do
      result = result_with_entry(%{"consideration" => "uses #{@token}"})

      log =
        capture_log(fn ->
          SecurityConsiderationsScan.audit(result, 123, "Claude Opus 5.5")
        end)

      assert_receive {:telemetry_event, @event, _measurements, metadata}
      refute inspect(metadata) =~ @token
      refute log =~ @token
    end

    test "stays silent and returns :ok for clean or missing input" do
      clean = result_with_entry(%{"consideration" => "API tokens are never logged"})

      assert :ok = SecurityConsiderationsScan.audit(clean, 123, "Claude Opus 5.5")

      assert :ok = SecurityConsiderationsScan.audit(nil, 123, "Claude Opus 5.5")

      refute_receive {:telemetry_event, @event, _measurements, _metadata}
    end
  end

  describe "scan_stored/0" do
    setup do
      board = board_fixture(user_fixture())
      %{column: column_fixture(board)}
    end

    # The write path refuses a credential-shaped consideration since W2382, so
    # the pre-W2382 state is reproduced by writing the column directly.
    defp store_considerations(task, considerations) do
      {1, _} =
        Task
        |> where([t], t.id == ^task.id)
        |> Repo.update_all(set: [security_considerations: considerations])

      task
    end

    defp stored_task(column, considerations, attrs \\ %{}) do
      column
      |> task_fixture(attrs)
      |> store_considerations(considerations)
    end

    test "scan_stored/0 reports the identifier and 1-based position of each credential-shaped stored consideration",
         %{column: column} do
      _clean = stored_task(column, ["API tokens are never logged"])

      several =
        stored_task(column, [
          "fixture uses #{@token}",
          "Inputs are validated",
          "saw #{@other_token} in a log"
        ])

      single = stored_task(column, ["Scoped", "uses #{@token}"])

      assert SecurityConsiderationsScan.scan_stored() == [
               %{identifier: several.identifier, task_id: several.id, positions: [1, 3]},
               %{identifier: single.identifier, task_id: single.id, positions: [2]}
             ]
    end

    test "scan_stored/0 includes archived tasks and goals", %{column: column} do
      archived = stored_task(column, ["uses #{@token}"])

      Task
      |> where([t], t.id == ^archived.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      goal = stored_task(column, ["uses #{@token}"], %{type: :goal})

      report = SecurityConsiderationsScan.scan_stored()

      assert Enum.map(report, & &1.task_id) == Enum.sort([archived.id, goal.id])
    end

    test "scan_stored/0 reads every batch when the matches span several", %{column: column} do
      tasks = for _ <- 1..5, do: stored_task(column, ["uses #{@token}"])
      _clean = stored_task(column, ["Inputs are validated"])

      report = SecurityConsiderationsScan.scan_stored(batch_size: 2)

      assert Enum.map(report, & &1.task_id) == tasks |> Enum.map(& &1.id) |> Enum.sort()
      assert SecurityConsiderationsScan.scan_stored(batch_size: 1) == report
    end

    test "scan_stored/0 never returns or logs the matched value", %{column: column} do
      task = stored_task(column, ["fixture uses #{@token}", "saw #{@other_token}"])
      before = Repo.get!(Task, task.id)

      # Lower the scan module's own level so a debug or info line naming the
      # value would be captured; the primary level in test is :warning, and a
      # module level is the one override :logger honours below it.
      Logger.put_module_level(SecurityConsiderationsScan, :debug)

      {report, log} =
        try do
          with_log([level: :debug], fn -> SecurityConsiderationsScan.scan_stored() end)
        after
          Logger.delete_module_level(SecurityConsiderationsScan)
        end

      assert [%{task_id: task_id}] = report
      assert task_id == task.id
      assert report |> hd() |> Map.keys() |> Enum.sort() == [:identifier, :positions, :task_id]
      refute inspect(report) =~ @token
      refute inspect(report) =~ @other_token
      refute log =~ @token
      refute log =~ @other_token

      # Read-only: the stored row is unchanged.
      assert Repo.get!(Task, task.id) == before
    end

    test "scan_stored/0 returns an empty list when no stored consideration matches",
         %{column: column} do
      _clean =
        stored_task(column, [
          "API tokens are never logged",
          "[REDACTED — row text embedded a credential]"
        ])

      assert SecurityConsiderationsScan.scan_stored() == []
    end

    test "scan_stored/0 skips tasks with nil or empty security_considerations",
         %{column: column} do
      _nil = stored_task(column, nil)
      _empty = stored_task(column, [])
      hit = stored_task(column, ["uses #{@token}"])

      assert [%{task_id: task_id}] = SecurityConsiderationsScan.scan_stored()
      assert task_id == hit.id
    end
  end
end
