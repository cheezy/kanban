defmodule Kanban.AuditStream.LeaseTest do
  use Kanban.DataCase, async: true

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Reachability
  alias Kanban.Repo

  setup do
    %{destination: destination_fixture(organization_fixture(), :https)}
  end

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp expire(destination) do
    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(set: [leased_until: DateTime.add(DateTime.utc_now(), -1, :second)])
  end

  defp guard(destination, token) do
    {:ok, cursor} = Repo.transact(fn -> {:ok, Lease.guard(destination.id, token)} end)
    cursor
  end

  test "take/1 gives one run the lease, ttl seconds ahead", %{destination: destination} do
    assert {:ok, token} = Lease.take(destination.id)
    assert Lease.take(destination.id) == :held

    cursor = cursor(destination)
    assert cursor.lease_token == token

    assert DateTime.diff(cursor.leased_until, DateTime.utc_now()) in (Lease.ttl() - 2)..Lease.ttl()
  end

  test "an expired lease can be taken again, and the old token no longer guards", %{
    destination: destination
  } do
    {:ok, old} = Lease.take(destination.id)
    expire(destination)

    assert guard(destination, old) == nil
    assert {:ok, new} = Lease.take(destination.id)
    assert new != old
    assert %Cursor{lease_token: ^new} = guard(destination, new)
    assert guard(destination, old) == nil
  end

  test "release/2 clears only the token's own lease", %{destination: destination} do
    {:ok, token} = Lease.take(destination.id)

    assert Lease.release(destination.id, Ecto.UUID.generate()) == :ok
    assert cursor(destination).lease_token == token

    assert Lease.release(destination.id, token) == :ok
    assert %Cursor{lease_token: nil, leased_until: nil} = cursor(destination)
    assert {:ok, _token} = Lease.take(destination.id)
  end

  test "extend/2 renews only the token's own live lease", %{destination: destination} do
    {:ok, token} = Lease.take(destination.id)
    soon = DateTime.add(DateTime.utc_now(), 5, :second)

    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(set: [leased_until: soon])

    assert Lease.extend(destination.id, token) == :ok
    assert DateTime.diff(cursor(destination).leased_until, DateTime.utc_now()) >= Lease.ttl() - 2

    assert Lease.extend(destination.id, Ecto.UUID.generate()) == :lost
    assert cursor(destination).lease_token == token

    expire(destination)
    assert Lease.extend(destination.id, token) == :lost
    assert DateTime.compare(cursor(destination).leased_until, DateTime.utc_now()) == :lt
  end

  test "owned/2 finds the cursor while the token is unchanged, expired or not", %{
    destination: destination
  } do
    {:ok, token} = Lease.take(destination.id)
    assert %Cursor{lease_token: ^token} = Lease.owned(destination.id, token)

    expire(destination)
    assert Lease.guard(destination.id, token) == nil
    assert %Cursor{lease_token: ^token} = Lease.owned(destination.id, token)

    {:ok, other} = Lease.take(destination.id)
    assert Lease.owned(destination.id, token) == nil
    assert %Cursor{lease_token: ^other} = Lease.owned(destination.id, other)
  end

  test "release_attrs/0 clears the lease fields" do
    assert Lease.release_attrs() == %{lease_token: nil, leased_until: nil}
  end

  test "a destination with no cursor has no lease to take" do
    assert Lease.take(-1) == :held
  end

  test "seconds_left/1 is the time to the lease's expiry, rounded up", %{destination: destination} do
    assert Lease.seconds_left(-1) == nil
    assert Lease.seconds_left(destination.id) == 0

    {:ok, _token} = Lease.take(destination.id)
    assert Lease.seconds_left(destination.id) == Lease.ttl()

    expire(destination)
    assert Lease.seconds_left(destination.id) == 0
  end

  test "Reachability.check_url/2 checks a stored URL over the configured resolver" do
    assert {:ok, %{addresses: [{93, 184, 216, 35}]}} =
             Reachability.check_url("https://siem.example.org/in")

    assert Reachability.check_url("https://internal.example.com/in") == {:error, :blocked_address}
    assert Reachability.check_url("https://nowhere.example.net/in") == {:error, :unresolvable}

    assert {:ok, _resolved} =
             Reachability.check_url("https://nowhere.example.net/in",
               resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
             )
  end
end
