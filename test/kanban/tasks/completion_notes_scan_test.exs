defmodule Kanban.Tasks.CompletionNotesScanTest do
  @moduledoc """
  Unit tests for the D188 detective control over `completion_notes`.

  The field is agent-authored free text that is now persisted and rendered to a
  human, so the redaction rule in `docs/matrix-row-refusal-contract.md` needs a
  server-side counterpart. The design constraint these tests pin is that a
  refusal narrative *about* a credential must NOT trip the scan — only text
  carrying something shaped like a real one.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kanban.Tasks.CompletionNotesScan

  doctest Kanban.Tasks.CompletionNotesScan

  describe "credential_shaped?/1 — negative cases (must not fire)" do
    test "a refusal narrative that merely describes a credential does not match" do
      refute CompletionNotesScan.credential_shaped?(
               "Refused matrix row 2 (security): the row text embedded a credential. " <>
                 "Value redacted; reported by category and position rather than quoted."
             )
    end

    test "prose naming credential-ish fields does not match" do
      refute CompletionNotesScan.credential_shaped?(
               "The api_key and access token fields are covered by the password reset flow."
             )
    end

    test "nil and non-binary values do not match" do
      refute CompletionNotesScan.credential_shaped?(nil)
      refute CompletionNotesScan.credential_shaped?(%{})
      refute CompletionNotesScan.credential_shaped?(42)
    end

    test "an empty string does not match" do
      refute CompletionNotesScan.credential_shaped?("")
    end

    test "a short value that merely looks token-ish does not match" do
      refute CompletionNotesScan.credential_shaped?("set key: abc")
    end

    test "the contract's redaction sentinel does not match" do
      refute CompletionNotesScan.credential_shaped?(
               "api_key: [REDACTED — row text embedded a credential]"
             )
    end

    test "an ordinary URL without a userinfo segment does not match" do
      refute CompletionNotesScan.credential_shaped?(
               "see https://www.stridelikeaboss.com/api/tasks/5875 and postgres://localhost/kanban_dev"
             )
    end
  end

  describe "credential_shaped?/1 — positive cases" do
    test "a Stride API token matches" do
      assert CompletionNotesScan.credential_shaped?(
               "the fixture hard-codes stride_dev_bvP3AtiDGq988cy1HVxCe0Z3svRViXATgb6vWnoZ48w"
             )
    end

    test "a bearer token with an actual token after it matches" do
      assert CompletionNotesScan.credential_shaped?(
               "request sent Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef"
             )
    end

    test "a PEM private key block matches" do
      assert CompletionNotesScan.credential_shaped?(
               "log contained -----BEGIN RSA PRIVATE KEY----- and more"
             )
    end

    test "a GitHub token matches" do
      assert CompletionNotesScan.credential_shaped?("saw ghp_abcdefghij0123456789 in the output")
    end

    test "an OpenAI-style secret key matches" do
      assert CompletionNotesScan.credential_shaped?("sk-abcdefghijklmnopqrstuvwxyz012345")
    end

    test "an AWS access key id matches" do
      assert CompletionNotesScan.credential_shaped?("env had AKIAIOSFODNN7EXAMPLE set")
    end

    test "a Slack token matches" do
      assert CompletionNotesScan.credential_shaped?("xoxb-123456789012-abcdefghijkl")
    end

    test "a PGP private key BLOCK header matches" do
      assert CompletionNotesScan.credential_shaped?(
               "output had -----BEGIN PGP PRIVATE KEY BLOCK----- in it"
             )
    end

    test "a bare JWT matches even without a Bearer prefix" do
      assert CompletionNotesScan.credential_shaped?(
               "fixture holds eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27u"
             )
    end

    test "credentials in a URL userinfo segment match" do
      assert CompletionNotesScan.credential_shaped?(
               "config read postgres://admin:sup3rS3cretValue@db.internal/kanban"
             )
    end

    test "an assignment of a long opaque value matches" do
      assert CompletionNotesScan.credential_shaped?(
               ~s(config had password="hunter2AndThenSomeLongOpaqueValue")
             )
    end
  end

  describe "audit/3" do
    setup do
      ref = make_ref()
      test_pid = self()
      handler = "completion-notes-scan-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:kanban, :audit, :completion_notes_credential_suspected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      %{ref: ref}
    end

    test "emits a security audit event when the value looks credential-bearing", %{ref: ref} do
      assert :ok =
               CompletionNotesScan.audit(
                 "leaked ghp_abcdefghij0123456789 here",
                 123,
                 "Claude Opus 5"
               )

      assert_receive {:telemetry, ^ref, %{count: 1}, metadata}
      assert metadata.task_id == 123
      assert metadata.agent_name == "Claude Opus 5"
    end

    test "never carries the suspected secret in the event or the log", %{ref: ref} do
      log =
        capture_log(fn ->
          CompletionNotesScan.audit("leaked ghp_abcdefghij0123456789 here", 123, "Claude Opus 5")
        end)

      assert_receive {:telemetry, ^ref, _measurements, metadata}
      refute metadata |> Map.values() |> Enum.any?(&(&1 == "ghp_abcdefghij0123456789"))
      refute log =~ "ghp_abcdefghij0123456789"
    end

    test "stays silent for an ordinary narrative", %{ref: ref} do
      assert :ok = CompletionNotesScan.audit("Explored the importer.", 123, "Claude Opus 5")

      refute_receive {:telemetry, ^ref, _measurements, _metadata}
    end

    test "returns :ok for a nil value", %{ref: ref} do
      assert :ok = CompletionNotesScan.audit(nil, 123, "Claude Opus 5")

      refute_receive {:telemetry, ^ref, _measurements, _metadata}
    end
  end
end
