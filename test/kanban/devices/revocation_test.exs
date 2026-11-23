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

  test "reasons/0 lists the five reasons" do
    assert Revocation.reasons() == [
             :sign_out,
             :user,
             :org_admin,
             :reuse_detected,
             :password_changed
           ]
  end

  describe "revoke_all_locked/3" do
    test "revokes every live device of the user, in id order, and expires its tokens", %{
      scope: scope
    } do
      {first, _issued} = device_with_tokens_fixture(scope, %{}, @t0)
      {second, _issued} = device_with_tokens_fixture(scope, %{name: "Second"}, @t0)
      other = device_fixture(user_scope_fixture(), %{}, @t0)
      now = DateTime.add(@t0, 60)

      assert {:ok, revoked} = Revocation.revoke_all_locked(scope.user, scope.user.id, now)
      assert Enum.map(revoked, & &1.id) == [first.id, second.id]

      for device <- revoked do
        assert device.revoked_at == now
        assert device.revoked_by_id == scope.user.id
        assert live_token_count(device) == 0
      end

      assert is_nil(Repo.get!(Device, other.id).revoked_at)
    end

    test "leaves an already revoked device as it is", %{scope: scope} do
      {:ok, {:revoked, gone}} =
        scope |> device_fixture(%{}, @t0) |> Revocation.revoke_locked(nil, @t0)

      live = device_fixture(scope, %{name: "Live"}, @t0)
      now = DateTime.add(@t0, 60)

      assert {:ok, [%Device{id: id}]} =
               Revocation.revoke_all_locked(scope.user, scope.user.id, now)

      assert id == live.id
      assert Repo.get!(Device, gone.id).revoked_at == @t0
      assert is_nil(Repo.get!(Device, gone.id).revoked_by_id)
    end

    test "revokes nothing for a user with no live device", %{scope: scope} do
      assert Revocation.revoke_all_locked(scope.user, scope.user.id, @t0) == {:ok, []}
    end
  end

  test "announce_all/2 announces each device it is given", %{scope: scope} do
    first = device_fixture(scope, %{}, @t0)
    second = device_fixture(scope, %{name: "Second"}, @t0)
    Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(first.id))
    Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(second.id))
    details = [owner: scope.user, user_id: scope.user.id, reason: :password_changed]

    assert Revocation.announce_all([], details) == :ok
    refute_receive {:telemetry_event, _, _, _}

    assert Revocation.announce_all([first, second], details) == :ok

    for device <- [first, second] do
      topic = Revocation.topic(device.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                    %{reason: :password_changed}}

    assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                    %{reason: :password_changed}}

    ids =
      AuditLog.list_events(action: "device_revoked")
      |> Enum.filter(&(&1.metadata["reason"] == "password_changed"))
      |> Enum.map(& &1.metadata["device_id"])

    assert Enum.sort(ids) == Enum.sort([first.id, second.id])
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

  defp live_token_count(device) do
    query =
      from(t in Kanban.Devices.DeviceToken,
        where: t.device_id == ^device.id and t.expires_at > ^device.revoked_at
      )

    Repo.aggregate(query, :count)
  end
end
