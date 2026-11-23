defmodule Kanban.Accounts.DeviceSignOutTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.DeviceSignOut
  alias Kanban.Devices
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.AuthorizationCodes
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation

  setup do
    attach_telemetry([:kanban, :device, :revoked])
    %{scope: user_scope_fixture()}
  end

  describe "Devices.revoke_all_for_password_change/2" do
    test "revokes every live device of the user by the user, at a whole second", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope)
      now = :microsecond |> DateTime.utc_now() |> DateTime.add(1)

      assert {:ok, [%Device{} = revoked]} =
               Devices.revoke_all_for_password_change(scope.user, now)

      assert revoked.id == device.id
      assert revoked.revoked_at == DateTime.truncate(now, :second)
      assert revoked.revoked_by_id == scope.user.id
      assert {:error, :invalid_token} = Devices.fetch_by_access_token(issued.access_token, now)
      assert {:error, :invalid_token} = Devices.rotate_refresh_token(issued.refresh_token, now)
    end
  end

  describe "AuthorizationCodes.expire_unused/2" do
    test "expires the user's unused codes and leaves used, expired and other users' codes",
         %{scope: scope} do
      now = DateTime.utc_now(:second)
      unused = authorization_code_fixture(scope)
      used = authorization_code_fixture(scope)
      {:ok, used} = Devices.consume_authorization_code(used.code, used.client_id)
      expired = authorization_code_fixture(scope, %{}, DateTime.add(now, -120, :second))
      other = authorization_code_fixture(user_scope_fixture())

      assert AuthorizationCodes.expire_unused(scope.user, now) == :ok

      assert Repo.get!(AuthorizationCode, unused.id).expires_at == unused.inserted_at
      assert Repo.get!(AuthorizationCode, used.id).expires_at == used.expires_at
      assert Repo.get!(AuthorizationCode, used.id).used_at == used.used_at
      assert Repo.get!(AuthorizationCode, expired.id).expires_at == expired.expires_at
      assert Repo.get!(AuthorizationCode, other.id).expires_at == other.expires_at

      assert {:error, :invalid_grant} =
               Devices.consume_authorization_code(unused.code, unused.client_id, now)
    end
  end

  describe "AuthorizationCodes.expire_unused/2 and an earlier clock" do
    test "a code expired at a change is refused by a redemption whose clock reads earlier",
         %{scope: scope} do
      issued_at = DateTime.utc_now(:second)
      code = authorization_code_fixture(scope, %{}, issued_at)

      assert AuthorizationCodes.expire_unused(scope.user, DateTime.add(issued_at, 10)) == :ok

      assert {:error, :invalid_grant} =
               Devices.consume_authorization_code(
                 code.code,
                 code.client_id,
                 DateTime.add(issued_at, 5)
               )
    end
  end

  describe "AuthorizationCodes.create/4 after a password change" do
    test "refuses a code for a scope loaded before the change and issues one after it",
         %{scope: scope} do
      assert {:ok, {_user, _tokens}} =
               Kanban.Accounts.update_user_password(scope.user, %{
                 password: "a new valid password"
               })

      assert {:error, %Ecto.Changeset{errors: [user_id: _]}} =
               Devices.create_authorization_code(scope, valid_authorization_code_attributes())

      refute Repo.get_by(AuthorizationCode, user_id: scope.user.id)

      fresh = scope.user.id |> Kanban.Accounts.get_user!() |> Kanban.Accounts.Scope.for_user()

      assert {:ok, %AuthorizationCode{}} =
               Devices.create_authorization_code(fresh, valid_authorization_code_attributes())
    end
  end

  describe "Devices.revoke_all_for_password_change/2 and authorization codes" do
    test "expires the user's unused codes before it revokes", %{scope: scope} do
      code = authorization_code_fixture(scope)

      assert {:ok, []} = Devices.revoke_all_for_password_change(scope.user)
      assert {:error, :invalid_grant} = redeem_authorization_code(code)
    end
  end

  describe "Devices.announce_password_changed/2" do
    test "announces each device with reason :password_changed", %{scope: scope} do
      device = device_fixture(scope)
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      assert Devices.announce_password_changed(scope.user, [device]) == :ok
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                      %{reason: :password_changed}}
    end
  end

  describe "revoke!/1" do
    test "returns the revoked devices inside a transaction", %{scope: scope} do
      device = device_fixture(scope)

      assert {:ok, [%Device{id: id}]} =
               Repo.transact(fn -> {:ok, DeviceSignOut.revoke!(scope.user)} end)

      assert id == device.id
      assert Repo.get!(Device, device.id).revoked_at
    end
  end

  describe "announce/1" do
    test "announces the devices and drops them from the result", %{scope: scope} do
      device = device_fixture(scope)
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      assert DeviceSignOut.announce({:ok, {scope.user, [:token], [device]}}) ==
               {:ok, {scope.user, [:token]}}

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "passes an error through and announces nothing" do
      assert DeviceSignOut.announce({:error, :user_disabled}) == {:error, :user_disabled}
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
    end
  end
end
