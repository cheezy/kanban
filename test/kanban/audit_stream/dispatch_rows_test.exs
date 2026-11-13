defmodule Kanban.AuditStream.DispatchRowsTest do
  use Kanban.DataCase, async: true

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchRows
  alias Kanban.AuditStream.Lease
  alias Kanban.Repo

  setup do
    %{destination: destination_fixture(organization_fixture(), :https)}
  end

  defp transact(fun) do
    {:ok, result} = Repo.transact(fn -> {:ok, fun.()} end)
    result
  end

  test "lock_destination/1 locks a destination, and says :gone once it is deleted", %{
    destination: destination
  } do
    assert {:ok, %Destination{id: id}} =
             transact(fn -> DispatchRows.lock_destination(destination.id) end)

    assert id == destination.id

    Repo.delete!(destination)
    assert transact(fn -> DispatchRows.lock_destination(destination.id) end) == {:error, :gone}
  end

  test "guard/2 returns the cursor only while the token holds the lease", %{
    destination: destination
  } do
    {:ok, token} = Lease.take(destination.id)

    assert {:ok, %Cursor{lease_token: ^token}} =
             transact(fn -> DispatchRows.guard(destination.id, token) end)

    assert transact(fn -> DispatchRows.guard(destination.id, Ecto.UUID.generate()) end) ==
             {:error, :lease_lost}
  end

  test "update_cursor/2 writes nothing for empty attrs, and writes the attrs otherwise", %{
    destination: destination
  } do
    cursor = Repo.get!(Cursor, destination.id)

    assert DispatchRows.update_cursor(cursor, %{}) == {:ok, cursor}

    assert {:ok, %Cursor{pending_attempts: 3}} =
             DispatchRows.update_cursor(cursor, %{pending_attempts: 3})

    assert Repo.get!(Cursor, destination.id).pending_attempts == 3
  end
end
