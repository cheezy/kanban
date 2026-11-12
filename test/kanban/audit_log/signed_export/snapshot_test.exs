defmodule Kanban.AuditLog.SignedExport.SnapshotTest do
  # async: false — one test turns the isolation switch on, which is global
  # application config.
  use Kanban.DataCase, async: false

  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.SignedExport.Slots
  alias Kanban.AuditLog.SignedExport.Snapshot

  @boundary_format ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

  defp insert_event!(organization) do
    Repo.insert!(%AuditEvent{
      action: "snapshot_test",
      organization_id: organization.id,
      inserted_at: DateTime.utc_now(),
      metadata: %{}
    })
  end

  describe "read/1" do
    test "returns the boundary, in UTC microseconds, with the function's result" do
      before = DateTime.utc_now()

      assert {boundary, :result} = Snapshot.read(fn -> :result end)

      assert boundary =~ @boundary_format
      {:ok, at, 0} = DateTime.from_iso8601(boundary)
      assert DateTime.compare(before, at) != :gt
      assert DateTime.compare(at, DateTime.utc_now()) != :gt
    end

    test "runs the function inside one transaction" do
      assert {_boundary, true} = Snapshot.read(fn -> Repo.in_transaction?() end)
    end

    test "a throw rolls the transaction back and reaches the caller" do
      organization = organization_fixture()

      assert catch_throw(
               Snapshot.read(fn ->
                 insert_event!(organization)
                 throw({:signed_export, :enospc})
               end)
             ) == {:signed_export, :enospc}

      refute AuditEvent |> where(action: "snapshot_test") |> Repo.exists?()
    end

    test "with no slot free in time it throws :busy, runs nothing and opens no transaction" do
      slots = start_supervised!({Slots, name: nil, slots: 1, wait: 50})
      test_pid = self()

      holder =
        spawn(fn ->
          Slots.with_slot(slots, fn ->
            send(test_pid, :holding)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :holding

      assert catch_throw(Snapshot.read(fn -> flunk("must not run") end, slots)) ==
               {:signed_export, :busy}

      send(holder, :release)
    end

    test "a timeout after the last statement throws :timeout and gives the slot back" do
      saved = Application.fetch_env(:kanban, Snapshot)

      on_exit(fn ->
        case saved do
          {:ok, config} -> Application.put_env(:kanban, Snapshot, config)
          :error -> Application.delete_env(:kanban, Snapshot)
        end
      end)

      Application.put_env(:kanban, Snapshot, snapshot_isolation: false, timeout: 100)
      slots = start_supervised!({Slots, name: nil, slots: 1, wait: 1_000})

      # The deadline fires while the function is between statements, so
      # DBConnection rolls back and returns instead of raising.
      read = fn ->
        Repo.query!("SELECT 1")
        Process.sleep(300)
        :unreached
      end

      assert catch_throw(Snapshot.read(read, slots)) == {:signed_export, :timeout}

      # The slot came back. The sandbox drops its owner's connection on a
      # timeout, so the connection is not checked here.
      assert {:ok, :free} = Slots.with_slot(slots, fn -> :free end)
    end

    test "with the switch on, it asks for a REPEATABLE READ, READ ONLY snapshot" do
      saved = Application.fetch_env(:kanban, Snapshot)

      on_exit(fn ->
        case saved do
          {:ok, config} -> Application.put_env(:kanban, Snapshot, config)
          :error -> Application.delete_env(:kanban, Snapshot)
        end
      end)

      Application.put_env(:kanban, Snapshot, snapshot_isolation: true)

      # The sandbox has already run queries in its own transaction, so the
      # level can no longer be set: proof that the statement is sent. The
      # race probe of D424 exercised it against a real connection.
      error = assert_raise Postgrex.Error, fn -> Snapshot.read(fn -> :unreached end) end
      assert error.postgres.code == :active_sql_transaction

      # Rolled back: the sandbox's connection still answers.
      assert Repo.aggregate(AuditEvent, :count) >= 0
    end
  end
end
