defmodule Kanban.AuditStream.Retention.LeasesTest do
  use Kanban.DataCase, async: true

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Retention.Leases
  alias Kanban.Repo

  setup do
    organization = organization_fixture()

    %{
      first: destination_fixture(organization, :https),
      second: destination_fixture(organization, :https)
    }
  end

  defp lease_token(destination), do: Repo.get!(Cursor, destination.id).lease_token

  defp now_ms, do: System.monotonic_time(:millisecond)

  test "take_all/3 takes every lease and skips a destination that is gone", %{
    first: first,
    second: second
  } do
    assert {:ok, leases} = Leases.take_all([first.id, -1, second.id], now_ms() + 1_000, 1)

    assert Enum.sort(leases) ==
             Enum.sort([{first.id, lease_token(first)}, {second.id, lease_token(second)}])
  end

  test "take_all/3 releases the leases it took when one stays held", %{
    first: first,
    second: second
  } do
    {:ok, held} = Lease.take(second.id)

    assert Leases.take_all([first.id, second.id], now_ms(), 1) == :held
    assert lease_token(first) == nil
    assert lease_token(second) == held
  end

  test "releases taken leases when take_all raises", %{first: first, second: second} do
    # Kanban.AuditStream.Lease.take/1 takes only an integer id, so the third
    # take raises after the first two leases are taken.
    assert_raise FunctionClauseError, fn ->
      Leases.take_all([first.id, second.id, :not_an_id], now_ms() + 1_000, 1)
    end

    assert lease_token(first) == nil
    assert lease_token(second) == nil
  end

  test "take_all/3 raising on the first take has nothing to release", %{first: first} do
    assert_raise FunctionClauseError, fn ->
      Leases.take_all([:not_an_id, first.id], now_ms() + 1_000, 1)
    end

    assert lease_token(first) == nil
  end

  test "release_all/1 releases every lease even when one release raises, then re-raises", %{
    first: first,
    second: second
  } do
    {:ok, leases} = Leases.take_all([first.id, second.id], now_ms() + 1_000, 1)
    [one, two] = leases

    # Lease.release/2 takes only a binary token, so the middle release raises.
    assert_raise FunctionClauseError, fn ->
      Leases.release_all([one, {first.id, :not_a_token}, two])
    end

    assert lease_token(first) == nil
    assert lease_token(second) == nil
  end

  test "extend_all/1 and release_all/1 renew and release every lease", %{
    first: first,
    second: second
  } do
    {:ok, leases} = Leases.take_all([first.id, second.id], now_ms() + 1_000, 1)
    soon = DateTime.add(DateTime.utc_now(), 5, :second)

    from(c in Cursor, where: c.destination_id in ^[first.id, second.id])
    |> Repo.update_all(set: [leased_until: soon])

    assert Leases.extend_all(leases) == :ok

    for destination <- [first, second] do
      leased_until = Repo.get!(Cursor, destination.id).leased_until
      assert DateTime.diff(leased_until, soon) > 30
    end

    assert Leases.release_all(leases) == :ok
    assert lease_token(first) == nil
    assert lease_token(second) == nil
  end
end
