defmodule Kanban.AuditStream.DispatchWorker do
  @moduledoc """
  Sends one destination's next batch of audit events, at least once and in
  commit order (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1-§8.4, §8.7,
  §8.8).

  One job per destination: it is unique on `destination_id` with `period:
  :infinity` in the states `available`, `scheduled` and `retryable`.
  `executing` is left out on purpose, so a running job can queue its own
  follow-up. Uniqueness only avoids redundant jobs; the lease
  (`Kanban.AuditStream.Lease`) is what stops two runs sending at once. A
  run queued for a destination that already has a scheduled one moves that
  job to its own time, so a follow-up is never absorbed by a job snoozing
  behind a lease, such as one the sweep queued between two drained batches.

  ## A run

  A run is three short transactions, and none is open during the POST, so a
  slow destination never holds a pool connection, a transaction id or the
  snapshot horizon (§7.3):

    1. **Prepare.** Take the lease in one committed statement; while
       another run holds a live lease, this one sends nothing and snoozes
       until it expires. Then, with the destination and its
       cursor locked (in that order, the order a delete cascades in):
       end when the destination is halted; halt it with `txid_reset` when
       the database's transaction id is at or below the cursor's (§8.8),
       even when it is paused or not yet due, because the move can no
       longer be seen once this server's ids pass the cursor (the sweep
       queues a run for such a cursor even with nothing waiting); end when
       it is paused, or not yet due (`next_attempt_at`); halt it with
       `credentials_unreadable` when a secret it needs can't be decrypted,
       sending nothing and recording no attempt (D17); for a kind with a
       `max_event_age` (Datadog), move the cursor past the events at the
       head of the backlog that are too old for it and record them as a
       `too_old` gap (`Kanban.AuditStream.AgeLimit`); then re-read the
       pending batch or cut the next one (`Kanban.AuditStream.PendingBatch`),
       never holding a too-old event, and commit it as pending.
    2. **Send** (`Kanban.AuditStream.Send`). Build the request with the kind's adapter, check the URL
       again with `Kanban.Webhooks.UrlGuard` (DNS may have changed), and POST
       it through `Kanban.Webhooks.Transport` to the approved address. The
       POST runs in a supervised task that is stopped after
       `send_deadline_ms/0` (45 seconds, inside the 60-second lease),
       connecting and sending the body included, and Finch stops waiting for
       the response after `send_timeout_ms/0`. A send stopped either way is
       a timeout, and one whose task crashes is a failed connection: both
       are recorded and retried like any transport error, so a destination
       that never answers in time still moves to Retrying and Failing.
    3. **Record** (`Kanban.AuditStream.Send`). Under the lease again: record an attempt and apply the
       outcome (`Kanban.AuditStream.Outcome`) to the cursor and the
       destination, record `audit_stream_failing` or
       `audit_stream_recovered` on a move into or out of Failing, queue the
       follow-up job for when the destination is next due, and release the
       lease. A run whose lease expired records nothing and queues a run
       now, so the batch is not left without a job; a destination deleted
       while the POST was in flight records nothing.

  ## Draining and pacing

  After a delivered batch, `Kanban.AuditStream.Pacing` decides what follows
  (§8.1, §8.5): nothing when no more is waiting; when the next waiting event
  is more than 10 minutes old, a follow-up 2 seconds ahead, with
  `next_attempt_at` set to match; otherwise the run takes the lease again
  and sends the next batch itself, for up to 30 seconds from its start, and
  then queues its own follow-up for now. Every batch is a run of its own
  three transactions under its own lease, so a send always ends inside the
  lease it started under, however long the run drains.

  The cursor moves only after a 2xx, past exactly the batch sent. A retry
  resends exactly the pending batch under the same `batch_id`. A filter
  change while a send is in flight does not interrupt it: on 2xx the cursor
  moves past it as usual, and the next run cuts under the new settings.

  `batch_delivered` and `batch_failed` are emitted by
  `Kanban.AuditStream.Send` after the outcome commits, with the destination's
  kind and the attempt's outcome only. Prepare and record lock and write the
  rows through `Kanban.AuditStream.DispatchRows`.

  `perform/1` returns `:ok` on every path it handles: the destination's own
  `next_attempt_at` paces retries, not Oban's attempts. The one exception
  is a live lease: the job snoozes until it expires, so a run that crashed
  holding the lease is retried rather than ended. Oban's own attempts
  (`max_attempts` 20, `backoff/1` just past the lease) only cover a run
  that crashes outside the send, and `timeout/1` (85 seconds) is the last
  resort against one that hangs there.

  Settings, for tests only: `config :kanban, #{inspect(__MODULE__)}`
  with `:send_deadline_ms`, `:horizon` (a `{module, function}`),
  `:drain_ms` and `:batch_size`.
  """

  use Oban.Worker,
    queue: :audit_stream,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:destination_id],
      states: [:available, :scheduled, :retryable]
    ],
    replace: [scheduled: [:scheduled_at]]

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream
  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.AgeLimit
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchRows
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Pacing
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Send
  alias Kanban.Organizations.Organization
  alias Kanban.Repo

  @send_timeout_ms 30_000
  @send_deadline_ms 45_000
  @run_timeout_ms 85_000

  @doc """
  A dispatch job for `destination_id`. `opts` are `Oban.Worker.new/2`
  options, such as `:scheduled_at`.
  """
  @spec job(integer(), keyword()) :: Oban.Job.changeset()
  def job(destination_id, opts \\ []) when is_integer(destination_id),
    do: new(%{destination_id: destination_id}, opts)

  @doc """
  The most milliseconds a send waits for the destination's response once
  the body is sent (Finch's `request_timeout`, best effort): half of
  `Kanban.AuditStream.Lease.ttl/0`.
  """
  @spec send_timeout_ms() :: pos_integer()
  def send_timeout_ms, do: @send_timeout_ms

  @doc """
  The most milliseconds a send may take, connecting, sending the body and
  reading the answer included, before it is stopped and recorded as a
  timeout: 45 seconds, inside the 60-second lease. Configurable as
  `config :kanban, #{inspect(__MODULE__)}, send_deadline_ms: ...` for tests.
  """
  @spec send_deadline_ms() :: pos_integer()
  def send_deadline_ms,
    do: Application.get_env(:kanban, __MODULE__, [])[:send_deadline_ms] || @send_deadline_ms

  @doc """
  The most milliseconds a whole run may take before Oban kills it: 85
  seconds, the 30 seconds a run may drain for, plus one last send stopped
  at `send_deadline_ms/0`, plus 10 seconds to prepare and record it. A last
  resort: each batch is sent under a lease of its own, which the send
  always ends inside.
  """
  @impl Oban.Worker
  def timeout(_job), do: @run_timeout_ms

  @doc """
  Seconds before Oban retries a run that crashed: just past the lease it may
  still hold. Never a delivery backoff, which the destination's own
  `consecutive_failures` and `next_attempt_at` set.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: Lease.ttl() + 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"destination_id" => destination_id}})
      when is_integer(destination_id) do
    case Lease.take(destination_id) do
      {:ok, token} -> run(destination_id, token, Pacing.drain_deadline())
      :held -> held(destination_id)
    end
  end

  # Another run holds the lease, or a run that crashed left it behind: come
  # back once it expires. No cursor means the destination is gone.
  defp held(destination_id) do
    case Lease.seconds_left(destination_id) do
      nil -> :ok
      seconds -> {:snooze, seconds + 1}
    end
  end

  # Public for the tests of a run whose lease or destination is gone before
  # it prepares; `perform/1` is the only caller in production. `deadline` is
  # the monotonic time after which the run sends no more batches.
  @doc false
  def run(destination_id, token, deadline \\ Pacing.drain_deadline()) do
    case Repo.transact(fn -> prepare(destination_id, token) end) do
      {:ok, {:send, context}} ->
        Gaps.emit_recorded(context.gap)

        context
        |> Send.deliver(destination_id, token, deadline)
        |> drain(destination_id, deadline)

      {:ok, {:stopped, gap}} ->
        Gaps.emit_recorded(gap)

      {:ok, :stopped} ->
        :ok

      {:error, _gone_or_lost} ->
        :ok
    end
  end

  # The next batch, under a lease of its own. A run holding it already sends
  # the rest.
  defp drain(:drain, destination_id, deadline) do
    case Lease.take(destination_id) do
      {:ok, token} -> run(destination_id, token, deadline)
      :held -> :ok
    end
  end

  defp drain(:done, _destination_id, _deadline), do: :ok

  # --- 1. prepare ------------------------------------------------------------

  defp prepare(destination_id, token) do
    with {:ok, destination} <- DispatchRows.lock_destination(destination_id),
         {:ok, cursor} <- DispatchRows.guard(destination_id, token) do
      destination
      |> check(cursor)
      |> prepared(destination, cursor)
    end
  end

  defp check(destination, cursor) do
    cond do
      not is_nil(destination.halted_reason) ->
        :stop

      # Before pause and backoff: a move missed now is never seen.
      txid_reset?(cursor) ->
        {:halt, :txid_reset, Outcome.txid_reset_reason()}

      not destination.enabled ->
        :stop

      not due?(cursor) ->
        {:not_due, cursor.next_attempt_at}

      needed_unreadable(destination) != [] ->
        {:halt, :credentials_unreadable, Outcome.credentials_unreadable_reason()}

      true ->
        adapter(destination.kind)
    end
  end

  defp prepared(:stop, _destination, cursor), do: stop(cursor, %{})

  defp prepared({:not_due, due_at}, destination, cursor) do
    {:ok, _job} = AuditStream.enqueue_dispatch(destination.id, scheduled_at: due_at)
    stop(cursor, %{})
  end

  defp prepared({:halt, reason, text}, destination, cursor) do
    plan = Outcome.halt(destination, reason, text, DateTime.utc_now())

    with {:ok, _destination} <- DispatchRows.apply_status(destination, plan) do
      stop(cursor, plan.cursor)
    end
  end

  defp prepared({:send, adapter}, destination, cursor) do
    read_opts = Pacing.read_opts()
    older_than = AgeLimit.threshold(adapter, DateTime.utc_now())

    with {:ok, cursor, gap} <- AgeLimit.skip(destination, cursor, older_than, read_opts) do
      organization = organization(destination.organization_id)
      opts = [{:older_than, older_than} | read_opts]

      destination
      |> PendingBatch.prepare(cursor, organization, opts)
      |> cut({adapter, destination, cursor, gap})
    end
  end

  # The batch carries the Organization its events were built for: the
  # snapshot stored when it was cut, or, for a batch cut before the snapshot
  # existed, the live row read once and stored then (D428).
  defp cut({:ok, batch, attrs}, {adapter, destination, cursor, gap}) do
    with {:ok, _cursor} <- DispatchRows.update_cursor(cursor, attrs) do
      {:ok,
       {:send,
        %{
          adapter: adapter,
          destination: destination,
          organization: batch.organization,
          batch: batch,
          gap: gap
        }}}
    end
  end

  # Every waiting event was too old: the cursor has moved past them all.
  defp cut({:empty, attrs}, {_adapter, _destination, cursor, nil}),
    do: stop(cursor, attrs)

  defp cut({:empty, attrs}, {_adapter, _destination, cursor, gap}) do
    with {:ok, :stopped} <- stop(cursor, attrs), do: {:ok, {:stopped, gap}}
  end

  defp stop(cursor, attrs) do
    with {:ok, _cursor} <-
           DispatchRows.update_cursor(cursor, Map.merge(attrs, Lease.release_attrs())) do
      {:ok, :stopped}
    end
  end

  # A kind whose adapter is not written yet sends nothing.
  defp adapter(kind) do
    case Adapter.module_for(kind) do
      nil -> :stop
      adapter -> {:send, adapter}
    end
  end

  defp due?(%Cursor{next_attempt_at: nil}), do: true
  defp due?(%Cursor{next_attempt_at: at}), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  # Transaction ids belong to one Postgres server; after a logical move new
  # rows get ids at or below every cursor's (§8.8). A cursor holds committed
  # rows' txids, always below this running transaction's on the same server.
  defp txid_reset?(cursor) do
    %{rows: [[current]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    current <= max(cursor.last_txid, cursor.pending_last_txid || 0)
  end

  # An unreadable previous signing secret is never needed: rotation drops it.
  defp needed_unreadable(destination),
    do: Destination.unreadable_secrets(destination) -- [:previous_signing_secret]

  defp organization(organization_id) do
    query =
      from(o in Organization, where: o.id == ^organization_id, select: %{id: o.id, name: o.name})

    Repo.one!(query)
  end
end
