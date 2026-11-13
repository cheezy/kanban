defmodule Kanban.AuditStream.Retention.Snapshot do
  @moduledoc """
  The counts `Kanban.AuditStream.Retention` takes before and after the
  purge (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6): per leased
  destination, the events after its cursor that the cutoff reaches, and
  those of its pending batch; per Organization, its events by action, for a
  destination created while the purge runs.

  The per-destination counts (`list/3`, `loss_counts/3`, `pending_count/3`)
  are `Kanban.AuditStream.Reader.loss_counts/4`, in (`txid`, `id`) order,
  leaving out the actions the destination excludes. `counts_by_action/2`
  counts the Organization's events by action, with no destination's filter.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  @typedoc """
  One leased destination before the purge: its plain fields and cursor, its
  lease `:token`, its `:before` count and its `:pending_before` count (`nil`
  with no pending batch).
  """
  @type t :: map()

  @doc """
  A snapshot of each leased destination in `leases` (`{destination_id,
  token}` pairs), in destination order, counted for Organization
  `organization_id` at `cutoff`. A destination deleted meanwhile is left out.
  """
  @spec list(pos_integer(), [{integer(), Ecto.UUID.t()}], DateTime.t()) :: [t()]
  # Plain fields only, so a destination's secrets are never decrypted here.
  def list(organization_id, leases, cutoff) do
    tokens = Map.new(leases)
    ids = Map.keys(tokens)

    from(d in Destination,
      join: c in Cursor,
      on: c.destination_id == d.id,
      where: d.id in ^ids,
      order_by: d.id,
      select: %{
        id: d.id,
        organization_id: d.organization_id,
        kind: d.kind,
        excluded_actions: d.excluded_actions,
        include_personal_data: d.include_personal_data,
        not_before: c.not_before,
        last_txid: c.last_txid,
        last_event_id: c.last_event_id,
        pending_batch_id: c.pending_batch_id,
        pending_last_txid: c.pending_last_txid,
        pending_last_id: c.pending_last_id,
        restored_max_event_id: c.restored_max_event_id,
        restored_min_txid: c.restored_min_txid
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row
      |> Map.put(:token, Map.fetch!(tokens, row.id))
      |> Map.put(:before, loss_counts(organization_id, row, cutoff))
      |> Map.put(:pending_before, pending_count(organization_id, row, cutoff))
    end)
  end

  @doc """
  The events after `row`'s cursor that `cutoff` reaches, as `row` filters
  them: the count `list/3` takes as `:before`, taken again after the purge.
  """
  @spec loss_counts(pos_integer(), map(), DateTime.t()) :: Reader.loss()
  def loss_counts(organization_id, row, cutoff),
    do: Reader.loss_counts(organization_id, position(row), cutoff, filters(row))

  @doc """
  How many events of `row`'s pending batch `cutoff` reaches, or `nil` when
  it has no pending batch.
  """
  @spec pending_count(pos_integer(), map(), DateTime.t()) :: non_neg_integer() | nil
  def pending_count(_organization_id, %{pending_batch_id: nil}, _cutoff), do: nil

  def pending_count(organization_id, row, cutoff) do
    through = {row.pending_last_txid, row.pending_last_id}
    opts = [{:through, through} | filters(row)]
    Reader.loss_counts(organization_id, position(row), cutoff, opts).events
  end

  @doc """
  Organization `organization_id`'s events inserted before `cutoff`, by
  action: a map of each action to its count, with the first and last times
  (`events`, `first_at`, `last_at`).
  """
  @spec counts_by_action(pos_integer(), DateTime.t()) :: %{String.t() => Reader.loss()}
  def counts_by_action(organization_id, cutoff) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization_id and e.inserted_at < ^cutoff,
      group_by: e.action,
      select:
        {e.action,
         %{events: count(e.id), first_at: min(e.inserted_at), last_at: max(e.inserted_at)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp position(row), do: {row.last_txid, row.last_event_id}

  defp filters(row), do: PendingBatch.filters(row, row)
end
