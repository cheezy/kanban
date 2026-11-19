defmodule Kanban.AuditLog.RedactionTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditLog.Redaction

  describe "drop?/2" do
    test "drops credential-shaped keys, as atoms or strings" do
      for key <- [:password, :reset_token, "api_key", :client_secret, :authorization, :otp] do
        assert Redaction.drop?(key, "value"), "expected #{inspect(key)} to be dropped"
      end
    end

    test "keeps *_id keys and ordinary keys" do
      for key <- [:token_id, "device_id", :board_id, :via, "files"] do
        refute Redaction.drop?(key, 1), "expected #{inspect(key)} to be kept"
      end
    end

    test "keeps approval_key only when it holds a boolean" do
      refute Redaction.drop?(:approval_key, true)
      refute Redaction.drop?("approval_key", false)

      assert Redaction.drop?(:approval_key, "raw-key-text")
      assert Redaction.drop?(:approval_key, nil)
      assert Redaction.drop?(:approval_public_key, true)
    end
  end
end
