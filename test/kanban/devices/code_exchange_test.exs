defmodule Kanban.Devices.CodeExchangeTest do
  @moduledoc """
  Replaying an authorization code (RFC 6749 §4.1.2, OAuth 2.0 Security BCP
  §4.2.4): a code presented again once it was redeemed is refused and
  revokes the device, and every token, its first redemption issued.
  The replay racing the first exchange is in
  `Kanban.Devices.TokenRaceTest`.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.AuthorizationCodes
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Revocation

  @t0 ~U[2026-11-18 12:00:00Z]

  setup do
    attach_telemetry([:kanban, :device, :revoked])
    %{scope: user_scope_fixture()}
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp details do
    %{
      "platform" => "ios",
      "device_class" => "phone",
      "approval_public_key" => valid_approval_public_key()
    }
  end

  defp redeem(code, seconds, grant \\ %{}, opts \\ []) do
    grant =
      Map.merge(
        %{
          code: code.code,
          client_id: code.client_id,
          redirect_uri: code.redirect_uri,
          code_verifier: valid_code_verifier()
        },
        grant
      )

    Devices.exchange_authorization_code(grant, details(), at(seconds), opts)
  end

  defp live_tokens(device_id, seconds) do
    now = at(seconds)

    from(t in DeviceToken, where: t.device_id == ^device_id and t.expires_at > ^now)
    |> Repo.all()
  end

  defp revoked_rows(user_id),
    do: AuditLog.list_events(action: "device_revoked", actor_user_id: user_id)

  describe "a replayed authorization code" do
    test "is refused and revokes the device and the tokens the first exchange issued", %{
      scope: scope
    } do
      code = authorization_code_fixture(scope, %{}, @t0)
      assert {:ok, issued} = redeem(code, 5)
      device_id = issued.device.id
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device_id))

      assert redeem(code, 10, %{}, ip: {10, 0, 0, 7}) == {:error, :invalid_grant}

      assert %DateTime{} = Repo.get!(Device, device_id).revoked_at
      assert live_tokens(device_id, 10) == []

      assert Devices.fetch_by_access_token(issued.access_token, at(11)) ==
               {:error, :invalid_token}

      assert Devices.rotate_refresh_token(issued.refresh_token, at(11)) ==
               {:error, :invalid_token}

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], %{count: 1},
                      %{reason: :reuse_detected, platform: "ios"}}

      assert [event] = revoked_rows(scope.user.id)
      assert event.metadata["reason"] == "reuse_detected"
      assert event.metadata["device_id"] == device_id
      assert event.ip == "10.0.0.7"
      refute inspect(event.metadata) =~ code.code
    end

    test "also kills the tokens rotated from the first pair", %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)
      {:ok, first} = redeem(code, 5)
      {:ok, rotated} = Devices.rotate_refresh_token(first.refresh_token, at(20))

      assert redeem(code, 30) == {:error, :invalid_grant}

      assert Devices.fetch_by_access_token(rotated.access_token, at(31)) ==
               {:error, :invalid_token}

      assert Devices.rotate_refresh_token(rotated.refresh_token, at(31)) ==
               {:error, :invalid_token}
    end

    test "revokes whichever client presents it, and after the code expired", %{scope: scope} do
      other_client = authorization_code_fixture(scope, %{}, @t0)
      {:ok, first} = redeem(other_client, 5)

      assert redeem(other_client, 6, %{client_id: "stride-android"}) == {:error, :invalid_grant}
      assert %DateTime{} = Repo.get!(Device, first.device.id).revoked_at

      late = authorization_code_fixture(scope, %{}, @t0)
      {:ok, second} = redeem(late, 5)

      assert redeem(late, 3_600, %{code_verifier: "wrong"}) == {:error, :invalid_grant}
      assert %DateTime{} = Repo.get!(Device, second.device.id).revoked_at
    end

    test "leaves every other device of the person alone", %{scope: scope} do
      {other, other_issued} = device_with_tokens_fixture(scope, %{}, @t0)
      sibling = authorization_code_fixture(scope, %{}, @t0)
      {:ok, sibling_issued} = redeem(sibling, 2)

      code = authorization_code_fixture(scope, %{}, @t0)
      {:ok, _issued} = redeem(code, 5)
      assert redeem(code, 10) == {:error, :invalid_grant}

      assert is_nil(Repo.get!(Device, other.id).revoked_at)
      assert is_nil(Repo.get!(Device, sibling_issued.device.id).revoked_at)
      assert {:ok, _} = Devices.fetch_by_access_token(other_issued.access_token, at(11))
      assert {:ok, _} = Devices.fetch_by_access_token(sibling_issued.access_token, at(11))
    end

    test "a second replay announces nothing again", %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)
      {:ok, _issued} = redeem(code, 5)

      assert redeem(code, 10) == {:error, :invalid_grant}
      assert redeem(code, 11) == {:error, :invalid_grant}

      assert [_one] = revoked_rows(scope.user.id)
    end

    test "a code whose first exchange failed has nothing to revoke", %{scope: scope} do
      {other, _issued} = device_with_tokens_fixture(scope, %{}, @t0)
      code = authorization_code_fixture(scope, %{}, @t0)

      assert redeem(code, 5, %{code_verifier: String.duplicate("a", 43)}) ==
               {:error, :invalid_grant}

      assert %AuthorizationCode{used_at: %DateTime{}} = Repo.get!(AuthorizationCode, code.id)
      assert redeem(code, 6) == {:error, :invalid_grant}

      assert is_nil(Repo.get!(Device, other.id).revoked_at)
      assert revoked_rows(scope.user.id) == []
      refute_received {:telemetry_event, [:kanban, :device, :revoked], _, _}
    end

    test "consume_authorization_code/3 refuses a used code and revokes nothing", %{scope: scope} do
      code = authorization_code_fixture(scope, %{}, @t0)
      {:ok, issued} = redeem(code, 5)

      assert Devices.consume_authorization_code(code.code, code.client_id, at(6)) ==
               {:error, :invalid_grant}

      assert is_nil(Repo.get!(Device, issued.device.id).revoked_at)
    end
  end

  describe "AuthorizationCodes.family_id/1" do
    test "the first pair's family is derived from the code, and differs per code", %{
      scope: scope
    } do
      code = authorization_code_fixture(scope, %{}, @t0)
      other = authorization_code_fixture(scope, %{}, @t0)
      {:ok, issued} = redeem(code, 5)

      stored = Repo.get!(AuthorizationCode, code.id)
      family_id = AuthorizationCodes.family_id(stored)

      refresh_hash = DeviceToken.hash_token(issued.refresh_token)
      assert Repo.get_by!(DeviceToken, token_hash: refresh_hash).family_id == family_id

      assert {:ok, _uuid} = Ecto.UUID.cast(family_id)
      other_family = AuthorizationCode |> Repo.get!(other.id) |> AuthorizationCodes.family_id()
      refute other_family == family_id
      refute String.replace(family_id, "-", "") == stored.code_hash
    end
  end
end
