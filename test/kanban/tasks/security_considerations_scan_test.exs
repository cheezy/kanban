defmodule Kanban.Tasks.SecurityConsiderationsScanTest do
  @moduledoc """
  Unit tests for the W2382 detective control over the security-consideration
  strings a reviewer echoes into `reviewer_result`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Kanban.TelemetryHelpers

  alias Kanban.Tasks.SecurityConsiderationsScan

  doctest Kanban.Tasks.SecurityConsiderationsScan

  # Fake value only.
  @token "ghp_abcdefghij0123456789"
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
end
