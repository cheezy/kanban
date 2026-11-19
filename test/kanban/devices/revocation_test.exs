defmodule Kanban.Devices.RevocationTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation

  @t0 ~U[2026-11-18 12:00:00Z]

  setup do
    attach_telemetry([:kanban, :device, :revoked])
    %{scope: user_scope_fixture()}
  end

  test "topic/1 names the device's PubSub topic" do
    assert Revocation.topic(42) == "device:42"
  end

  test "reasons/0 lists the four reasons" do
    assert Revocation.reasons() == [:sign_out, :user, :org_admin, :reuse_detected]
  end

  test "revoke_locked/3 is not found for a missing row and unchanged for a revoked one", %{
    scope: scope
  } do
    assert Revocation.revoke_locked(nil, nil, @t0) == {:error, :not_found}

    device = device_fixture(scope, %{}, @t0)
    assert {:ok, {:revoked, revoked}} = Revocation.revoke_locked(device, nil, @t0)
    assert revoked.revoked_at == @t0
    assert is_nil(revoked.revoked_by_id)

    assert {:ok, {:unchanged, ^revoked}} =
             Revocation.revoke_locked(revoked, scope.user.id, DateTime.add(@t0, 5))
  end

  test "announce/2 announces a revocation and nothing else", %{scope: scope} do
    device = device_fixture(scope, %{}, @t0)
    Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))
    details = [owner: scope.user, user_id: nil, reason: :org_admin]

    assert Revocation.announce({:error, :not_found}, details) == {:error, :not_found}
    assert Revocation.announce({:ok, {:unchanged, device}}, details) == {:ok, device}
    refute_receive %Phoenix.Socket.Broadcast{}
    refute_receive {:telemetry_event, _, _, _}

    assert {:ok, %Device{}} = Revocation.announce({:ok, {:revoked, device}}, details)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert_receive {:telemetry_event, [:kanban, :device, :revoked], _, %{reason: :org_admin}}

    assert [event] =
             AuditLog.list_events(action: "device_revoked")
             |> Enum.filter(&(&1.metadata["device_id"] == device.id))

    assert event.metadata["device_user_id"] == scope.user.id
    assert is_nil(event.actor_user_id)
  end

  test "announce/2 refuses an unknown reason", %{scope: scope} do
    device = device_fixture(scope, %{}, @t0)

    assert_raise ArgumentError, fn ->
      Revocation.announce({:ok, device}, owner: scope.user, reason: :because)
    end
  end
end
