defmodule Kanban.AuditStream.ReseedRaceTest do
  @moduledoc """
  The cursor re-seed (`Kanban.AuditStream.Reseed`) against a second,
  committing connection: it locks a destination's row before its cursor, the
  order `Kanban.AuditStream.DispatchWorker` and a delete take them in, and it
  skips a destination deleted while it waited for that lock instead of
  counting it busy (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.8).

  ## Running

  Tagged `:audit_stream_race`, which `test/test_helper.exs` excludes. The
  rows these tests commit stay behind, so they run only in the throwaway race
  database:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/reseed_race_test.exs
      dropdb kanban_test_race
  """
  use ExUnit.Case, async: false

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.Repo

  @moduletag :audit_stream_race
  @moduletag timeout: 120_000

  @await_ms 30_000

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits rows that stay behind, so it runs only in \
      the throwaway kanban_test_race database, not #{database}:

          dropdb --if-exists kanban_test_race
          MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    organization =
      organization_fixture(%{name: "audit-reseed-race #{System.unique_integer([:positive])}"})

    destination = destination_fixture(organization, :https)

    # Halted txid_reset, so the re-seed treats it as left behind by a move
    # and takes its lock rather than skipping it as unmoved.
    from(d in Destination, where: d.id == ^destination.id)
    |> Repo.update_all(set: [halted_reason: :txid_reset])

    %{organization: organization, destination: destination}
  end

  # A connection of its own, outside the test's pool, so it can hold a lock
  # while the re-seed waits on it.
  defp connection do
    opts =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp waiting_on_lock?(conn, holder_pid) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND $1 = ANY(pg_blocking_pids(pid))",
        [holder_pid]
      )

    rows == [[1]]
  end

  defp await_blocked(conn, holder_pid, deadline) do
    cond do
      waiting_on_lock?(conn, holder_pid) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the re-seed never waited on the destination lock")

      true ->
        Process.sleep(20)
        await_blocked(conn, holder_pid, deadline)
    end
  end

  test "locks the destination before the cursor and skips one deleted meanwhile", ctx do
    destination_id = ctx.destination.id
    holder = connection()
    checker = connection()
    %{rows: [[holder_pid]]} = Postgrex.query!(holder, "SELECT pg_backend_pid()", [])

    # Other destinations in this database whose lease a run still holds are
    # busy; this one, deleted, must not be counted with them.
    others_busy =
      from(c in Cursor,
        where: c.destination_id != ^destination_id and c.leased_until > ^DateTime.utc_now()
      )
      |> Repo.aggregate(:count)

    Postgrex.query!(holder, "BEGIN", [])

    Postgrex.query!(
      holder,
      "SELECT 1 FROM audit_stream_destinations WHERE id = $1 FOR UPDATE",
      [destination_id]
    )

    reseed = Task.async(fn -> AuditStream.reseed_cursors(lease_wait_ms: 1, lease_poll_ms: 1) end)
    await_blocked(checker, holder_pid, System.monotonic_time(:millisecond) + @await_ms)

    # Waiting on the destination, the re-seed holds no lock on the cursor.
    Postgrex.query!(checker, "BEGIN", [])

    assert %{num_rows: 1} =
             Postgrex.query!(
               checker,
               "SELECT 1 FROM audit_stream_cursors WHERE destination_id = $1 FOR UPDATE NOWAIT",
               [destination_id]
             )

    Postgrex.query!(checker, "ROLLBACK", [])

    Postgrex.query!(holder, "DELETE FROM audit_stream_destinations WHERE id = $1", [
      destination_id
    ])

    Postgrex.query!(holder, "COMMIT", [])

    assert {:ok, %{busy: ^others_busy}} = Task.await(reseed, @await_ms)
    assert Repo.get(Destination, destination_id) == nil
    assert Repo.get(Cursor, destination_id) == nil

    reseeded =
      from(e in AuditEvent,
        where:
          e.organization_id == ^ctx.organization.id and
            e.action == "audit_stream_cursors_reseeded"
      )

    assert Repo.all(reseeded) == []
  end
end
