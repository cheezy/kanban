defmodule Kanban.AuditStream.SchedulerTest do
  @moduledoc """
  The minute sweep in the Ecto sandbox. Events inserted with a chosen small
  `txid` are below any real horizon, and those inserted with the sandbox
  transaction's own id are above it, so no horizon setting is needed. Each
  destination has an Organization of its own, so one destination's events
  are never another's.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditStream.AttemptPruneWorker
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Scheduler
  alias Kanban.Repo

  @lag [:kanban, :audit_stream, :lag_measured]

  # --- helpers ------------------------------------------------------------------

  defp destination(fields \\ [], kind \\ :https) do
    destination = organization_fixture() |> destination_fixture(kind)
    {cursor_fields, destination_fields} = Keyword.split(fields, [:next_attempt_at, :leased_until])

    update_rows(from(d in Destination, where: d.id == ^destination.id), destination_fields)
    update_rows(from(c in Cursor, where: c.destination_id == ^destination.id), cursor_fields)
    destination
  end

  defp update_rows(_query, []), do: :ok
  defp update_rows(query, fields), do: Repo.update_all(query, set: fields)

  defp event!(destination, txid, inserted_at \\ ~N[2026-11-01 00:00:00.000000]) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', $2, $3) RETURNING id
        """,
        [destination.organization_id, inserted_at, txid]
      )

    id
  end

  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  defp ago(seconds),
    do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-seconds, :second)

  defp sweep(at \\ DateTime.utc_now()), do: perform_job(Scheduler, %{}, scheduled_at: at)

  defp swept,
    do:
      [worker: DispatchWorker]
      |> all_enqueued()
      |> Enum.map(& &1.args["destination_id"])
      |> Enum.sort()

  # A tick whose minute is `destination`'s 15-minute slot.
  defp slot_tick(destination) do
    base = %{DateTime.utc_now() | minute: 0, second: 0, microsecond: {0, 6}}
    DateTime.add(base, rem(destination.id, 15) * 60, :second)
  end

  # --- the sweep ------------------------------------------------------------------

  describe "the sweep" do
    test "enqueues only enabled, unhalted, due destinations", _ctx do
      now = DateTime.utc_now()

      never_tried = destination()
      event!(never_tried, 1)

      due_earlier = destination(next_attempt_at: DateTime.add(now, -5, :second))
      event!(due_earlier, 1)

      leased = destination()
      event!(leased, 1)
      {:ok, _token} = Lease.take(leased.id)

      lease_expired = destination(leased_until: DateTime.add(now, -1, :second))
      event!(lease_expired, 1)

      not_due = destination(next_attempt_at: DateTime.add(now, 60, :second))
      event!(not_due, 1)

      _nothing_waiting = destination()

      only_above_horizon = destination()
      event!(only_above_horizon, own_txid(), NaiveDateTime.utc_now())

      assert :ok = sweep()

      # A run holding a live lease queues its own follow-up; a lease left
      # behind by a crashed run, once expired, no longer keeps it out.
      assert swept() == Enum.sort([never_tried.id, due_earlier.id, lease_expired.id])

      for job <- all_enqueued(worker: DispatchWorker), do: assert(job.queue == "audit_stream")
    end

    test "halted and paused destinations are never swept", _ctx do
      halted = destination(halted_reason: :rejected_batch, state: :failing)
      event!(halted, 1)

      paused = destination(enabled: false)
      event!(paused, 1)

      assert :ok = sweep()

      assert swept() == []
      refute_enqueued(worker: DispatchWorker)
    end

    test "no destinations enqueues nothing", _ctx do
      attach_telemetry([@lag])

      for minute <- 0..14 do
        assert :ok = sweep(%{DateTime.utc_now() | minute: minute})
      end

      refute_enqueued(worker: DispatchWorker)
      refute_received {:telemetry_event, @lag, _, _}
    end
  end

  # --- lag ------------------------------------------------------------------------

  describe "lag telemetry" do
    test "lag_measured emitted once per 15-minute slot", _ctx do
      destination = destination()
      event!(destination, 1, ago(3_600))
      event!(destination, own_txid(), NaiveDateTime.utc_now())
      attach_telemetry([@lag])

      tick = slot_tick(destination)
      base = %{tick | minute: 0}

      for minute <- 0..14, do: assert(:ok = sweep(DateTime.add(base, minute * 60, :second)))

      assert_received {:telemetry_event, @lag, measurements, metadata}
      refute_received {:telemetry_event, @lag, _, _}

      assert Map.keys(measurements) |> Enum.sort() ==
               [:events_above_horizon, :events_waiting, :lag_seconds]

      assert measurements.events_waiting == 2
      assert measurements.events_above_horizon == 1
      assert measurements.lag_seconds in 3_599..3_605
      assert metadata == %{kind: :https}

      # The same slot an hour later measures again.
      assert :ok = sweep(DateTime.add(tick, 3_600, :second))
      assert_received {:telemetry_event, @lag, _, _}
    end

    test "a held horizon shows as waiting events and growing lag, never zero", _ctx do
      destination = destination()
      event!(destination, own_txid(), ago(300))
      attach_telemetry([@lag])

      assert :ok = sweep(slot_tick(destination))

      refute_enqueued(worker: DispatchWorker)
      assert_received {:telemetry_event, @lag, measurements, _metadata}
      assert measurements.events_waiting == 1
      assert measurements.events_above_horizon == 1
      assert measurements.lag_seconds >= 300
    end

    test "a destination with nothing waiting reports zero lag", _ctx do
      destination = destination()
      attach_telemetry([@lag])

      assert :ok = sweep(slot_tick(destination))

      assert_received {:telemetry_event, @lag, measurements, %{kind: :https}}
      assert measurements == %{lag_seconds: 0, events_waiting: 0, events_above_horizon: 0}
    end

    test "lag is measured for halted destinations but not paused ones", _ctx do
      halted = destination(halted_reason: :rejected_batch, state: :failing)
      event!(halted, 1, ago(60))
      paused = destination([enabled: false], :splunk_hec)
      event!(paused, 1, ago(60))
      attach_telemetry([@lag])

      for tick <- Enum.uniq([slot_tick(halted), slot_tick(paused)]), do: sweep(tick)

      assert_received {:telemetry_event, @lag, %{events_waiting: 1}, %{kind: :https}}
      refute_received {:telemetry_event, @lag, _, %{kind: :splunk_hec}}
    end
  end

  # --- wiring ---------------------------------------------------------------------

  describe "configuration" do
    test "config.exs registers the queue and both cron entries" do
      oban = Application.fetch_env!(:kanban, Oban)
      assert Keyword.fetch!(oban, :queues)[:audit_stream] == 5

      {Oban.Plugins.Cron, opts} =
        oban |> Keyword.fetch!(:plugins) |> List.keyfind(Oban.Plugins.Cron, 0)

      crontab = Keyword.fetch!(opts, :crontab)

      assert {"* * * * *", Scheduler} in crontab
      assert {"29 * * * *", AttemptPruneWorker} in crontab
      assert crontab |> Enum.map(&elem(&1, 0)) |> Enum.count(&String.starts_with?(&1, "29 ")) == 1

      assert Scheduler.__opts__()[:queue] == :audit_stream
      assert Scheduler.__opts__()[:max_attempts] == 1
      assert AttemptPruneWorker.__opts__()[:queue] == :maintenance
    end
  end
end
