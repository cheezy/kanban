defmodule Kanban.AuditStream.Scheduler do
  @moduledoc """
  The minute sweep of audit log streaming (`Oban.Plugins.Cron`, every
  minute, on the `:audit_stream` queue;
  `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1, §13.1).

  There is no after-commit nudge (D9): `Kanban.AuditLog.event/2` can't tell
  when its caller's transaction commits. So this sweep is what starts every
  delivery, every retry that is due and every catch-up, and events reach a
  destination within about a minute. Each run:

    1. queues a `Kanban.AuditStream.DispatchWorker` run for every
       destination that is enabled, not halted, due, not leased by a running
       run and has an event waiting below the horizon
       (`Kanban.AuditStream.due_for_dispatch/2`). A run
       already queued is kept rather than queued twice, and a run lost to a
       unique race is made up by the next sweep;
    2. emits `[:kanban, :audit_stream, :lag_measured]` for the enabled
       destinations whose 15-minute slot this is
       (`Kanban.AuditStream.measure_lag/3`), so each is measured at most once
       every 15 minutes and the persisted event stays rare. Its metadata is
       the destination's kind only: no Organization id, destination name or
       host reaches telemetry (D8).

  The slot is the minute the cron tick was scheduled for, so a sweep that
  starts late still measures the tick's own slot. A run that fails is simply
  replaced by the next minute's.
  """

  use Oban.Worker, queue: :audit_stream, max_attempts: 1

  alias Kanban.AuditStream

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    now = DateTime.utc_now()

    for destination_id <- AuditStream.due_for_dispatch(now) do
      {:ok, _job} = AuditStream.enqueue_dispatch(destination_id)
    end

    minute = (job.scheduled_at || now).minute

    for lag <- AuditStream.measure_lag(minute, now) do
      Kanban.Telemetry.emit(
        [:kanban, :audit_stream, :lag_measured],
        %{
          lag_seconds: lag.lag_seconds,
          events_waiting: lag.events_waiting,
          events_above_horizon: lag.events_above_horizon
        },
        %{kind: lag.kind}
      )
    end

    :ok
  end
end
