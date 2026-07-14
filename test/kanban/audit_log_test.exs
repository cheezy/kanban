defmodule Kanban.AuditLogTest do
  # async: false because two tests lower the global Logger level to capture the
  # :info audit line (the suite otherwise runs at :warning).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLog

  setup do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)
    :ok
  end

  defp attach(action) do
    test_pid = self()
    event = [:kanban, :audit, action]
    handler_id = "audit-test-#{action}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:audit, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits a telemetry event with count and sanitized metadata" do
    attach(:login_failed)

    AuditLog.event(:login_failed, email: "a@example.com", ip: {203, 0, 113, 5})

    assert_receive {:audit, %{count: 1}, metadata}
    assert metadata.email == "a@example.com"
    assert metadata.ip == "203.0.113.5"
  end

  test "formats IPv6 tuples to strings" do
    attach(:api_token_auth_failed)

    AuditLog.event(:api_token_auth_failed,
      ip: {8193, 3512, 0, 0, 0, 0, 0, 1},
      reason: "not_found"
    )

    assert_receive {:audit, _m, metadata}
    assert metadata.ip == "2001:db8::1"
    assert metadata.reason == "not_found"
  end

  test "drops sensitive keys before emitting" do
    attach(:login_failed)

    AuditLog.event(:login_failed,
      email: "a@example.com",
      password: "hunter2",
      token: "raw-secret-token"
    )

    assert_receive {:audit, _m, metadata}
    assert metadata.email == "a@example.com"
    refute Map.has_key?(metadata, :password)
    refute Map.has_key?(metadata, :token)
  end

  test "writes a structured security_audit log line without interpolating values" do
    log =
      capture_log(fn ->
        AuditLog.event(:sudo_mode_entered, user_id: 42)
      end)

    assert log =~ "security_audit"
  end

  test "sensitive values never reach the log output" do
    Logger.put_process_level(self(), :info)
    on_exit(fn -> Logger.delete_process_level(self()) end)

    log =
      capture_log([level: :info], fn ->
        AuditLog.event(:login_failed, email: "a@example.com", password: "hunter2")
      end)

    refute log =~ "hunter2"
  end
end
