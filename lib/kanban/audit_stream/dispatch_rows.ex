defmodule Kanban.AuditStream.DispatchRows do
  @moduledoc """
  The row locks and writes both transactions of a
  `Kanban.AuditStream.DispatchWorker` run make under the lease
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1, §8.4): prepare, in the
  worker, and record, in `Kanban.AuditStream.Send`.

  Each run locks the destination first and then guards the cursor with the
  lease (`Kanban.AuditStream.Lease.guard/2`), the order a delete cascades
  in. Call these inside a transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Lease
  alias Kanban.Notifications
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Repo

  @doc """
  Locks destination `destination_id` `FOR UPDATE`. `{:error, :gone}` when it
  has been deleted.
  """
  @spec lock_destination(integer()) :: {:ok, Destination.t()} | {:error, :gone}
  def lock_destination(destination_id) do
    query = from(d in Destination, where: d.id == ^destination_id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :gone}
      destination -> {:ok, destination}
    end
  end

  @doc """
  The cursor of destination `destination_id`, locked, while `token` still
  holds its lease; `{:error, :lease_lost}` once it does not.
  """
  @spec guard(integer(), Ecto.UUID.t()) :: {:ok, Cursor.t()} | {:error, :lease_lost}
  def guard(destination_id, token) do
    case Lease.guard(destination_id, token) do
      nil -> {:error, :lease_lost}
      cursor -> {:ok, cursor}
    end
  end

  @doc """
  Writes `attrs` to `cursor`. Empty `attrs` write nothing.
  """
  @spec update_cursor(Cursor.t(), map()) :: {:ok, Cursor.t()} | {:error, Ecto.Changeset.t()}
  def update_cursor(cursor, attrs) when map_size(attrs) == 0, do: {:ok, cursor}
  def update_cursor(cursor, attrs), do: cursor |> Cursor.changeset(attrs) |> Repo.update()

  @doc """
  Writes the status fields of a `Kanban.AuditStream.Outcome` plan to
  `destination`, then records the plan's `audit_stream_failing` or
  `audit_stream_recovered` event, if any.

  In the same transaction it enqueues the org-admin email the plan calls for
  (`Kanban.Notifications.AuditStreamAlerts.status_alert/3`): Failing,
  recovered or the re-seed, writing `failing_emailed_at` or
  `recovered_emailed_at` with the status fields so the hourly throttle holds.
  """
  @spec apply_status(Destination.t(), map()) ::
          {:ok, Destination.t()} | {:error, Ecto.Changeset.t()}
  # Only the status fields are written, so a secret that loaded as
  # :unreadable is never dumped and lock_version never moves.
  def apply_status(destination, plan) do
    alert = AuditStreamAlerts.status_alert(destination, plan, DateTime.utc_now())
    attrs = Map.merge(plan.destination, emailed_at(alert))

    with {:ok, updated} <- destination |> Destination.status_changeset(attrs) |> Repo.update(),
         :ok <- email(alert, updated) do
      record_audit(plan.audit, updated)
      {:ok, updated}
    end
  end

  defp emailed_at(nil), do: %{}
  defp emailed_at({_kind, _details, timestamps}), do: timestamps

  defp email(nil, _destination), do: :ok

  defp email({kind, details, _timestamps}, destination),
    do: Notifications.enqueue_audit_stream_email(kind, destination, nil, details)

  defp record_audit(nil, _destination), do: :ok
  defp record_audit(:recovered, destination), do: DestinationEvents.recovered(destination)

  defp record_audit({:failing, reason}, destination),
    do: DestinationEvents.failing(destination, reason)
end
