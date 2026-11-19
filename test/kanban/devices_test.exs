defmodule Kanban.DevicesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Revocation
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy

  @t0 ~U[2026-11-18 12:00:00Z]

  setup do
    %{scope: user_scope_fixture()}
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)
  defp days(n), do: DateTime.add(@t0, n, :day)

  defp token_row(plain), do: Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(plain))

  defp disable(user) do
    user
    |> User.disabled_changeset(@t0)
    |> Repo.update!()
  end

  describe "create_device/3 and issue_tokens/2" do
    test "creates a device and issues an access and a refresh token", %{scope: scope} do
      {:ok, device} = Devices.create_device(scope, valid_device_attributes(), @t0)

      assert device.user_id == scope.user.id
      assert device.platform == :ios
      assert device.device_class == :phone
      assert device.inserted_at == @t0
      assert is_nil(device.revoked_at)

      {:ok, issued} = Devices.issue_tokens(device, @t0)

      assert "sdat_" <> _ = issued.access_token
      assert "sdrt_" <> _ = issued.refresh_token
      assert issued.access_token_expires_at == at(3600)
      assert issued.refresh_token_expires_at == days(30)

      access = token_row(issued.access_token)
      refresh = token_row(issued.refresh_token)

      assert access.kind == :access
      assert refresh.kind == :refresh
      assert access.family_id == refresh.family_id
      assert access.device_id == device.id
      assert access.inserted_at == @t0

      # Only hashes are stored: the plain value is in no column, and a loaded
      # row's inspect output shows neither the plain value nor the hash.
      assert access.token_hash == DeviceToken.hash_token(issued.access_token)
      assert is_nil(access.token)
      refute inspect(access) =~ issued.access_token
      refute inspect(access) =~ access.token_hash

      %{rows: rows} = Repo.query!("SELECT * FROM device_tokens WHERE device_id = $1", [device.id])
      refute rows |> List.flatten() |> Enum.member?(issued.refresh_token)
    end

    test "each sign-in starts a new token family", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      {:ok, first} = Devices.issue_tokens(device, @t0)
      {:ok, second} = Devices.issue_tokens(device, @t0)

      refute token_row(first.refresh_token).family_id == token_row(second.refresh_token).family_id
    end

    test "rejects invalid device attributes", %{scope: scope} do
      long_name = String.duplicate("a", 256)

      attrs = %{client_id: "other-app", platform: "windows", name: long_name}
      {:error, changeset} = Devices.create_device(scope, valid_device_attributes(attrs), @t0)

      assert "is invalid" in errors_on(changeset).client_id
      assert "is invalid" in errors_on(changeset).platform
      assert "should be at most 255 character(s)" in errors_on(changeset).name

      {:error, changeset} =
        Devices.create_device(scope, valid_device_attributes(%{name: " "}), @t0)

      assert "can't be blank" in errors_on(changeset).name
    end

    test "many devices may have a null push_token", %{scope: scope} do
      first = device_fixture(scope, %{push_token: nil}, @t0)
      second = device_fixture(scope, %{push_token: nil}, @t0)

      assert is_nil(first.push_token)
      assert is_nil(second.push_token)
    end

    test "a second device with the same push_token is refused", %{scope: scope} do
      device_fixture(scope, %{push_token: "fixture-push-token-1"}, @t0)
      other_scope = user_scope_fixture()

      {:error, changeset} =
        Devices.create_device(
          other_scope,
          valid_device_attributes(%{push_token: "fixture-push-token-1"}),
          @t0
        )

      assert "has already been taken" in errors_on(changeset).push_token
    end

    test "refuses to issue tokens for a revoked device", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      {:ok, _revoked} = Devices.revoke_device(scope, device, @t0)

      assert Devices.issue_tokens(device, at(1)) == {:error, :revoked}
    end
  end

  describe "issue_tokens/2 at the 90-day limit" do
    test "refuses to issue tokens once the device is 90 days past sign-in", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)

      assert {:ok, issued} = Devices.issue_tokens(device, DateTime.add(days(90), -1, :second))
      assert issued.refresh_token_expires_at == days(90)

      assert Devices.issue_tokens(device, days(90)) == {:error, :expired}
      assert Devices.issue_tokens(device, days(91)) == {:error, :expired}
    end
  end

  describe "Activity.signed_in?/1" do
    test "is true for a live device of an active user", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)

      assert Devices.Activity.signed_in?(device)
    end

    test "is false once the device is revoked", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      {:ok, _revoked} = Devices.revoke_device(scope, device, at(5))

      refute Devices.Activity.signed_in?(device)
    end

    test "is false once the device's user is disabled", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      scope.user |> User.disabled_changeset(at(5)) |> Repo.update!()

      refute Devices.Activity.signed_in?(device)
    end

    test "is false for a device that no longer exists", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      Repo.delete!(device)

      refute Devices.Activity.signed_in?(device)
    end
  end

  describe "touch_last_seen/2" do
    test "sets last_seen_at, truncated to the second", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      assert is_nil(device.last_seen_at)

      touched = Devices.touch_last_seen(device, DateTime.add(at(5), 750_000, :microsecond))

      assert touched.last_seen_at == at(5)
      assert Repo.get!(Device, device.id).last_seen_at == at(5)
    end

    test "never moves last_seen_at backwards", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      later = Devices.touch_last_seen(device, at(60))

      assert Devices.touch_last_seen(later, at(30)).last_seen_at == at(60)
      assert Devices.touch_last_seen(device, at(30)).last_seen_at == at(60)
      assert Repo.get!(Device, device.id).last_seen_at == at(60)

      assert Devices.touch_last_seen(later, at(60)).last_seen_at == at(60)
      assert Devices.touch_last_seen(later, at(90)).last_seen_at == at(90)
      assert Repo.get!(Device, device.id).last_seen_at == at(90)
    end

    test "touches only the given device", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      other = device_fixture(scope, %{name: "Other"}, @t0)

      Devices.touch_last_seen(device, at(10))

      assert is_nil(Repo.get!(Device, other.id).last_seen_at)
    end

    test "returns the device unchanged in the database when its row is gone", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      Repo.delete!(device)

      assert Devices.touch_last_seen(device, at(10)).last_seen_at == at(10)
      refute Repo.get(Device, device.id)
    end
  end

  describe "fetch_by_access_token/2" do
    test "finds a device by access token hash and refuses an expired token", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

      assert {:ok, found} = Devices.fetch_by_access_token(issued.access_token, @t0)
      assert found.id == device.id
      assert found.user.id == scope.user.id

      assert {:ok, _} = Devices.fetch_by_access_token(issued.access_token, at(3599))

      # At exactly its expiry second the token is refused.
      assert Devices.fetch_by_access_token(issued.access_token, at(3600)) ==
               {:error, :invalid_token}

      assert Devices.fetch_by_access_token(issued.access_token, at(3601)) ==
               {:error, :invalid_token}
    end

    test "refuses unknown, malformed and refresh tokens", %{scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope, %{}, @t0)
      unknown = DeviceToken.generate("sdat")

      for token <- [unknown, issued.refresh_token, "", nil, 42] do
        assert Devices.fetch_by_access_token(token, @t0) == {:error, :invalid_token}
      end
    end

    test "refuses a token of a revoked device or a disabled user", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{}, @t0)
      device |> Device.revoke_changeset(nil, @t0) |> Repo.update!()

      assert Devices.fetch_by_access_token(issued.access_token, @t0) == {:error, :invalid_token}

      other_scope = user_scope_fixture()
      {_device, other} = device_with_tokens_fixture(other_scope, %{}, @t0)
      disable(other_scope.user)

      assert Devices.fetch_by_access_token(other.access_token, @t0) == {:error, :invalid_token}
    end
  end

  describe "rotate_refresh_token/2" do
    test "rotates the refresh token and refuses the old one", %{scope: scope} do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)

      {:ok, second} = Devices.rotate_refresh_token(first.refresh_token, at(60))

      refute second.refresh_token == first.refresh_token
      refute second.access_token == first.access_token
      assert second.device.id == device.id
      assert second.access_token_expires_at == at(60 + 3600)
      assert second.refresh_token_expires_at == 60 |> at() |> DateTime.add(30, :day)

      old = token_row(first.refresh_token)
      new = token_row(second.refresh_token)
      assert old.used_at == at(60)
      assert new.family_id == old.family_id
      assert is_nil(new.used_at)

      assert {:ok, _} = Devices.fetch_by_access_token(second.access_token, at(61))
      refute match?({:ok, _}, Devices.rotate_refresh_token(first.refresh_token, at(62)))
    end

    test "reusing an old refresh token revokes the family and the device", %{scope: scope} do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, second} = Devices.rotate_refresh_token(first.refresh_token, at(60))

      assert Devices.rotate_refresh_token(first.refresh_token, at(120)) ==
               {:error, :reuse_detected}

      # The revocation committed although the call failed.
      revoked = Repo.get!(Device, device.id)
      assert revoked.revoked_at == at(120)
      assert is_nil(revoked.revoked_by_id)

      family_id = token_row(first.refresh_token).family_id
      family = DeviceToken |> where([t], t.family_id == ^family_id) |> Repo.all()

      assert length(family) == 4
      assert Enum.all?(family, &(DateTime.compare(&1.expires_at, at(120)) != :gt))

      assert Devices.rotate_refresh_token(second.refresh_token, at(121)) ==
               {:error, :invalid_token}

      assert Devices.fetch_by_access_token(second.access_token, at(121)) ==
               {:error, :invalid_token}

      assert Devices.fetch_by_access_token(first.access_token, at(121)) ==
               {:error, :invalid_token}

      # Presenting the stolen token again is refused without raising.
      assert Devices.rotate_refresh_token(first.refresh_token, at(122)) ==
               {:error, :invalid_token}
    end

    test "reuse after the used token has expired still revokes the device", %{scope: scope} do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, _second} = Devices.rotate_refresh_token(first.refresh_token, at(60))

      assert Devices.rotate_refresh_token(first.refresh_token, days(31)) ==
               {:error, :reuse_detected}

      assert Repo.get!(Device, device.id).revoked_at == days(31)
    end

    test "refresh expires after 30 days unused and 90 days after sign-in", %{scope: scope} do
      {_device, fresh} = device_with_tokens_fixture(scope, %{}, @t0)
      thirty_days = 30 * 24 * 3600
      assert {:ok, _} = Devices.rotate_refresh_token(fresh.refresh_token, at(thirty_days - 1))

      {_device, idle} = device_with_tokens_fixture(scope, %{}, @t0)

      assert Devices.rotate_refresh_token(idle.refresh_token, days(30)) ==
               {:error, :invalid_token}

      {_device, chained} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, r29} = Devices.rotate_refresh_token(chained.refresh_token, days(29))
      {:ok, r58} = Devices.rotate_refresh_token(r29.refresh_token, days(58))
      {:ok, r87} = Devices.rotate_refresh_token(r58.refresh_token, days(87))

      # 30 days after day 87 would be day 117: capped at 90 days after sign-in.
      assert r87.refresh_token_expires_at == days(90)
      assert Devices.rotate_refresh_token(r87.refresh_token, days(90)) == {:error, :invalid_token}

      ninety_days = 90 * 24 * 3600
      {:ok, last} = Devices.rotate_refresh_token(r87.refresh_token, at(ninety_days - 1))
      assert last.refresh_token_expires_at == days(90)

      assert Devices.rotate_refresh_token(last.refresh_token, days(90)) ==
               {:error, :invalid_token}
    end

    test "refuses unknown, malformed and access tokens", %{scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope, %{}, @t0)
      unknown = DeviceToken.generate("sdrt")

      for token <- [unknown, issued.access_token, "", nil, 42] do
        assert Devices.rotate_refresh_token(token, @t0) == {:error, :invalid_token}
      end

      assert is_nil(token_row(issued.refresh_token).used_at)
    end

    test "refuses a disabled user and a revoked device without using the token", %{scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope, %{}, @t0)
      disable(scope.user)

      assert Devices.rotate_refresh_token(issued.refresh_token, at(1)) == {:error, :invalid_token}
      assert is_nil(token_row(issued.refresh_token).used_at)

      other_scope = user_scope_fixture()
      {device, other} = device_with_tokens_fixture(other_scope, %{}, @t0)
      device |> Device.revoke_changeset(nil, @t0) |> Repo.update!()

      assert Devices.rotate_refresh_token(other.refresh_token, at(1)) == {:error, :invalid_token}
    end

    test "an unused token presented by another client is refused and stays usable", %{
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope, %{client_id: "stride-ios"}, @t0)

      assert Devices.rotate_refresh_token(issued.refresh_token, at(1),
               client_id: "stride-android"
             ) ==
               {:error, :invalid_token}

      assert is_nil(token_row(issued.refresh_token).used_at)
      assert is_nil(Repo.get!(Device, device.id).revoked_at)

      assert {:ok, _rotated} =
               Devices.rotate_refresh_token(issued.refresh_token, at(2), client_id: "stride-ios")
    end

    test "a used token replayed while its user is disabled still revokes the device", %{
      scope: scope
    } do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, _second} = Devices.rotate_refresh_token(first.refresh_token, at(60))
      disable(scope.user)

      assert Devices.rotate_refresh_token(first.refresh_token, at(120)) ==
               {:error, :reuse_detected}

      assert Repo.get!(Device, device.id).revoked_at == at(120)

      assert [_event] =
               AuditLog.list_events(
                 action: "device_refresh_reuse_detected",
                 actor_user_id: scope.user.id
               )
    end
  end

  describe "revoke_device/3 and list_devices/1" do
    test "revoking a device stamps revoked_at and revoked_by_id and kills its tokens",
         %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

      {:ok, revoked} = Devices.revoke_device(scope, device, at(10))

      assert revoked.revoked_at == at(10)
      assert revoked.revoked_by_id == scope.user.id
      assert Device.revoked?(revoked)

      assert Devices.fetch_by_access_token(issued.access_token, at(11)) ==
               {:error, :invalid_token}

      assert Devices.rotate_refresh_token(issued.refresh_token, at(11)) ==
               {:error, :invalid_token}

      tokens = DeviceToken |> where([t], t.device_id == ^device.id) |> Repo.all()
      assert Enum.all?(tokens, &(&1.expires_at == at(10)))

      assert Devices.list_devices(scope) == []

      # Revoking again keeps the first stamp.
      assert {:ok, again} = Devices.revoke_device(scope, device, at(20))
      assert again.revoked_at == at(10)
    end

    test "a revoked device releases its push_token for the next sign-in", %{scope: scope} do
      device = device_fixture(scope, %{push_token: "fixture-push-token-2"}, @t0)
      {:ok, revoked} = Devices.revoke_device(scope, device, at(10))

      assert is_nil(revoked.push_token)
      assert is_nil(Repo.get!(Device, device.id).push_token)

      assert {:ok, again} =
               Devices.create_device(
                 scope,
                 valid_device_attributes(%{push_token: "fixture-push-token-2"}),
                 at(20)
               )

      assert again.push_token == "fixture-push-token-2"
    end

    test "cannot revoke another user's device", %{scope: scope} do
      other_scope = user_scope_fixture()
      {device, issued} = device_with_tokens_fixture(other_scope, %{}, @t0)

      assert Devices.revoke_device(scope, device, at(10)) == {:error, :not_found}
      assert is_nil(Repo.get!(Device, device.id).revoked_at)
      assert {:ok, _} = Devices.fetch_by_access_token(issued.access_token, at(11))
    end

    test "revoking a device that no longer exists is not found", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      Repo.delete!(device)

      assert Devices.revoke_device(scope, device, at(10)) == {:error, :not_found}
    end

    test "lists only the scope user's active devices, newest first", %{scope: scope} do
      older = device_fixture(scope, %{name: "Older"}, @t0)
      newer = device_fixture(scope, %{name: "Newer"}, at(60))
      revoked = device_fixture(scope, %{name: "Revoked"}, at(120))
      {:ok, _} = Devices.revoke_device(scope, revoked, at(180))
      device_fixture(user_scope_fixture(), %{name: "Someone else's"}, @t0)

      assert scope |> Devices.list_devices() |> Enum.map(& &1.id) == [newer.id, older.id]
    end
  end

  describe "W2748: announcing a revocation" do
    setup do
      attach_telemetry([:kanban, :device, :revoked])
      :ok
    end

    defp revoked_rows(user_id),
      do: AuditLog.list_events(action: "device_revoked", actor_user_id: user_id)

    test "revoke_device broadcasts on device:<id> and records the reason", %{scope: scope} do
      org = organization_fixture()
      organization_member_fixture(org, scope.user)
      device = device_fixture(scope, %{}, @t0)
      topic = Revocation.topic(device.id)
      assert topic == "device:#{device.id}"
      Phoenix.PubSub.subscribe(Kanban.PubSub, topic)

      assert {:ok, _} =
               Devices.revoke_device(scope, device, at(10), reason: :sign_out, ip: {10, 0, 0, 3})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], %{count: 1},
                      %{platform: "ios", reason: :sign_out} = metadata}

      assert map_size(metadata) == 2

      assert [event] = revoked_rows(scope.user.id)
      assert event.organization_id == org.id
      assert event.ip == "10.0.0.3"

      assert %{
               "reason" => "sign_out",
               "device_id" => device_id,
               "device_user_id" => owner_id,
               "user_id" => revoker_id
             } = event.metadata

      assert {device_id, owner_id, revoker_id} == {device.id, scope.user.id, scope.user.id}
      refute event.metadata |> Map.keys() |> Enum.any?(&(&1 =~ ~r/token|key|name/))
    end

    test "the reason defaults to user", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)

      assert {:ok, _} = Devices.revoke_device(scope, device, at(10))
      assert [%{metadata: %{"reason" => "user"}}] = revoked_rows(scope.user.id)
    end

    test "a revocation is broadcast to the owner's devices topic", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      :ok = Devices.subscribe_devices(scope)
      other_scope = user_scope_fixture()
      {:ok, _} = Devices.revoke_device(other_scope, device_fixture(other_scope, %{}, @t0))
      refute_receive {:device_revoked, _}

      {:ok, _} = Devices.revoke_device(scope, device, at(10))

      id = device.id
      assert_receive {:device_revoked, ^id}
      assert Revocation.user_topic(scope.user.id) == "user_devices:#{scope.user.id}"
    end

    test "report_unchanged says a device revoked meanwhile was already revoked", %{
      scope: scope
    } do
      stale = device_fixture(scope, %{}, @t0)
      {:ok, _} = Devices.revoke_device(scope, stale, at(10))

      assert {:error, :already_revoked} =
               Devices.revoke_device(scope, stale, at(20), report_unchanged: true)

      assert {:ok, %Device{revoked_at: revoked_at}} = Devices.revoke_device(scope, stale, at(30))
      assert revoked_at == at(10)
      assert [_one] = revoked_rows(scope.user.id)

      live = device_fixture(scope, %{}, @t0)
      assert {:ok, revoked} = Devices.revoke_device(scope, live, at(40), report_unchanged: true)
      assert revoked.revoked_at == at(40)
    end

    test "revoking an already revoked device announces nothing again", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      {:ok, _} = Devices.revoke_device(scope, device, at(10))
      assert_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))
      :ok = Devices.subscribe_devices(scope)

      assert {:ok, again} = Devices.revoke_device(scope, device, at(20), reason: :sign_out)
      assert again.revoked_at == at(10)

      refute_receive %Phoenix.Socket.Broadcast{}
      refute_receive {:device_revoked, _}
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
      assert [_one] = revoked_rows(scope.user.id)
    end

    test "another user's device is not found and announces nothing", %{scope: scope} do
      device = device_fixture(user_scope_fixture(), %{}, @t0)

      assert Devices.revoke_device(scope, device, at(10)) == {:error, :not_found}
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
      assert revoked_rows(scope.user.id) == []
      assert revoked_rows(device.user_id) == []
    end

    # Options where `now` belongs, handed in through the test context so the
    # compiler cannot see the call is bad and refuse to build it.
    @tag misplaced_opts: [reason: :sign_out]
    test "refuses a reason a person cannot give, and options in place of now", %{
      scope: scope,
      misplaced_opts: misplaced_opts
    } do
      device = device_fixture(scope, %{}, @t0)

      for reason <- [:org_admin, :reuse_detected, :bogus, "user"] do
        assert_raise ArgumentError, fn ->
          Devices.revoke_device(scope, device, at(10), reason: reason)
        end
      end

      error =
        assert_raise FunctionClauseError, fn ->
          Devices.revoke_device(scope, device, misplaced_opts)
        end

      assert {error.module, error.function} == {Kanban.Devices, :revoke_device}

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
      assert revoked_rows(scope.user.id) == []
    end

    test "POST /oauth/revoke's revoke_by_refresh_token records reason sign_out", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{platform: :android}, @t0)
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      assert {:ok, _} =
               Devices.revoke_by_refresh_token(issued.refresh_token, at(10), ip: {10, 0, 0, 4})

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                      %{platform: "android", reason: :sign_out}}

      assert [event] = revoked_rows(scope.user.id)
      assert event.metadata["reason"] == "sign_out"
      assert event.ip == "10.0.0.4"

      assert Devices.revoke_by_refresh_token(issued.refresh_token, at(20)) ==
               {:error, :invalid_token}

      assert [_one] = revoked_rows(scope.user.id)
    end

    test "refresh-token reuse records reason reuse_detected and broadcasts", %{scope: scope} do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, _second} = Devices.rotate_refresh_token(first.refresh_token, at(60))
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      assert Devices.rotate_refresh_token(first.refresh_token, at(120), ip: {10, 0, 0, 5}) ==
               {:error, :reuse_detected}

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                      %{reason: :reuse_detected}}

      assert [event] = revoked_rows(scope.user.id)
      assert event.metadata["reason"] == "reuse_detected"
      assert event.metadata["device_id"] == device.id
      assert event.ip == "10.0.0.5"

      # The reuse event is still written beside it.
      assert [_reuse] =
               AuditLog.list_events(
                 action: "device_refresh_reuse_detected",
                 actor_user_id: scope.user.id
               )
    end
  end

  describe "W2748: a revoked requesting device" do
    test "revokes nothing, not another device and not itself", %{scope: scope} do
      phone = device_fixture(scope, %{}, @t0)
      tablet = device_fixture(scope, %{}, @t0)
      {:ok, _} = Devices.revoke_device(scope, phone, at(10))

      assert Devices.revoke_device(scope, tablet, at(20), by_device: phone) ==
               {:error, :revoked}

      assert Devices.revoke_device(scope, phone, at(20), by_device: phone, reason: :sign_out) ==
               {:error, :revoked}

      assert is_nil(Repo.get!(Device, tablet.id).revoked_at)
      assert Repo.get!(Device, phone.id).revoked_at == at(10)
    end

    test "an active requesting device revokes another as before", %{scope: scope} do
      phone = device_fixture(scope, %{}, @t0)
      tablet = device_fixture(scope, %{}, @t0)

      assert {:ok, %Device{revoked_at: revoked_at}} =
               Devices.revoke_device(scope, tablet, at(10), by_device: phone)

      assert revoked_at == at(10)
    end

    test "list_devices_for/2 refuses a revoked device and lists for an active one", %{
      scope: scope
    } do
      phone = device_fixture(scope, %{}, @t0)
      tablet = device_fixture(scope, %{}, @t0)

      assert {:ok, devices} = Devices.list_devices_for(scope, phone)
      assert devices |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([phone.id, tablet.id])

      {:ok, _} = Devices.revoke_device(scope, phone, at(10))
      assert Devices.list_devices_for(scope, phone) == {:error, :revoked}
    end

    test "a push token with a NUL byte is a changeset error, not a crash", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)

      assert {:error, changeset} =
               Devices.update_current(scope, device, %{"push_token" => "tok\u0000en"})

      assert %{push_token: [_ | _]} = errors_on(changeset)
    end
  end

  describe "W2748: fetch_device/2" do
    test "gets one of the scope user's devices, revoked or not", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      {:ok, _} = Devices.revoke_device(scope, device, at(10))
      theirs = device_fixture(user_scope_fixture(), %{}, @t0)

      assert {:ok, %Device{id: id}} = Devices.fetch_device(scope, device.id)
      assert id == device.id
      assert Devices.fetch_device(scope, theirs.id) == {:error, :not_found}
      assert Devices.fetch_device(scope, theirs.id + 1_000_000) == {:error, :not_found}
    end
  end

  describe "W2748: update_current/4" do
    test "updates the fields the app may change and nothing else", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)

      attrs = %{
        "push_token" => "fixture-push-token-u1",
        "push_environment" => "production",
        "locale" => "de_DE",
        "time_zone" => "Asia/Tokyo",
        "app_version" => "2.0.0 (1)",
        "name" => "Renamed",
        "revoked_at" => "2026-11-18T12:00:00Z"
      }

      assert {:ok, updated} = Devices.update_current(scope, device, attrs, at(30))

      assert {updated.push_token, updated.push_environment, updated.locale} ==
               {"fixture-push-token-u1", :production, "de_DE"}

      assert {updated.time_zone, updated.app_version} == {"Asia/Tokyo", "2.0.0 (1)"}
      assert updated.updated_at == at(30)
      assert updated.name == device.name
      assert is_nil(updated.revoked_at)
    end

    test "an empty push token clears it and an absent key is left alone", %{scope: scope} do
      device = device_fixture(scope, %{push_token: "fixture-push-token-u2"}, @t0)

      assert {:ok, updated} = Devices.update_current(scope, device, %{"push_token" => ""}, at(30))
      assert is_nil(updated.push_token)
      assert updated.time_zone == device.time_zone
    end

    test "a push token another of the person's devices holds moves to this one", %{scope: scope} do
      holder = device_fixture(scope, %{push_token: "fixture-push-token-u3"}, @t0)
      device = device_fixture(scope, %{}, @t0)

      assert {:ok, updated} =
               Devices.update_current(scope, device, %{"push_token" => "fixture-push-token-u3"})

      assert updated.push_token == "fixture-push-token-u3"
      assert is_nil(Repo.get!(Device, holder.id).push_token)
    end

    test "a push token another person's device holds is refused and stays put", %{scope: scope} do
      holder = device_fixture(user_scope_fixture(), %{push_token: "fixture-push-token-u6"}, @t0)
      device = device_fixture(scope, %{locale: "en"}, @t0)
      attrs = %{"push_token" => "fixture-push-token-u6", "locale" => "de"}

      assert {:error, changeset} = Devices.update_current(scope, device, attrs, at(30))
      assert "has already been taken" in errors_on(changeset).push_token

      assert Repo.get!(Device, holder.id).push_token == "fixture-push-token-u6"
      stored = Repo.get!(Device, device.id)
      assert is_nil(stored.push_token)
      assert stored.locale == "en"
    end

    test "an invalid field is a changeset and moves no token", %{scope: scope} do
      holder = device_fixture(scope, %{push_token: "fixture-push-token-u5"}, @t0)
      device = device_fixture(scope, %{}, @t0)

      attrs = %{"push_token" => "fixture-push-token-u5", "time_zone" => "Not/AZone"}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Devices.update_current(scope, device, attrs)

      assert %{time_zone: [_]} = errors_on(changeset)
      assert Repo.get!(Device, holder.id).push_token == "fixture-push-token-u5"

      assert {:error, changeset} =
               Devices.update_current(scope, device, %{"push_environment" => "staging"})

      assert %{push_environment: [_]} = errors_on(changeset)

      long = String.duplicate("a", 4097)
      assert {:error, changeset} = Devices.update_current(scope, device, %{"push_token" => long})
      assert %{push_token: [_]} = errors_on(changeset)
    end

    test "a device revoked while the request was in flight is refused", %{scope: scope} do
      device = device_fixture(scope, %{}, @t0)
      # The caller still holds the struct the plug loaded before the revoke.
      {:ok, _} = Devices.revoke_device(scope, device, at(10))

      assert Devices.update_current(scope, device, %{"time_zone" => "Asia/Tokyo"}, at(20)) ==
               {:error, :revoked}

      assert Repo.get!(Device, device.id).time_zone == device.time_zone
    end

    test "another user's device, or a deleted one, is not found", %{scope: scope} do
      theirs = device_fixture(user_scope_fixture(), %{}, @t0)
      assert Devices.update_current(scope, theirs, %{"locale" => "fr"}) == {:error, :not_found}

      mine = device_fixture(scope, %{}, @t0)
      Repo.delete!(mine)
      assert Devices.update_current(scope, mine, %{"locale" => "fr"}) == {:error, :not_found}
    end
  end

  describe "authorization codes" do
    test "an authorization code is single-use and expires after 60 seconds", %{scope: scope} do
      {:ok, code} =
        Devices.create_authorization_code(scope, valid_authorization_code_attributes(), @t0)

      assert "sdac_" <> _ = code.code
      assert code.code_hash == DeviceToken.hash_token(code.code)
      assert code.expires_at == at(60)
      assert code.inserted_at == @t0
      refute inspect(code) =~ code.code

      stored = Repo.get!(AuthorizationCode, code.id)
      assert is_nil(stored.code)

      assert {:ok, consumed} = Devices.consume_authorization_code(code.code, "stride-ios", at(59))
      assert consumed.id == code.id
      assert consumed.used_at == at(59)
      assert consumed.user.id == scope.user.id
      assert consumed.code_challenge == valid_code_challenge()

      assert Devices.consume_authorization_code(code.code, "stride-ios", at(59)) ==
               {:error, :invalid_grant}

      late = authorization_code_fixture(scope, %{}, @t0)

      assert Devices.consume_authorization_code(late.code, "stride-ios", at(60)) ==
               {:error, :invalid_grant}
    end

    test "a code is refused for another client and stays usable", %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)

      assert Devices.consume_authorization_code(code.code, "stride-android", at(1)) ==
               {:error, :invalid_grant}

      assert {:ok, _} = Devices.consume_authorization_code(code.code, "stride-ios", at(2))
    end

    test "unknown and malformed codes, and a disabled user's code, are refused",
         %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)
      unknown = DeviceToken.generate("sdac")

      for {value, client} <- [{unknown, "stride-ios"}, {nil, "stride-ios"}, {code.code, nil}] do
        assert Devices.consume_authorization_code(value, client, at(1)) ==
                 {:error, :invalid_grant}
      end

      disable(scope.user)

      assert Devices.consume_authorization_code(code.code, "stride-ios", at(1)) ==
               {:error, :invalid_grant}
    end

    test "rejects invalid code attributes", %{scope: scope} do
      attrs = %{client_id: "other-app", code_challenge: "too-short", device_name: nil}

      {:error, changeset} =
        Devices.create_authorization_code(
          scope,
          valid_authorization_code_attributes(attrs),
          @t0
        )

      assert "is invalid" in errors_on(changeset).client_id
      assert "has invalid format" in errors_on(changeset).code_challenge
      assert "can't be blank" in errors_on(changeset).device_name
    end
  end

  describe "the default clock" do
    test "every function defaults to the current time", %{scope: scope} do
      {:ok, device} = Devices.create_device(scope, valid_device_attributes())
      assert DateTime.diff(DateTime.utc_now(), device.inserted_at) in 0..5

      {:ok, issued} = Devices.issue_tokens(device)
      assert {:ok, _} = Devices.fetch_by_access_token(issued.access_token)
      assert {:ok, rotated} = Devices.rotate_refresh_token(issued.refresh_token)

      {:ok, code} =
        Devices.create_authorization_code(scope, valid_authorization_code_attributes())

      assert {:ok, _} = Devices.consume_authorization_code(code.code, "stride-ios")

      assert {:ok, %Device{revoked_at: %DateTime{}}} =
               Devices.revoke_device(scope, rotated.device)
    end
  end

  describe "user deletion" do
    test "deleting the user deletes devices, tokens and codes", %{scope: scope} do
      {device, _issued} = device_with_tokens_fixture(scope, %{}, @t0)
      code = authorization_code_fixture(scope, %{}, @t0)

      # A device of another user that this user revoked survives, with the
      # revoker cleared.
      other_scope = user_scope_fixture()
      other_device = device_fixture(other_scope, %{}, @t0)
      other_device |> Device.revoke_changeset(scope.user.id, @t0) |> Repo.update!()

      Repo.delete!(scope.user)

      assert is_nil(Repo.get(Device, device.id))
      assert DeviceToken |> where([t], t.device_id == ^device.id) |> Repo.all() == []
      assert is_nil(Repo.get(AuthorizationCode, code.id))

      survivor = Repo.get!(Device, other_device.id)
      assert survivor.revoked_at == @t0
      assert is_nil(survivor.revoked_by_id)
    end
  end

  describe "refresh refusals" do
    @overdue_since_days 30

    defp overdue_member_scope do
      org = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(org, admin, :org_admin)
      scope = user_scope_fixture()
      organization_member_fixture(org, scope.user)
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      {org, scope}
    end

    defp backdate_requirement(org, since) do
      from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      |> Repo.update_all(set: [two_factor_enforced_at: since])

      from(m in OrganizationMember, where: m.organization_id == ^org.id)
      |> Repo.update_all(set: [inserted_at: since])
    end

    test "refresh is refused for a disabled user, a revoked device or a missing required two-factor",
         %{scope: scope} do
      {_device, disabled} = device_with_tokens_fixture(scope, %{}, @t0)
      disable(scope.user)

      assert Devices.rotate_refresh_token(disabled.refresh_token, at(1)) ==
               {:error, :invalid_token}

      assert is_nil(token_row(disabled.refresh_token).used_at)

      revoked_scope = user_scope_fixture()
      {device, revoked} = device_with_tokens_fixture(revoked_scope, %{}, @t0)
      {:ok, _} = Devices.revoke_device(revoked_scope, device, @t0)

      assert Devices.rotate_refresh_token(revoked.refresh_token, at(1)) ==
               {:error, :invalid_token}

      {org, member_scope} = overdue_member_scope()
      backdate_requirement(org, days(-@overdue_since_days))
      {member_device, overdue} = device_with_tokens_fixture(member_scope, %{}, @t0)

      assert Devices.rotate_refresh_token(overdue.refresh_token, at(1)) ==
               {:error, :invalid_token}

      # Refused without being used up, and without revoking the device: the
      # member can refresh again once two-factor is on.
      assert is_nil(token_row(overdue.refresh_token).used_at)
      assert is_nil(Repo.get!(Device, member_device.id).revoked_at)
    end

    test "a member still in the two-factor grace period can refresh" do
      {org, scope} = overdue_member_scope()
      backdate_requirement(org, @t0)
      {_device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

      assert {:ok, _rotated} = Devices.rotate_refresh_token(issued.refresh_token, at(60))
    end

    test "reuse writes device_refresh_reuse_detected with the device and no token", %{
      scope: scope
    } do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, _second} = Devices.rotate_refresh_token(first.refresh_token, at(60))

      assert Devices.rotate_refresh_token(first.refresh_token, at(120), ip: {10, 0, 0, 7}) ==
               {:error, :reuse_detected}

      assert [event] =
               AuditLog.list_events(
                 action: "device_refresh_reuse_detected",
                 actor_user_id: scope.user.id
               )

      assert event.actor_user_id == scope.user.id
      assert event.metadata["device_id"] == device.id
      assert event.ip == "10.0.0.7"
      refute event.metadata |> Map.keys() |> Enum.any?(&String.contains?(&1, "token"))
    end
  end

  describe "exchange_authorization_code/4" do
    defp details(overrides \\ %{}) do
      Map.merge(
        %{
          "platform" => "ios",
          "device_class" => "tablet",
          "model" => "iPad14,1",
          "os_version" => "18.1",
          "app_version" => "1.2.0 (7)",
          "locale" => "fr-FR",
          "time_zone" => "Europe/Paris",
          "approval_public_key" => valid_approval_public_key()
        },
        overrides
      )
    end

    # Redeems `code` at `seconds` past @t0. `opts` may override the grant
    # (`:grant`), replace the details (`:details`) and pass `:ip`.
    defp redeem(code, seconds, opts \\ []) do
      grant =
        Map.merge(
          %{
            code: code.code,
            client_id: code.client_id,
            redirect_uri: code.redirect_uri,
            code_verifier: valid_code_verifier()
          },
          Keyword.get(opts, :grant, %{})
        )

      device_details = Keyword.get_lazy(opts, :details, &details/0)
      now = at(seconds)

      Devices.exchange_authorization_code(grant, device_details, now, Keyword.take(opts, [:ip]))
    end

    defp metadata_keys(event), do: Map.keys(event.metadata)

    test "creates the device from the code and the details, and issues tokens", %{scope: scope} do
      code = authorization_code_fixture(scope, %{device_name: "Kitchen iPad"}, @t0)
      key = valid_approval_public_key()
      with_key = details(%{"approval_public_key" => key})

      assert {:ok, issued} = redeem(code, 5, details: with_key)

      device = Repo.get!(Device, issued.device.id)
      assert device.user_id == scope.user.id
      assert device.name == "Kitchen iPad"
      assert device.client_id == "stride-ios"
      assert device.platform == :ios
      assert device.device_class == :tablet
      assert device.approval_public_key == key
      assert device.inserted_at == at(5)
      assert issued.access_token_expires_at == at(5 + 3600)

      assert {:ok, %Device{id: id}} = Devices.fetch_by_access_token(issued.access_token, at(6))
      assert id == device.id
      assert {:ok, _rotated} = Devices.rotate_refresh_token(issued.refresh_token, at(7))
    end

    test "refuses a PKCE mismatch, a wrong redirect URI, a reused or expired code", %{
      scope: scope
    } do
      mismatch = authorization_code_fixture(scope, %{}, @t0)
      wrong = String.duplicate("a", 43)

      assert redeem(mismatch, 1, grant: %{code_verifier: wrong}) == {:error, :invalid_grant}

      # The failed attempt used the code up, so the right verifier is too late.
      assert redeem(mismatch, 2) == {:error, :invalid_grant}

      redirect = authorization_code_fixture(scope, %{}, @t0)
      other_uri = %{redirect_uri: "com.stridelikeaboss.app:/other"}
      assert redeem(redirect, 1, grant: other_uri) == {:error, :invalid_grant}

      reused = authorization_code_fixture(scope, %{}, @t0)
      assert {:ok, _issued} = redeem(reused, 1)
      assert redeem(reused, 2) == {:error, :invalid_grant}

      expired = authorization_code_fixture(scope, %{}, @t0)
      assert redeem(expired, 60) == {:error, :invalid_grant}

      assert Repo.aggregate(Device, :count) == 1
    end

    test "invalid details are refused before the code is used", %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)
      long_model = String.duplicate("m", 256)
      valid = details()

      for bad <- [
            Map.delete(valid, "platform"),
            Map.delete(valid, "approval_public_key"),
            details(%{"device_class" => "watch"}),
            details(%{"approval_public_key" => "fixture-public-key"}),
            details(%{"model" => long_model})
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} = redeem(code, 1, details: bad)
      end

      assert {:ok, _issued} = redeem(code, 2)
    end

    test "an unknown, padded or invented time zone and a malformed locale are refused", %{
      scope: scope
    } do
      code = authorization_code_fixture(scope, %{}, @t0)

      for {field, value} <- [
            {"time_zone", "Mars/Olympus_Mons"},
            {"time_zone", " Europe/London "},
            {"time_zone", "europe/london"},
            {"time_zone", "UTC+99"},
            {"locale", "zz-NOT_A-LOCALE!!"},
            {"locale", "en-GB "},
            {"locale", "e"}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 redeem(code, 1, details: details(%{field => value}))

        assert Keyword.has_key?(changeset.errors, String.to_existing_atom(field))
      end

      assert {:ok, %{device: device}} =
               redeem(code, 2, details: details(%{"locale" => "en_GB", "time_zone" => "Etc/UTC"}))

      assert {device.locale, device.time_zone} == {"en_GB", "Etc/UTC"}
    end

    test "writes device_signed_in with the platform, device class and app version", %{
      scope: scope
    } do
      org = organization_fixture()
      organization_member_fixture(org, scope.user)
      code = authorization_code_fixture(scope, %{}, @t0)

      {:ok, issued} = redeem(code, 1, ip: {10, 0, 0, 9})

      assert [event] =
               AuditLog.list_events(action: "device_signed_in", actor_user_id: scope.user.id)

      assert event.actor_user_id == scope.user.id
      assert event.organization_id == org.id
      assert event.ip == "10.0.0.9"

      assert %{
               "device_id" => device_id,
               "platform" => "ios",
               "device_class" => "tablet",
               "app_version" => "1.2.0 (7)"
             } = event.metadata

      assert device_id == issued.device.id
      refute event |> metadata_keys() |> Enum.any?(&(&1 =~ ~r/token|key|code/))
    end

    test "emits device signed_in once, after the exchange commits (W2748)", %{scope: scope} do
      attach_telemetry([:kanban, :device, :signed_in])

      device_fixture(scope, %{}, @t0)
      refute_receive {:telemetry_event, [:kanban, :device, :signed_in], _, _}

      code = authorization_code_fixture(scope, %{}, @t0)
      assert {:error, :invalid_grant} = redeem(code, 1, grant: %{code_verifier: "wrong-verifier"})
      refute_receive {:telemetry_event, [:kanban, :device, :signed_in], _, _}

      code = authorization_code_fixture(scope, %{}, @t0)
      assert {:ok, _issued} = redeem(code, 1)

      assert_receive {:telemetry_event, [:kanban, :device, :signed_in], %{count: 1}, metadata}
      assert metadata == %{platform: "ios", device_class: "tablet"}
      refute_receive {:telemetry_event, [:kanban, :device, :signed_in], _, _}
    end
  end

  describe "revoke_by_refresh_token/2 and device_id_for_refresh_token/1" do
    test "revokes the device by its refresh token, as its own user", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

      assert Devices.device_id_for_refresh_token(issued.refresh_token) == device.id
      assert {:ok, revoked} = Devices.revoke_by_refresh_token(issued.refresh_token, at(10))
      assert revoked.revoked_at == at(10)
      assert revoked.revoked_by_id == scope.user.id

      assert Devices.fetch_by_access_token(issued.access_token, at(11)) ==
               {:error, :invalid_token}

      assert Devices.rotate_refresh_token(issued.refresh_token, at(11)) ==
               {:error, :invalid_token}

      assert Devices.revoke_by_refresh_token(issued.refresh_token, at(12)) ==
               {:error, :invalid_token}
    end

    test "an already used refresh token still names and revokes its device", %{scope: scope} do
      {device, first} = device_with_tokens_fixture(scope, %{}, @t0)
      {:ok, _second} = Devices.rotate_refresh_token(first.refresh_token, at(60))

      assert {:ok, %Device{id: id}} = Devices.revoke_by_refresh_token(first.refresh_token, at(61))
      assert id == device.id
    end

    test "refuses unknown, access, malformed and expired tokens", %{scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

      assert Devices.revoke_by_refresh_token("sdrt_unknown", at(1)) == {:error, :invalid_token}

      assert Devices.revoke_by_refresh_token(issued.access_token, at(1)) ==
               {:error, :invalid_token}

      assert Devices.revoke_by_refresh_token(nil, at(1)) == {:error, :invalid_token}

      assert Devices.revoke_by_refresh_token(issued.refresh_token, days(31)) ==
               {:error, :invalid_token}

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
      assert Devices.device_id_for_refresh_token(issued.access_token) == nil
      assert Devices.device_id_for_refresh_token(%{}) == nil
    end
  end

  describe "org-admin member devices (W2749)" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      member = user_fixture()
      organization_member_fixture(organization, member, :member)

      %{
        organization: organization,
        admin: admin,
        admin_scope: user_scope_fixture(admin),
        member: member,
        member_scope: user_scope_fixture(member)
      }
    end

    defp org_admin_revoked_events(admin_id),
      do: AuditLog.list_events(action: "device_revoked", actor_user_id: admin_id)

    test "an org-admin can list and revoke a member's devices; a member cannot", ctx do
      first = device_fixture(ctx.member_scope, %{name: "Phone"}, @t0)
      {second, issued} = device_with_tokens_fixture(ctx.member_scope, %{name: "Tablet"}, at(1))
      third = device_fixture(ctx.member_scope, %{name: "Spare"}, at(2))

      assert {:ok, listed} = Devices.list_devices_for_member(ctx.admin_scope, ctx.member.id)
      assert Enum.map(listed, & &1.id) == [third.id, second.id, first.id]

      assert {:error, :unauthorized} =
               Devices.list_devices_for_member(ctx.member_scope, ctx.member.id)

      assert {:error, :unauthorized} =
               Devices.revoke_member_device(ctx.member_scope, first.id, at(5))

      assert {:error, :unauthorized} =
               Devices.revoke_all_for_member(ctx.member_scope, ctx.member.id, at(5))

      assert is_nil(Repo.get!(Device, first.id).revoked_at)

      assert {:ok, revoked} = Devices.revoke_member_device(ctx.admin_scope, first.id, at(10))
      assert revoked.revoked_at == at(10)
      assert revoked.revoked_by_id == ctx.admin.id

      assert [event] = org_admin_revoked_events(ctx.admin.id)
      assert event.metadata["reason"] == "org_admin"
      assert event.metadata["device_id"] == first.id
      assert event.metadata["device_user_id"] == ctx.member.id
      assert event.organization_id == ctx.organization.id

      assert {:ok, all} = Devices.revoke_all_for_member(ctx.admin_scope, ctx.member.id, at(20))
      assert all |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([second.id, third.id])

      assert Devices.fetch_by_access_token(issued.access_token, at(21)) ==
               {:error, :invalid_token}

      assert length(org_admin_revoked_events(ctx.admin.id)) == 3

      assert {:ok, []} = Devices.list_devices_for_member(ctx.admin_scope, ctx.member.id)
      assert {:ok, []} = Devices.revoke_all_for_member(ctx.admin_scope, ctx.member.id, at(30))
      assert length(org_admin_revoked_events(ctx.admin.id)) == 3
    end

    test "revoking an already-revoked device changes nothing and audits nothing", ctx do
      device = device_fixture(ctx.member_scope, %{}, @t0)
      {:ok, _revoked} = Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))
      :ok = Devices.subscribe_devices(ctx.member_scope)

      assert {:error, :already_revoked} =
               Devices.revoke_member_device(ctx.admin_scope, device.id, at(2))

      assert Repo.get!(Device, device.id).revoked_at == at(1)
      assert length(org_admin_revoked_events(ctx.admin.id)) == 1
      refute_receive {:device_revoked, _}
    end

    test "watching a member's devices subscribes only an org-admin to that member", ctx do
      device = device_fixture(ctx.member_scope, %{}, @t0)
      other_scope = user_scope_fixture()
      other = device_fixture(other_scope, %{}, @t0)

      assert {:error, :unauthorized} =
               Devices.watch_member_devices(ctx.member_scope, ctx.member.id)

      {:ok, _} = Devices.revoke_device(ctx.member_scope, device_fixture(ctx.member_scope))
      refute_receive {:device_revoked, _}

      assert {:ok, [%Device{id: id}]} =
               Devices.watch_member_devices(ctx.admin_scope, to_string(ctx.member.id))

      assert id == device.id

      {:ok, _} = Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))
      assert_receive {:device_revoked, ^id}

      {:ok, _} = Devices.revoke_device(other_scope, other)
      refute_receive {:device_revoked, _}

      :ok = Devices.unwatch_member_devices(ctx.member.id)
      {:ok, _} = Devices.revoke_device(ctx.member_scope, device_fixture(ctx.member_scope))
      refute_receive {:device_revoked, _}
    end

    test "a device or user outside the Organization is not found", ctx do
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :member)
      outsider_scope = user_scope_fixture(outsider)
      outside_device = device_fixture(outsider_scope, %{}, @t0)
      loner_device = device_fixture(ctx.scope, %{}, @t0)

      assert {:error, :not_found} = Devices.list_devices_for_member(ctx.admin_scope, outsider.id)

      assert {:error, :not_found} =
               Devices.revoke_member_device(ctx.admin_scope, outside_device.id, at(1))

      assert {:error, :not_found} =
               Devices.revoke_member_device(ctx.admin_scope, loner_device.id, at(1))

      assert {:error, :not_found} =
               Devices.revoke_all_for_member(ctx.admin_scope, outsider.id, at(1))

      assert is_nil(Repo.get!(Device, outside_device.id).revoked_at)
      assert is_nil(Repo.get!(Device, loner_device.id).revoked_at)
      assert org_admin_revoked_events(ctx.admin.id) == []
    end

    test "an org-admin's devices are refused", ctx do
      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)
      device = device_fixture(user_scope_fixture(other_admin), %{}, @t0)

      assert {:error, :org_admin} =
               Devices.list_devices_for_member(ctx.admin_scope, other_admin.id)

      assert {:error, :org_admin} =
               Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))

      assert {:error, :org_admin} =
               Devices.revoke_all_for_member(ctx.admin_scope, other_admin.id, at(1))

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end

    test "ids that cannot name a row are not found", ctx do
      for id <- ["abc", "1.5", "", -1, 0, 9_223_372_036_854_775_808, nil, %{}] do
        assert {:error, :not_found} = Devices.list_devices_for_member(ctx.admin_scope, id)
        assert {:error, :not_found} = Devices.revoke_member_device(ctx.admin_scope, id, at(1))
        assert {:error, :not_found} = Devices.revoke_all_for_member(ctx.admin_scope, id, at(1))
      end
    end

    test "a string id is accepted", ctx do
      device = device_fixture(ctx.member_scope, %{}, @t0)

      assert {:ok, [_]} =
               Devices.list_devices_for_member(ctx.admin_scope, Integer.to_string(ctx.member.id))

      assert {:ok, _} =
               Devices.revoke_member_device(ctx.admin_scope, Integer.to_string(device.id), at(1))
    end

    test "a demoted or disabled org-admin is refused", ctx do
      device = device_fixture(ctx.member_scope, %{}, @t0)

      OrganizationMember
      |> Repo.get_by!(user_id: ctx.admin.id)
      |> Ecto.Changeset.change(role: :member)
      |> Repo.update!()

      assert {:error, :unauthorized} =
               Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))

      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)
      disable(other_admin)

      disabled_scope = user_scope_fixture(other_admin)

      assert {:error, :unauthorized} =
               Devices.list_devices_for_member(disabled_scope, ctx.member.id)

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end

    test "a member who left the Organization is not found", ctx do
      device = device_fixture(ctx.member_scope, %{}, @t0)

      OrganizationMember
      |> Repo.get_by!(user_id: ctx.member.id)
      |> Repo.delete!()

      assert {:error, :not_found} =
               Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))

      assert {:error, :not_found} =
               Devices.list_devices_for_member(ctx.admin_scope, ctx.member.id)

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end

    test "an org-admin revoke emits telemetry and broadcasts the disconnect", ctx do
      device =
        device_fixture(ctx.member_scope, %{platform: :android, client_id: "stride-android"}, @t0)

      attach_telemetry([:kanban, :device, :revoked])
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      {:ok, _revoked} = Devices.revoke_member_device(ctx.admin_scope, device.id, at(1))

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], %{count: 1},
                      %{platform: "android", reason: :org_admin}}

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end

