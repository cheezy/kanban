defmodule Kanban.AuditStream.BatchActions do
  @moduledoc """
  The two ways an org-admin takes a destination out of a `rejected_batch`
  halt (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4, §10.4): **Retry
  now**, for when the cause has been fixed at the tool's end, and **Skip this
  batch**. Stride never skips a batch on its own (D3).

  Both work only on a destination halted with `rejected_batch`. Any other
  halt, and a configuration error or an unauthorized answer (which leave
  `halted_reason` unset), gets `{:error, :not_rejected_batch}`: skipping
  cannot fix a configuration, a blocked address, a database move or a lost
  key, and would only lose events.

  Both write under the destination's lease (`Kanban.AuditStream.Lease`,
  §8.1), exactly as a dispatch run does, so neither can move the cursor
  while a run is sending. The lease is taken in its own committed statement
  before the transaction, and a destination whose lease a run holds gets
  `{:error, :busy}`. Inside the transaction the Organization, the
  destination and the cursor are locked in that order and the caller's
  rights are read again (`Kanban.AuditStream.Destinations.fetch_authorized/3`),
  the cursor only through `Lease.guard/2`. The cursor update releases the
  lease in the same commit that queues the next dispatch run, so that run
  never snoozes behind it; any other exit releases it afterwards.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.AuditStream.Status
  alias Kanban.Repo

  @type error :: :unauthorized | :not_found | :not_rejected_batch | :busy

  @doc """
  Clears a `rejected_batch` halt, resets the pending batch's
  `pending_attempts` and `next_attempt_at`, and queues a dispatch run. The
  pending batch itself is kept, so the run resends exactly it under the same
  `batch_id`.
  """
  @spec retry_now(Scope.t() | nil, Destination.t()) :: {:ok, Destination.t()} | {:error, error()}
  def retry_now(scope, %Destination{id: id}), do: under_lease(scope, id, &retry_locked/3)

  @doc """
  Skips the pending batch of a destination halted with `rejected_batch`:
  records an attempt with outcome `skipped` and an
  `audit_stream_batch_skipped` event, which every destination receives, moves
  the cursor past exactly the pending batch, discards it, clears the halt and
  queues a dispatch run.
  """
  @spec skip_batch(Scope.t() | nil, Destination.t()) :: {:ok, Destination.t()} | {:error, error()}
  def skip_batch(scope, %Destination{id: id}), do: under_lease(scope, id, &skip_locked/3)

  # The destination is looked up and checked first, so a caller can't take
  # the lease on another Organization's destination, and a refused action
  # never takes it; both are checked again under the locks.
  defp under_lease(scope, id, locked) do
    with {:ok, leased} <- lease(scope, id) do
      try do
        fn -> transact(leased, locked) end |> Repo.transact() |> SigningSecrets.conceal()
      after
        Lease.release(leased.id, leased.token)
      end
    end
  end

  defp lease(scope, id) do
    with {:ok, actor, organization_id} <- Destinations.authorize(scope),
         {:ok, destination} <- Destinations.fetch(organization_id, id),
         :ok <- require_rejected(destination),
         {:ok, token} <- take(destination.id) do
      {:ok, %{actor: actor, organization_id: organization_id, id: destination.id, token: token}}
    end
  end

  defp transact(leased, locked) do
    with {:ok, fresh, cursor} <- lock(leased),
         do: locked.(fresh, cursor, leased.actor)
  end

  defp take(destination_id) do
    case Lease.take(destination_id) do
      {:ok, token} -> {:ok, token}
      :held -> {:error, :busy}
    end
  end

  defp lock(%{actor: actor, organization_id: organization_id, id: id, token: token}) do
    with {:ok, fresh} <- Destinations.fetch_authorized(actor, organization_id, id),
         :ok <- require_rejected(fresh) do
      case Lease.guard(id, token) do
        %Cursor{} = cursor -> {:ok, fresh, cursor}
        nil -> {:error, :busy}
      end
    end
  end

  defp require_rejected(%Destination{halted_reason: :rejected_batch}), do: :ok
  defp require_rejected(%Destination{}), do: {:error, :not_rejected_batch}

  # --- retry now --------------------------------------------------------------

  defp retry_locked(destination, cursor, _actor) do
    cursor_attrs = Map.merge(%{pending_attempts: 0, next_attempt_at: nil}, Lease.release_attrs())

    with {:ok, _cursor} <- update_cursor(cursor, cursor_attrs),
         {:ok, destination} <- clear_halt(destination),
         {:ok, _job} <- AuditStream.enqueue_dispatch(destination.id) do
      {:ok, destination}
    end
  end

  # --- skip this batch --------------------------------------------------------

  defp skip_locked(destination, cursor, actor) do
    with %{} = batch <-
           Status.rejected_batch(destination, cursor) || {:error, :not_rejected_batch},
         {:ok, _attempt} <- insert_skipped(destination, batch),
         {:ok, _cursor} <- update_cursor(cursor, past(cursor, destination)),
         {:ok, destination} <- clear_halt(destination),
         {:ok, _job} <- AuditStream.enqueue_dispatch(destination.id) do
      DestinationEvents.batch_skipped(destination, actor, batch)
      {:ok, destination}
    end
  end

  defp insert_skipped(destination, batch) do
    %Attempt{}
    |> Attempt.changeset(%{
      destination_id: destination.id,
      batch_id: batch.batch_id,
      started_at: DateTime.utc_now(),
      event_count: batch.events,
      first_event_id: batch.first_event_id,
      last_event_id: batch.last_event_id,
      http_status: batch.http_status,
      outcome: :skipped
    })
    |> Repo.insert()
  end

  # Past exactly the pending batch's last event, whatever the filters now
  # hold back, and with the pending batch discarded.
  defp past(cursor, destination) do
    Outcome.cleared_pending_attrs()
    |> Map.merge(Lease.release_attrs())
    |> Map.merge(%{
      last_txid: cursor.pending_last_txid,
      last_event_id: cursor.pending_last_id,
      last_inserted_at: inserted_at(destination.organization_id, cursor.pending_last_id)
    })
  end

  # Read from the row itself, so an event the filters leave out still gives
  # its time; nil when retention has deleted it.
  defp inserted_at(organization_id, event_id) do
    query =
      from(e in AuditEvent,
        where: e.id == ^event_id and e.organization_id == ^organization_id,
        select: e.inserted_at
      )

    Repo.one(query)
  end

  # --- shared -----------------------------------------------------------------

  defp update_cursor(cursor, attrs), do: cursor |> Cursor.changeset(attrs) |> Repo.update()

  # Only the status fields are written, so a secret that loaded as
  # :unreadable is never dumped and lock_version never moves.
  defp clear_halt(destination),
    do: destination |> Destination.status_changeset(%{halted_reason: nil}) |> Repo.update()
end
