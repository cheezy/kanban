defmodule Kanban.AuditStream.SchedulerRaceTest do
  @moduledoc """
  Two minute sweeps of the same 15-minute slot, each on a committing
  connection of its own, as two nodes running the cron or a slow sweep
  overlapping the next would: every enabled destination of the slot is
  measured once between them (D432; `Kanban.AuditStream.measure_lag/3`).

  ## Running

  Tagged `:audit_stream_race`, which `test/test_helper.exs` excludes. The
  rows these tests commit stay behind, so they run only in the throwaway race
  database:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/scheduler_race_test.exs
      dropdb kanban_test_race
  """
  use ExUnit.Case, async: false

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Scheduler
  alias Kanban.AuditStream.Sweep
  alias Kanban.Repo

  @moduletag :audit_stream_race
  @moduletag timeout: 120_000

  @lag [:kanban, :audit_stream, :lag_measured]
  @rounds 30
  @await_ms 10_000

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
      organization_fixture(%{name: "audit-scheduler-race #{System.unique_integer([:positive])}"})

    %{destination: destination_fixture(organization, :https)}
  end

  # A connection of its own, outside the test's pool, so it can hold a lock
  # while the sweeps wait on it.
  defp connection do
    opts =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  # A tick of `destination`'s residue in a slot later than every slot any
  # destination in this database has been measured in, so every destination
  # of that residue is still unmeasured in it.
  defp next_tick(destination) do
    latest =
      from(c in Cursor, select: max(c.lag_measured_slot)) |> Repo.one() ||
        ~U[2030-01-01 00:00:00.000000Z]

    DateTime.add(latest, 15 * 60 + rem(destination.id, 15) * 60, :second)
  end

  # Every enabled destination this tick's sweep should measure.
  defp expected(tick) do
    {residue, _slot} = Sweep.lag_slot(tick)

    from(d in Destination, where: d.enabled and fragment("? % 15", d.id) == ^residue)
    |> Repo.aggregate(:count)
  end

  defp sweep(tick) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Scheduler.perform(%Oban.Job{scheduled_at: tick})
    end)
  end

  defp drain_lag(count) do
    receive do
      {:telemetry_event, @lag, _measurements, _metadata} -> drain_lag(count + 1)
    after
      0 -> count
    end
  end

  # Backends of this database waiting on a lock. The first sweep waits on
  # the holder; the second waits behind the first, so pg_blocking_pids names
  # the first sweep rather than the holder for it.
  defp waiters(conn) do
    %{rows: [[count]]} =
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()",
        []
      )

    count
  end

  defp await_waiters(conn, want, deadline) do
    cond do
      waiters(conn) >= want ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the sweeps never both waited on the cursor lock")

      true ->
        Process.sleep(20)
        await_waiters(conn, want, deadline)
    end
  end

  test "concurrent sweeps measure once", ctx do
    attach_telemetry([@lag], any_process: true)

    for _round <- 1..@rounds do
      tick = next_tick(ctx.destination)
      want = expected(tick)
      assert want >= 1

      assert [:ok, :ok] = Task.await_many([sweep(tick), sweep(tick)], @await_ms)
      assert drain_lag(0) == want

      assert Repo.get!(Cursor, ctx.destination.id).lag_measured_slot ==
               elem(Sweep.lag_slot(tick), 1)
    end
  end

  test "concurrent sweeps held on the cursor lock measure once when it is released", ctx do
    attach_telemetry([@lag], any_process: true)
    holder = connection()
    checker = connection()

    tick = next_tick(ctx.destination)
    want = expected(tick)

    Postgrex.query!(holder, "BEGIN", [])

    Postgrex.query!(
      holder,
      "SELECT 1 FROM audit_stream_cursors WHERE destination_id = $1 FOR UPDATE",
      [ctx.destination.id]
    )

    sweeps = [sweep(tick), sweep(tick)]
    await_waiters(checker, 2, System.monotonic_time(:millisecond) + @await_ms)
    refute_received {:telemetry_event, @lag, _, _}

    Postgrex.query!(holder, "ROLLBACK", [])

    assert [:ok, :ok] = Task.await_many(sweeps, @await_ms)
    assert drain_lag(0) == want

    assert Repo.get!(Cursor, ctx.destination.id).lag_measured_slot ==
             elem(Sweep.lag_slot(tick), 1)
  end
end
