defmodule Kanban.AuditStream.DispatchWorker do
  @moduledoc """
  Sends one destination's next batch of audit events, at least once and in
  commit order (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1-§8.4, §8.7,
  §8.8).

  One job per destination: it is unique on `destination_id` with `period:
  :infinity` in the states `available`, `scheduled` and `retryable`.
  `executing` is left out on purpose, so a running job can queue its own
  follow-up. Uniqueness only avoids redundant jobs; the lease
  (`Kanban.AuditStream.Lease`) is what stops two runs sending at once.

  ## A run

  A run is three short transactions, and none is open during the POST, so a
  slow destination never holds a pool connection, a transaction id or the
  snapshot horizon (§7.3):

    1. **Prepare.** Take the lease in one committed statement; while
       another run holds a live lease, this one sends nothing and snoozes
       until it expires. Then, with the destination and its
       cursor locked (in that order, the order a delete cascades in):
       end when the destination is paused or halted, or not yet due
       (`next_attempt_at`); halt it with `txid_reset` when the database's
       transaction id is below the cursor's (§8.8); halt it with
       `credentials_unreadable` when a secret it needs can't be decrypted,
       sending nothing and recording no attempt (D17); then re-read the
       pending batch or cut the next one (`Kanban.AuditStream.PendingBatch`),
       and commit it as pending.
    2. **Send.** Build the request with the kind's adapter, check the URL
       again with `Kanban.Webhooks.UrlGuard` (DNS may have changed), and POST
       it through `Kanban.Webhooks.Transport` to the approved address. The
       POST runs in a supervised task that is stopped after
       `send_deadline_ms/0` (45 seconds, inside the 60-second lease),
       connecting and sending the body included, and Finch stops waiting for
       the response after `send_timeout_ms/0`. A send stopped either way is
       a timeout, and one whose task crashes is a failed connection: both
       are recorded and retried like any transport error, so a destination
       that never answers in time still moves to Retrying and Failing.
    3. **Record.** Under the lease again: record an attempt and apply the
       outcome (`Kanban.AuditStream.Outcome`) to the cursor and the
       destination, record `audit_stream_failing` or
       `audit_stream_recovered` on a move into or out of Failing, queue the
       follow-up job for when the destination is next due, and release the
       lease. A run whose lease expired records nothing and queues a run
       now, so the batch is not left without a job; a destination deleted
       while the POST was in flight records nothing.

  The cursor moves only after a 2xx, past exactly the batch sent. A retry
  resends exactly the pending batch under the same `batch_id`. A filter
  change while a send is in flight does not interrupt it: on 2xx the cursor
  moves past it as usual, and the next run cuts under the new settings.

  `batch_delivered` and `batch_failed` are emitted after the outcome
  commits, with the destination's kind and the attempt's outcome only.

  `perform/1` returns `:ok` on every path it handles: the destination's own
  `next_attempt_at` paces retries, not Oban's attempts. The one exception
  is a live lease: the job snoozes until it expires, so a run that crashed
  holding the lease is retried rather than ended. Oban's own attempts
  (`max_attempts` 20, `backoff/1` just past the lease) only cover a run
  that crashes outside the send, and `timeout/1` (55 seconds) is the last
  resort against one that hangs there.
  """

  use Oban.Worker,
    queue: :audit_stream,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:destination_id],
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream
  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reachability
  alias Kanban.Organizations.Organization
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  require Logger

  @send_timeout_ms 30_000
  @send_deadline_ms 45_000
  @run_timeout_ms 55_000

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
  The most milliseconds a whole run may take before Oban kills it: 55
  seconds, inside the 60-second lease. A last resort: the send is already
  stopped at `send_deadline_ms/0`.
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
      {:ok, token} -> run(destination_id, token)
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
  # it prepares; `perform/1` is the only caller in production.
  @doc false
  def run(destination_id, token) do
    case Repo.transact(fn -> prepare(destination_id, token) end) do
      {:ok, {:send, context}} -> context |> send_batch() |> record(destination_id, token)
      {:ok, :stopped} -> :ok
      {:error, _gone_or_lost} -> :ok
    end
  end

  # --- 1. prepare ------------------------------------------------------------

  defp prepare(destination_id, token) do
    with {:ok, destination} <- lock_destination(destination_id),
         {:ok, cursor} <- guard(destination_id, token) do
      destination
      |> check(cursor)
      |> prepared(destination, cursor)
    end
  end

  defp check(destination, cursor) do
    cond do
      not destination.enabled or not is_nil(destination.halted_reason) ->
        :stop

      not due?(cursor) ->
        {:not_due, cursor.next_attempt_at}

      txid_reset?(cursor) ->
        {:halt, :txid_reset, Outcome.txid_reset_reason()}

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

    with {:ok, _destination} <- apply_status(destination, plan) do
      stop(cursor, plan.cursor)
    end
  end

  defp prepared({:send, adapter}, destination, cursor) do
    organization = organization(destination.organization_id)

    case PendingBatch.prepare(destination, cursor, organization, horizon_opts()) do
      {:ok, batch, attrs} ->
        with {:ok, _cursor} <- update_cursor(cursor, attrs) do
          {:ok,
           {:send,
            %{
              adapter: adapter,
              destination: destination,
              organization: organization,
              batch: batch
            }}}
        end

      {:empty, attrs} ->
        stop(cursor, attrs)
    end
  end

  defp stop(cursor, attrs) do
    with {:ok, _cursor} <- update_cursor(cursor, Map.merge(attrs, Lease.release_attrs())) do
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
  # rows get ids below every cursor's (§8.8).
  defp txid_reset?(cursor) do
    %{rows: [[current]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    current < max(cursor.last_txid, cursor.pending_last_txid || 0)
  end

  # An unreadable previous signing secret is never needed: rotation drops it.
  defp needed_unreadable(destination),
    do: Destination.unreadable_secrets(destination) -- [:previous_signing_secret]

  defp organization(organization_id) do
    query =
      from(o in Organization, where: o.id == ^organization_id, select: %{id: o.id, name: o.name})

    Repo.one!(query)
  end

  defp horizon_opts do
    case Application.get_env(:kanban, __MODULE__, [])[:horizon] do
      {module, function} -> [horizon: apply(module, function, [])]
      nil -> []
    end
  end

  # --- 2. send (no transaction open) ----------------------------------------

  defp send_batch(
         %{adapter: adapter, destination: destination, organization: organization, batch: batch} =
           context
       ) do
    {url, headers, body} =
      adapter.build_request(destination, %{
        batch_id: batch.batch_id,
        events: batch.payloads,
        organization: organization
      })

    started_at = DateTime.utc_now()
    start = System.monotonic_time()
    result = post(url, body, headers)
    duration_ms = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

    Map.merge(context, %{
      result: result,
      started_at: started_at,
      duration_ms: duration_ms
    })
  end

  defp post(url, body, headers) do
    case Reachability.check_url(url) do
      {:ok, resolved} ->
        within_deadline(fn ->
          Transport.post(resolved, body, headers, request_timeout: @send_timeout_ms)
        end)

      {:error, reason} ->
        {:guard_error, reason}
    end
  end

  # The POST runs unlinked, so a crash in it is an outcome rather than the
  # end of the run, and a send that outlasts the deadline is stopped.
  defp within_deadline(post) do
    task = Task.Supervisor.async_nolink(Kanban.TaskSupervisor, post)

    case Task.yield(task, send_deadline_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> posted(result)
      {:exit, _reason} -> {:transport_error, :crashed}
      nil -> {:transport_error, %Req.TransportError{reason: :timeout}}
    end
  end

  defp posted({:ok, response}), do: {:response, response}
  defp posted({:error, error}), do: {:transport_error, error}

  # --- 3. record --------------------------------------------------------------

  defp record(sent, destination_id, token) do
    class = Outcome.classify(sent.result, sent.adapter, length(sent.batch.events))

    case Repo.transact(fn -> record_locked(sent, class, destination_id, token) end) do
      {:ok, destination} ->
        emit(class, destination, sent)

      {:error, reason} ->
        Logger.warning(
          "audit stream outcome for destination #{destination_id} not recorded: " <>
            not_recorded(reason)
        )

        requeue(reason, destination_id)
    end

    :ok
  end

  # A run that lost its lease moved nothing, so the batch still needs a run:
  # queue one now. It snoozes while another run holds the lease.
  defp requeue(:lease_lost, destination_id) do
    {:ok, _job} = AuditStream.enqueue_dispatch(destination_id)
    :ok
  end

  defp requeue(_reason, _destination_id), do: :ok

  # A bounded reason for the log: never a changeset, which holds the values.
  defp not_recorded(reason) when reason in [:gone, :lease_lost], do: Atom.to_string(reason)
  defp not_recorded(_reason), do: "invalid"

  defp record_locked(sent, class, destination_id, token) do
    with {:ok, destination} <- lock_destination(destination_id),
         {:ok, cursor} <- guard(destination_id, token) do
      error = Outcome.error_text(class, sent.result, sent.adapter)
      batch = Map.put(sent.batch, :pending_attempts, cursor.pending_attempts)
      plan = Outcome.plan(class, error, destination, batch, DateTime.utc_now())
      apply_plan(plan, sent, class, error, destination, cursor)
    end
  end

  defp apply_plan(plan, sent, class, error, destination, cursor) do
    with {:ok, _attempt} <- insert_attempt(destination.id, sent, class, error),
         {:ok, _cursor} <- update_cursor(cursor, Map.merge(plan.cursor, Lease.release_attrs())),
         {:ok, destination} <- apply_status(destination, plan),
         :ok <- follow_up(destination, plan.follow_up_at) do
      {:ok, destination}
    end
  end

  defp insert_attempt(destination_id, sent, class, error) do
    {_first_txid, first_id} = sent.batch.first
    {_last_txid, last_id} = sent.batch.last

    %Attempt{}
    |> Attempt.changeset(%{
      destination_id: destination_id,
      batch_id: sent.batch.batch_id,
      started_at: sent.started_at,
      duration_ms: sent.duration_ms,
      event_count: length(sent.batch.events),
      bytes: sent.batch.bytes,
      first_event_id: first_id,
      last_event_id: last_id,
      http_status: http_status(sent.result),
      outcome: Outcome.attempt_outcome(class),
      error: error
    })
    |> Repo.insert()
  end

  defp http_status({:response, %{status: status}}), do: status
  defp http_status(_result), do: nil

  # A paused or halted destination gets no follow-up; the sweep, or the
  # person clearing the halt, queues the next run.
  defp follow_up(_destination, nil), do: :ok

  defp follow_up(%Destination{enabled: true, halted_reason: nil} = destination, due_at) do
    {:ok, _job} = AuditStream.enqueue_dispatch(destination.id, scheduled_at: due_at)
    :ok
  end

  defp follow_up(_destination, _due_at), do: :ok

  # --- shared ------------------------------------------------------------------

  defp lock_destination(destination_id) do
    query = from(d in Destination, where: d.id == ^destination_id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :gone}
      destination -> {:ok, destination}
    end
  end

  defp guard(destination_id, token) do
    case Lease.guard(destination_id, token) do
      nil -> {:error, :lease_lost}
      cursor -> {:ok, cursor}
    end
  end

  defp update_cursor(cursor, attrs) when map_size(attrs) == 0, do: {:ok, cursor}
  defp update_cursor(cursor, attrs), do: cursor |> Cursor.changeset(attrs) |> Repo.update()

  # Only the status fields are written, so a secret that loaded as
  # :unreadable is never dumped and lock_version never moves.
  defp apply_status(destination, plan) do
    with {:ok, updated} <-
           destination |> Destination.status_changeset(plan.destination) |> Repo.update() do
      record_audit(plan.audit, updated)
      {:ok, updated}
    end
  end

  defp record_audit(nil, _destination), do: :ok
  defp record_audit(:recovered, destination), do: DestinationEvents.recovered(destination)

  defp record_audit({:failing, reason}, destination),
    do: DestinationEvents.failing(destination, reason)

  defp emit(:delivered, destination, sent) do
    Kanban.Telemetry.emit(
      [:kanban, :audit_stream, :batch_delivered],
      %{
        count: 1,
        events: length(sent.batch.events),
        bytes: sent.batch.bytes,
        duration_ms: sent.duration_ms
      },
      %{kind: destination.kind}
    )
  end

  defp emit(class, destination, sent) do
    Kanban.Telemetry.emit(
      [:kanban, :audit_stream, :batch_failed],
      %{count: 1, duration_ms: sent.duration_ms},
      %{kind: destination.kind, outcome: Outcome.attempt_outcome(class)}
    )
  end
end
