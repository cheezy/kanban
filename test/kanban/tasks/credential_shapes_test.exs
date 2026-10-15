defmodule Kanban.Tasks.CredentialShapesTest do
  @moduledoc """
  Unit tests for the shared credential-shape list (W2382). The list moved here
  from `Kanban.Tasks.CompletionNotesScan`, so these pin that every shape the
  scan matched still matches through both entry points, and that prose about
  credentials still does not.
  """

  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionNotesScan
  alias Kanban.Tasks.CredentialShapes

  doctest Kanban.Tasks.CredentialShapes

  # One example per pattern — the same fixtures completion_notes_scan_test.exs
  # uses. All are fake values.
  @positives [
    stride_token: "the fixture hard-codes stride_dev_bvP3AtiDGq988cy1HVxCe0Z3svRViXATgb6vWnoZ48w",
    bearer: "request sent Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef",
    pem_key: "log contained -----BEGIN RSA PRIVATE KEY----- and more",
    pgp_key: "output had -----BEGIN PGP PRIVATE KEY BLOCK----- in it",
    jwt: "fixture holds eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27u",
    url_userinfo: "config read postgres://admin:sup3rS3cretValue@db.internal/kanban",
    github: "saw ghp_abcdefghij0123456789 in the output",
    openai: "sk-abcdefghijklmnopqrstuvwxyz012345",
    aws: "env had AKIAIOSFODNN7EXAMPLE set",
    slack: "xoxb-123456789012-abcdefghijkl",
    assignment: ~s(config had password="hunter2AndThenSomeLongOpaqueValue")
  ]

  describe "match?/1" do
    test "matches every pattern CompletionNotesScan matched" do
      for {shape, text} <- @positives do
        assert CredentialShapes.match?(text), "expected #{shape} to match"

        assert CompletionNotesScan.credential_shaped?(text),
               "expected CompletionNotesScan to still match #{shape}"
      end
    end

    test "does not match prose that only describes credentials" do
      for text <- [
            "API tokens are never logged",
            "Never log sensitive data (passwords, tokens, credit cards)",
            "bearer tokens are never written to the audit log",
            "The api_key and access token fields are covered by the password reset flow.",
            "api_key: [REDACTED — row text embedded a credential]"
          ] do
        refute CredentialShapes.match?(text), "expected no match for: #{text}"
      end
    end

    test "does not match a short example token below the length floor" do
      refute CredentialShapes.match?("e.g. stride_dev_abc123")
    end

    test "is false for an empty string and for non-strings" do
      refute CredentialShapes.match?("")
      refute CredentialShapes.match?(nil)
      refute CredentialShapes.match?(42)
      refute CredentialShapes.match?(%{})
      refute CredentialShapes.match?(["ghp_abcdefghij0123456789"])
    end
  end
end
