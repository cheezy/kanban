defmodule Kanban.AuditStream.Pacing do
  @moduledoc """
  What a run of `Kanban.AuditStream.DispatchWorker` does after a delivered
  batch: drain, pace or stop (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1,
  §8.5, §12.5).

    * **Caught up.** Nothing more is waiting below the horizon: no follow-up.
      The minute sweep (`Kanban.AuditStream.Scheduler`) queues the next run
      once something is.
    * **Paced.** The next waiting event is more than 10 minutes old, so the
      destination is catching up: it sends at most one batch every 2 seconds.
      The follow-up job and the cursor's `next_attempt_at` are both set 2
      seconds ahead, so a run that comes early, the sweep's included, ends
      as not due. Nothing sleeps inside the job, which would hold a slot of
      the `:audit_stream` queue that other Organizations' live events need.
    * **Draining.** More is waiting and it is recent: the run sends the next
      batch itself, taking the lease again, for up to 30 seconds from its
      start. A run that drains queues no follow-up between batches; if it
      stops between committing one batch and taking the lease for the next,
      the minute sweep queues the next run.
    * **Follow-up.** The 30 seconds are up with more still waiting: the run
      queues its own follow-up for now and ends. `executing` is not one of
      the worker's unique states, so the insert is never dropped as a
      duplicate of the run making it.

  Catching up is judged on the next event in commit order
  (`Kanban.AuditStream.Reader.next_waiting_at/3`), one indexed row, rather
  than the exact oldest waiting event, which would count the whole backlog
  after every batch. Commit order is close to time order, so against 10
  minutes the two agree.

  The drain budget and the batch size are settings for the worker's tests:
  `config :kanban, Kanban.AuditStream.DispatchWorker, drain_ms: ...,
  batch_size: ...`. The 10 minutes and the 2 seconds are fixed.
  """

  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader

  @drain_ms 30_000
  @catch_up_seconds 600
  @pace_ms 2_000

  @type step :: :caught_up | :drain | :follow_up | {:paced, DateTime.t()}

  @doc """
  How long a run keeps sending, in milliseconds from its start: 30 seconds,
  or the worker's `:drain_ms` setting.
  """
  @spec drain_ms() :: non_neg_integer()
  def drain_ms, do: setting(:drain_ms) || @drain_ms

  @doc "How old the next waiting event must be, in seconds, before a destination is catching up."
  @spec catch_up_seconds() :: pos_integer()
  def catch_up_seconds, do: @catch_up_seconds

  @doc "The least time, in milliseconds, between two batches of a destination catching up."
  @spec pace_ms() :: pos_integer()
  def pace_ms, do: @pace_ms

  @doc "The monotonic time, in milliseconds, after which a run starting now sends no more batches."
  @spec drain_deadline() :: integer()
  def drain_deadline, do: System.monotonic_time(:millisecond) + drain_ms()

  @doc """
  The `Kanban.AuditStream.PendingBatch` options from the worker's settings:
  `:horizon`, a `{module, function}` whose result is the horizon, and
  `:batch_size`. Both are for tests; production sets neither.
  """
  @spec read_opts() :: keyword()
  def read_opts do
    horizon =
      case setting(:horizon) do
        {module, function} -> [horizon: apply(module, function, [])]
        nil -> []
      end

    case setting(:batch_size) do
      nil -> horizon
      size -> [{:batch_size, size} | horizon]
    end
  end

  @doc """
  Whether a destination whose next waiting event was inserted `at` is
  catching up at `now`: when that event is strictly more than 10 minutes old.
  """
  @spec catching_up?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def catching_up?(nil, _now), do: false

  def catching_up?(%DateTime{} = at, %DateTime{} = now),
    do: DateTime.diff(now, at, :microsecond) > @catch_up_seconds * 1_000_000

  @doc """
  What a run does after delivering a batch that ended at `last` for
  `destination` at `cursor` (the destination's filters and the cursor's
  `not_before` apply), at `now`, with its drain `deadline`.
  """
  @spec step(map(), map(), Reader.pair(), DateTime.t(), integer()) :: step()
  def step(destination, cursor, last, now, deadline) do
    opts = PendingBatch.filters(destination, cursor) ++ Keyword.take(read_opts(), [:horizon])

    destination.organization_id
    |> Reader.next_waiting_at(last, opts)
    |> next_step(now, deadline)
  end

  defp next_step(nil, _now, _deadline), do: :caught_up

  defp next_step(at, now, deadline) do
    cond do
      catching_up?(at, now) -> {:paced, DateTime.add(now, @pace_ms, :millisecond)}
      System.monotonic_time(:millisecond) < deadline -> :drain
      true -> :follow_up
    end
  end

  @doc """
  The delivered `plan` (`Kanban.AuditStream.Outcome.plan/5`) adjusted for
  `step`: no follow-up when caught up or draining, the follow-up and
  `next_attempt_at` 2 seconds ahead when paced, and the plan's own follow-up
  for now otherwise.
  """
  @spec adjust(map(), step()) :: map()
  def adjust(plan, step) when step in [:caught_up, :drain], do: %{plan | follow_up_at: nil}

  def adjust(plan, {:paced, at}),
    do: %{plan | follow_up_at: at, cursor: Map.put(plan.cursor, :next_attempt_at, at)}

  def adjust(plan, :follow_up), do: plan

  @doc "Whether the run sends the next batch itself."
  @spec continue?(step(), map()) :: boolean()
  def continue?(:drain, %{enabled: true, halted_reason: nil}), do: true
  def continue?(_step, _destination), do: false

  defp setting(key), do: Application.get_env(:kanban, DispatchWorker, [])[key]
end
