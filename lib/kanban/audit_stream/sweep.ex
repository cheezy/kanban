defmodule Kanban.AuditStream.Sweep do
  @moduledoc """
  The minute sweep's two reads over every destination
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1, §8.8, §13.1): which
  destinations to queue a run for, and the lag of a 15-minute slot of them.
  `Kanban.AuditStream.due_for_dispatch/2` and
  `Kanban.AuditStream.measure_lag/3` document both and are the only callers.

  Both select plain destination and cursor fields only, never the structs,
  so a destination's secrets are never decrypted every minute.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  @lag_slots 15

  @doc "See `Kanban.AuditStream.due_for_dispatch/2`."
  @spec due_for_dispatch(DateTime.t(), keyword()) :: [integer()]
  def due_for_dispatch(%DateTime{} = now, opts \\ []) do
    query =
      from([d, c] in sweep_rows(),
        where: is_nil(d.halted_reason) and (is_nil(c.leased_until) or c.leased_until <= ^now),
        select_merge: %{enabled: d.enabled, next_attempt_at: c.next_attempt_at}
      )

    rows = Repo.all(query)
    next_txid = next_txid()
    for row <- rows, moved?(row, next_txid) or due?(row, now, opts), do: row.id
  end

  @doc "See `Kanban.AuditStream.measure_lag/3`."
  @spec measure_lag(non_neg_integer(), DateTime.t(), keyword()) :: [map()]
  def measure_lag(minute, %DateTime{} = now, opts \\ []) when is_integer(minute) do
    slot = rem(minute, @lag_slots)

    query =
      from([d, c] in sweep_rows(),
        where: d.enabled and fragment("? % ?", d.id, ^@lag_slots) == ^slot
      )

    for row <- Repo.all(query), do: lag(row, now, opts)
  end

  # The destination and cursor fields the sweep reads; never the struct.
  defp sweep_rows do
    from(d in Destination,
      join: c in Cursor,
      on: c.destination_id == d.id,
      order_by: d.id,
      select: %{
        id: d.id,
        kind: d.kind,
        organization_id: d.organization_id,
        excluded_actions: d.excluded_actions,
        include_personal_data: d.include_personal_data,
        last_txid: c.last_txid,
        last_event_id: c.last_event_id,
        pending_last_txid: c.pending_last_txid,
        not_before: c.not_before,
        restored_max_event_id: c.restored_max_event_id,
        restored_min_txid: c.restored_min_txid
      }
    )
  end

  # The xmax of this snapshot, one past the latest transaction this server
  # completed. Every txid a cursor holds is a committed row's, so on this
  # server it is below xmax. Unlike pg_current_xact_id(), reading it assigns
  # no id. Read after the rows, so it is at least as new as every cursor.
  defp next_txid do
    %{rows: [[xmax]]} =
      Repo.query!("SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint")

    xmax
  end

  # A cursor at or past xmax holds another server's txids. Checked whether
  # the destination is paused or waiting to retry: once this server's txids
  # pass the cursor the move can no longer be seen. A halted one keeps its
  # halt for a person, and the re-seed covers it.
  defp moved?(row, next_txid), do: max(row.last_txid, row.pending_last_txid || 0) >= next_txid

  defp due?(%{enabled: true} = row, now, opts),
    do: attempt_due?(row.next_attempt_at, now) and sendable?(row, opts)

  defp due?(_row, _now, _opts), do: false

  defp attempt_due?(nil, _now), do: true
  defp attempt_due?(at, now), do: DateTime.compare(at, now) != :gt

  defp sendable?(row, opts) do
    filters = PendingBatch.filters(row, row) ++ Keyword.take(opts, [:horizon])
    Reader.next_waiting_at(row.organization_id, position(row), filters) != nil
  end

  defp lag(row, now, opts) do
    filters = PendingBatch.filters(row, row) ++ Keyword.take(opts, [:horizon])
    counts = Reader.waiting_counts(row.organization_id, position(row), filters)

    %{
      kind: row.kind,
      lag_seconds: lag_seconds(counts.oldest_waiting_at, now),
      events_waiting: counts.events_waiting,
      events_above_horizon: counts.events_above_horizon
    }
  end

  defp lag_seconds(nil, _now), do: 0
  defp lag_seconds(oldest, now), do: max(DateTime.diff(now, oldest, :second), 0)

  defp position(row), do: {row.last_txid, row.last_event_id}
end
