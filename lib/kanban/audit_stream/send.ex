defmodule Kanban.AuditStream.Send do
  @moduledoc """
  Sends one prepared batch for `Kanban.AuditStream.DispatchWorker` and
  records its outcome: steps 2 and 3 of a run
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.2, §8.4, §8.7).

    * **Send**, with no transaction open. The kind's adapter builds the
      request, the URL is checked again with `Kanban.Webhooks.UrlGuard`
      (`Kanban.AuditStream.Reachability`; DNS may have changed), and the POST
      goes through `Kanban.Webhooks.Transport` to the approved address. It
      runs in an unlinked task under `Kanban.TaskSupervisor`, stopped after
      `Kanban.AuditStream.DispatchWorker.send_deadline_ms/0`, and Finch stops
      waiting for the response after
      `Kanban.AuditStream.DispatchWorker.send_timeout_ms/0`. A send stopped
      either way is a timeout, and one whose task crashes is a failed
      connection.
    * **Record**, under the lease again (`Kanban.AuditStream.DispatchRows`):
      record an attempt, apply the outcome (`Kanban.AuditStream.Outcome`,
      paced by `Kanban.AuditStream.Pacing`) to the cursor and the
      destination, queue the follow-up job and release the lease. A run whose
      lease expired records nothing and queues a run now; a destination
      deleted while the POST was in flight records nothing.

  `batch_delivered` and `batch_failed` are emitted after the outcome
  commits, with the destination's kind and the attempt's outcome only.
  """

  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchRows
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Pacing
  alias Kanban.AuditStream.Payload
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reachability
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  require Logger

  @typedoc """
  A prepared batch: the kind's adapter, the locked destination as prepared,
  the Organization its events were built for, the batch, and the gap recorded
  while preparing it.
  """
  @type context :: %{
          required(:adapter) => module(),
          required(:destination) => Destination.t(),
          required(:organization) => Payload.organization(),
          required(:batch) => PendingBatch.batch(),
          required(:gap) => term()
        }

  @doc """
  Sends the prepared batch in `context` for destination `destination_id`
  and records its outcome under the lease `token`. `:drain` when the run
  sends the next batch itself before `deadline` (a monotonic time), else
  `:done`.
  """
  @spec deliver(context(), integer(), Ecto.UUID.t(), integer()) :: :drain | :done
  def deliver(context, destination_id, token, deadline) do
    context
    |> send_batch()
    |> record(destination_id, token, deadline)
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
          Transport.post(resolved, body, headers,
            request_timeout: DispatchWorker.send_timeout_ms()
          )
        end)

      {:error, reason} ->
        {:guard_error, reason}
    end
  end

  # The POST runs unlinked, so a crash in it is an outcome rather than the
  # end of the run, and a send that outlasts the deadline is stopped.
  defp within_deadline(post) do
    task = Task.Supervisor.async_nolink(Kanban.TaskSupervisor, post)

    case Task.yield(task, DispatchWorker.send_deadline_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> posted(result)
      {:exit, _reason} -> {:transport_error, :crashed}
      nil -> {:transport_error, %Req.TransportError{reason: :timeout}}
    end
  end

  defp posted({:ok, response}), do: {:response, response}
  defp posted({:error, error}), do: {:transport_error, error}

  # --- 3. record --------------------------------------------------------------

  # `:drain` when the run sends the next batch itself, else `:done`.
  defp record(sent, destination_id, token, deadline) do
    class = Outcome.classify(sent.result, sent.adapter, length(sent.batch.events))

    case Repo.transact(fn -> record_locked(sent, class, destination_id, token, deadline) end) do
      {:ok, {destination, step}} ->
        emit(class, destination, sent)
        if Pacing.continue?(step, destination), do: :drain, else: :done

      {:error, reason} ->
        not_recorded(reason, destination_id)
    end
  end

  defp not_recorded(reason, destination_id) do
    Logger.warning(
      "audit stream outcome for destination #{destination_id} not recorded: " <>
        not_recorded(reason)
    )

    requeue(reason, destination_id)
    :done
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

  defp record_locked(sent, class, destination_id, token, deadline) do
    with {:ok, destination} <- DispatchRows.lock_destination(destination_id),
         {:ok, cursor} <- DispatchRows.guard(destination_id, token) do
      error = Outcome.error_text(class, sent.result, sent.adapter)
      {plan, step} = plan(sent, class, error, destination, cursor, deadline)

      with {:ok, destination} <- apply_plan(plan, sent, class, error, destination, cursor) do
        {:ok, {destination, step}}
      end
    end
  end

  defp plan(sent, class, error, destination, cursor, deadline) do
    now = DateTime.utc_now()
    batch = Map.put(sent.batch, :pending_attempts, cursor.pending_attempts)
    step = next_step(class, destination, cursor, sent.batch.last, now, deadline)
    {class |> Outcome.plan(error, destination, batch, now) |> Pacing.adjust(step), step}
  end

  # Only a delivered batch drains or paces; every other outcome keeps the
  # follow-up its plan sets.
  defp next_step(:delivered, destination, cursor, last, now, deadline),
    do: Pacing.step(destination, cursor, last, now, deadline)

  defp next_step(_class, _destination, _cursor, _last, _now, _deadline), do: :follow_up

  defp apply_plan(plan, sent, class, error, destination, cursor) do
    with {:ok, _attempt} <- insert_attempt(destination.id, sent, class, error),
         {:ok, _cursor} <-
           DispatchRows.update_cursor(cursor, Map.merge(plan.cursor, Lease.release_attrs())),
         {:ok, destination} <- DispatchRows.apply_status(destination, plan),
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