defmodule Kanban.DevicesRotationAtomicityTest do
  # Not async: the test adds a constraint to device_tokens inside its sandbox
  # transaction, which locks the table until the test ends.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Devices
  alias Kanban.Devices.DeviceToken

  @t0 ~U[2026-11-18 12:00:00Z]

  test "a rotation that fails to insert the new pair leaves the old token usable" do
    scope = user_scope_fixture()
    {_device, issued} = device_with_tokens_fixture(scope, %{}, @t0)

    # Any token inserted after t0 now violates a constraint, so the rotation
    # fails after it has marked the old token used.
    Repo.query!(
      "ALTER TABLE device_tokens ADD CONSTRAINT w2744_no_new_tokens " <>
        "CHECK (inserted_at <= '2026-11-18 12:00:00')"
    )

    assert_raise Ecto.ConstraintError, fn ->
      Devices.rotate_refresh_token(issued.refresh_token, DateTime.add(@t0, 60, :second))
    end

    Repo.query!("ALTER TABLE device_tokens DROP CONSTRAINT w2744_no_new_tokens")

    old = Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(issued.refresh_token))
    assert is_nil(old.used_at)

    assert DeviceToken |> where([t], t.family_id == ^old.family_id) |> Repo.aggregate(:count) ==
             2

    assert {:ok, _} =
             Devices.rotate_refresh_token(issued.refresh_token, DateTime.add(@t0, 61, :second))
  end
