defmodule Mix.Tasks.DarkMode.EnsureAuditUserTest do
  # async: false — these tests read/write process-global environment variables.
  use ExUnit.Case, async: false

  alias Mix.Tasks.DarkMode.EnsureAuditUser

  setup do
    # Snapshot and restore the env vars so tests don't leak into each other.
    prev_pw = System.get_env("STRIDE_AUDIT_PASSWORD")
    prev_email = System.get_env("STRIDE_AUDIT_EMAIL")

    on_exit(fn ->
      restore("STRIDE_AUDIT_PASSWORD", prev_pw)
      restore("STRIDE_AUDIT_EMAIL", prev_email)
    end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  describe "resolve_audit_password/0 (W1435)" do
    test "returns {:error, :missing_password} when STRIDE_AUDIT_PASSWORD is unset" do
      System.delete_env("STRIDE_AUDIT_PASSWORD")
      assert EnsureAuditUser.resolve_audit_password() == {:error, :missing_password}
    end

    test "returns {:error, :missing_password} when STRIDE_AUDIT_PASSWORD is empty" do
      System.put_env("STRIDE_AUDIT_PASSWORD", "")
      assert EnsureAuditUser.resolve_audit_password() == {:error, :missing_password}
    end

    test "returns {:ok, password} when STRIDE_AUDIT_PASSWORD is set" do
      System.put_env("STRIDE_AUDIT_PASSWORD", "set-by-test-pw-123456789")
      assert EnsureAuditUser.resolve_audit_password() == {:ok, "set-by-test-pw-123456789"}
    end
  end

  describe "audit_email/0 (W1435)" do
    test "defaults to the dev audit email when STRIDE_AUDIT_EMAIL is unset" do
      System.delete_env("STRIDE_AUDIT_EMAIL")
      assert EnsureAuditUser.audit_email() == "dark-mode-audit@stride.local"
    end

    test "uses STRIDE_AUDIT_EMAIL when set" do
      System.put_env("STRIDE_AUDIT_EMAIL", "auditor@example.com")
      assert EnsureAuditUser.audit_email() == "auditor@example.com"
    end
  end
end
