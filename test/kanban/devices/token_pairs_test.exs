defmodule Kanban.Devices.TokenPairsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.TokenPairs

  @t0 ~U[2026-11-18 12:00:00Z]

  test "refresh_expiry/2 is 30 days out, capped at 90 days after sign-in" do
    scope = user_scope_fixture()
    device = device_fixture(scope, %{}, @t0)

    assert TokenPairs.refresh_expiry(device, @t0) == DateTime.add(@t0, 30, :day)

    late = DateTime.add(@t0, 80, :day)
    assert TokenPairs.refresh_expiry(device, late) == DateTime.add(@t0, 90, :day)
  end

  test "insert/3 inserts a one-hour access token and a refresh token in one family" do
    device = user_scope_fixture() |> device_fixture(%{}, @t0)
    family_id = Ecto.UUID.generate()

    assert {:ok, issued} = TokenPairs.insert(device, family_id, @t0)

    assert issued.device.id == device.id
    assert issued.access_token_expires_at == DateTime.add(@t0, 3600, :second)
    assert issued.refresh_token_expires_at == DateTime.add(@t0, 30, :day)

    access = Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(issued.access_token))
    refresh = Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(issued.refresh_token))

    assert {access.kind, refresh.kind} == {:access, :refresh}
    assert access.family_id == family_id and refresh.family_id == family_id
  end
end
