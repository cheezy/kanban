defmodule Kanban.Devices.PushTokensTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Devices
  alias Kanban.Devices.PushTokens

  defp device!(user, token), do: device_fixture(Scope.for_user(user), %{push_token: token})

  describe "user_ids_with_device/1" do
    test "returns only users with an active device that has a push token" do
      with_token = user_fixture()
      without_token = user_fixture()
      revoked_only = user_fixture()
      no_device = user_fixture()

      device!(with_token, "tok-a")
      device!(with_token, "tok-b")
      device!(without_token, nil)
      revoked = device!(revoked_only, "tok-c")
      {:ok, _} = revoked_only |> Scope.for_user() |> Devices.revoke_device(revoked)

      ids = [with_token.id, without_token.id, revoked_only.id, no_device.id]

      assert PushTokens.user_ids_with_device(ids) == MapSet.new([with_token.id])
      assert PushTokens.user_ids_with_device([]) == MapSet.new()
    end
  end

  describe "list_for_user/1" do
    test "lists the active devices with a push token, oldest first" do
      user = user_fixture()
      first = device!(user, "tok-1")
      _no_token = device!(user, nil)
      second = device!(user, "tok-2")
      revoked = device!(user, "tok-3")
      {:ok, _} = user |> Scope.for_user() |> Devices.revoke_device(revoked)

      assert user.id |> PushTokens.list_for_user() |> Enum.map(& &1.id) == [first.id, second.id]
      assert PushTokens.list_for_user(user_fixture().id) == []
    end
  end

  describe "revocation" do
    test "a revoked device is never reachable, even with a token left behind" do
      user = user_fixture()
      device = device!(user, "tok-kept")

      device
      |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update!()

      assert Repo.reload!(device).push_token == "tok-kept"
      assert PushTokens.list_for_user(user.id) == []
      assert PushTokens.user_ids_with_device([user.id]) == MapSet.new()
    end
  end

  describe "current/1" do
    test "reads the device again and drops one that can no longer take a push" do
      user = user_fixture()
      kept = device!(user, "tok-kept")
      revoked = device!(user, "tok-gone")
      cleared = device!(user, "tok-cleared")

      {:ok, _} = user |> Scope.for_user() |> Devices.revoke_device(revoked)
      cleared |> Ecto.Changeset.change(push_token: nil) |> Repo.update!()

      assert %{id: id} = PushTokens.current(kept)
      assert id == kept.id
      assert PushTokens.current(revoked) == nil
      assert PushTokens.current(cleared) == nil
      assert PushTokens.current(%{kept | user_id: user_fixture().id}) == nil
    end
  end

  describe "clear/1" do
    test "clears the token the device was loaded with" do
      device = device!(user_fixture(), "tok-dead")

      assert PushTokens.clear(device) == :ok
      assert Repo.reload!(device).push_token == nil
    end

    test "keeps a token registered again since the device was loaded" do
      device = device!(user_fixture(), "tok-old")
      device |> Ecto.Changeset.change(push_token: "tok-new") |> Repo.update!()

      assert PushTokens.clear(device) == :ok
      assert Repo.reload!(device).push_token == "tok-new"
    end

    test "is a no-op for a device without a token" do
      device = device!(user_fixture(), nil)
      assert PushTokens.clear(device) == :ok
    end
  end
end