end

defmodule Kanban.DevicesRotationRaceTest do
  @moduledoc """
  Shows that two concurrent rotations of one refresh token, in real separate
  Postgres sessions, leave exactly one winner, and that the loser is treated
  as reuse: the device is revoked and no refresh token of the family is left
  live. It also races `PUT /api/me/devices/current` (W2748): two devices
  registering one new push token at once, and a revocation landing while an
  update waits on the device's lock.

  The test sandbox never commits, so these sessions could not see sandboxed
  rows. This module checks out unsandboxed connections and commits its
  fixtures for real, which is why it is not async; `on_exit` deletes the
  user, and the cascade removes the device and its tokens.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.DevicesFixtures
  alias Kanban.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    uniq = System.unique_integer([:positive])
    user = Repo.insert!(%User{email: "devices-race-#{uniq}@example.com"})
    on_exit(fn -> delete_committed(user.id) end)

    {device, issued} = user |> Scope.for_user() |> DevicesFixtures.device_with_tokens_fixture()
    %{device: device, issued: issued}
  end

  test "two concurrent rotations of one refresh token leave one winner", ctx do
    plain = ctx.issued.refresh_token
    token = Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(plain))

    holder = hold_token_lock(token.id)
    await_lock_waiters(0)

    first = start_rotation(plain)
    second = start_rotation(plain)
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert {:ok, :released} = Task.await(holder)

    results = Enum.map([first, second], &Task.await/1)

    assert Enum.count(results, &match?({:ok, {:ok, %{refresh_token: _}}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, {:error, :reuse_detected}})) == 1

    assert %DateTime{} = Repo.get!(Device, ctx.device.id).revoked_at

    now = DateTime.utc_now(:second)

    live_refresh =
      from(t in DeviceToken,
        where: t.family_id == ^token.family_id and t.kind == :refresh,
        where: is_nil(t.used_at) and t.expires_at > ^now
      )
      |> Repo.all()

    assert live_refresh == []
  end

  test "a rotation waits for a revocation of its device and is then refused", ctx do
    plain = ctx.issued.refresh_token
    holder = hold_device_lock(ctx.device.id)
    await_lock_waiters(0)

    rotation = start_bare_rotation(plain)
    await_lock_waiters(1)

    send(holder.pid, :proceed)
    assert {:ok, :revoked} = Task.await(holder)

    assert Task.await(rotation) == {:error, :invalid_token}

    now = DateTime.utc_now(:second)

    live =
      from(t in DeviceToken, where: t.device_id == ^ctx.device.id and t.expires_at > ^now)
      |> Repo.all()

    assert live == []
  end

  test "a code exchanged twice in parallel issues one device and one token pair", ctx do
    user = Repo.get!(User, ctx.device.user_id)
    scope = Scope.for_user(user)
    code = DevicesFixtures.authorization_code_fixture(scope)

    grant = %{
      code: code.code,
      client_id: code.client_id,
      redirect_uri: code.redirect_uri,
      code_verifier: DevicesFixtures.valid_code_verifier()
    }

    details = %{
      platform: :android,
      device_class: :phone,
      approval_public_key: DevicesFixtures.valid_approval_public_key()
    }

    holder = hold_row_lock("oauth_authorization_codes", code.id)
    await_lock_waiters(0)

    first = start_exchange(grant, details)
    second = start_exchange(grant, details)
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert {:ok, :released} = Task.await(holder)

    results = Enum.map([first, second], &Task.await/1)

    assert Enum.count(results, &match?({:ok, %{refresh_token: _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_grant})) == 1

    # The fixture device from setup plus the one the winner created.
    user_devices = from(d in Device, where: d.user_id == ^user.id)
    assert Repo.aggregate(user_devices, :count) == 2
  end

  test "two devices registering one new push token at once both succeed and it moves",
       ctx do
    user = Repo.get!(User, ctx.device.user_id)
    scope = Scope.for_user(user)
    first_device = ctx.device
    second_device = DevicesFixtures.device_fixture(scope)
    token = "race-push-token-#{System.unique_integer([:positive])}"

    # Both rows are held, so each update is queued behind its own row lock.
    holder = hold_device_rows([first_device.id, second_device.id])
    await_lock_waiters(0)

    first = start_update(scope, first_device, %{"push_token" => token})
    await_lock_waiters(1)
    second = start_update(scope, second_device, %{"push_token" => token})
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert {:ok, :released} = Task.await(holder)

    assert {:ok, %Device{push_token: ^token}} = Task.await(first)
    assert {:ok, %Device{push_token: ^token}} = Task.await(second)

    assert Repo.get!(Device, first_device.id).push_token == nil
    assert Repo.get!(Device, second_device.id).push_token == token
  end

  test "an update waiting on its device is refused once a revocation commits", ctx do
    user = Repo.get!(User, ctx.device.user_id)
    scope = Scope.for_user(user)
    device = ctx.device

    holder = hold_device_lock(device.id)
    await_lock_waiters(0)

    update = start_update(scope, device, %{"time_zone" => "Asia/Tokyo"})
    await_lock_waiters(1)

    send(holder.pid, :proceed)
    assert {:ok, :revoked} = Task.await(holder)

    assert Task.await(update) == {:error, :revoked}
    assert Repo.get!(Device, device.id).time_zone == device.time_zone
  end

  defp start_update(scope, device, attrs) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.checkout(fn ->
        Repo.query!("SET lock_timeout = '5s'")
        result = Devices.update_current(scope, device, attrs)
        Repo.query!("RESET lock_timeout")
        result
      end)
    end)
  end

  # A second session that locks several device rows FOR UPDATE and holds
  # them until told to proceed.
  defp hold_device_rows(ids) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM user_devices WHERE id = ANY($1) FOR UPDATE", [ids])
          send(test_pid, :holding)
          receive do: (:proceed -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  defp start_exchange(grant, details) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.checkout(fn ->
        Repo.query!("SET lock_timeout = '5s'")
        result = Devices.exchange_authorization_code(grant, details)
        Repo.query!("RESET lock_timeout")
        result
      end)
    end)
  end

  # A second session that locks one row of `table` FOR UPDATE and holds it
  # until told to proceed, so every contender is queued on the lock first.
  defp hold_row_lock(table, id) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [id])
          send(test_pid, :holding)
          receive do: (:proceed -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  # A second session that locks the device row FOR UPDATE, as revoke_device/3
  # does, and on :proceed makes the revocation's writes and commits.
  defp hold_device_lock(device_id) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM user_devices WHERE id = $1 FOR UPDATE", [device_id])
          send(test_pid, :holding)

          receive do
            :proceed ->
              Postgrex.query!(
                c,
                "UPDATE user_devices SET revoked_at = date_trunc('second', now() AT TIME ZONE 'UTC') WHERE id = $1",
                [
                  device_id
                ]
              )

              Postgrex.query!(
                c,
                "UPDATE device_tokens SET expires_at = date_trunc('second', now() AT TIME ZONE 'UTC') WHERE device_id = $1",
                [device_id]
              )

              :revoked
          end
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  # A second session that locks the refresh token row FOR UPDATE and holds it
  # until told to proceed, so both rotations are queued on the lock before
  # either runs.
  defp hold_token_lock(token_id) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM device_tokens WHERE id = $1 FOR UPDATE", [token_id])
          send(test_pid, :holding)
          receive do: (:proceed -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  defp start_rotation(plain) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")
        Devices.rotate_refresh_token(plain)
      end)
    end)
  end

  # A rotation with no outer transaction, so its own refusal is returned as
  # is; the lock timeout is set on the pinned connection and reset after.
  defp start_bare_rotation(plain) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.checkout(fn ->
        Repo.query!("SET lock_timeout = '5s'")
        result = Devices.rotate_refresh_token(plain)
        Repo.query!("RESET lock_timeout")
        result
      end)
    end)
  end

  defp await_lock_waiters(expected, attempts \\ 500)

  defp await_lock_waiters(expected, 0),
    do: flunk("expected #{expected} sessions waiting on a lock, saw #{lock_waiters()}")

  defp await_lock_waiters(expected, attempts) do
    if lock_waiters() == expected do
      :ok
    else
      Process.sleep(10)
      await_lock_waiters(expected, attempts - 1)
    end
  end

  defp lock_waiters do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    count
  end

  # A raw connection outside the sandbox: another Postgres session whose row
  # locks really contend with the others'. Linked to the test process, so it
  # closes when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  # on_exit runs in its own process, which needs its own connection. The
  # cascade deletes the device and its tokens with the user.
  defp delete_committed(user_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    delete_committed_audit_rows(user_id)
    from(u in User, where: u.id == ^user_id) |> Repo.delete_all()
  end

  # The sign-in and reuse paths these tests drive commit device_signed_in and
  # device_refresh_reuse_detected audit rows, naming the user only in their
  # metadata. Left behind, they show up in every later test that reads
  # audit_events in the same database. The table is append-only: only its
  # owner role may delete from it, so the cleanup takes that role for one
  # transaction (tests connect as a superuser, which may switch to it).
  defp delete_committed_audit_rows(user_id) do
    owner_id = Integer.to_string(user_id)

    {:ok, _deleted} =
      Repo.transact(fn ->
        %{rows: [[owner]]} =
          Repo.query!(
            "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'audit_events'::regclass"
          )

        Repo.query!("SET LOCAL ROLE #{Kanban.AuditLog.Hardening.quote_ident(owner)}")

        {count, _rows} =
          from(e in Kanban.AuditLog.AuditEvent,
            where: fragment("?->>'user_id'", e.metadata) == ^owner_id
          )
          |> Repo.delete_all()

        {:ok, count}
      end)
  end
end
