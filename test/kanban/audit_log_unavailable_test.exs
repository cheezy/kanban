defmodule Kanban.AuditLogUnavailableTest do
  @moduledoc """
  `Kanban.AuditLog.event/2` when the database cannot be reached. This module
  deliberately checks out no sandbox connection, so every Repo call raises
  `DBConnection.OwnershipError` — the same failure a caller would see if the
  database were down — and event/2 must still return `:ok`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kanban.AuditLog

  test "event/2 logs the failure without the values and still returns :ok" do
    test_pid = self()
    handler_id = "audit-unavailable-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :audit, :login_failed],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:audit, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log([level: :error], fn ->
        assert :ok =
                 AuditLog.event(:login_failed,
                   email: "unavailable@example.com",
                   password: "hunter2"
                 )
      end)

    assert_receive {:audit, %{email: "unavailable@example.com"}}
    assert log =~ "security_audit_persist_failed"
    assert log =~ "DBConnection.OwnershipError"
    refute log =~ "hunter2"
    refute log =~ "unavailable@example.com"
  end
end
