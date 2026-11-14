defmodule Kanban.AuditStream.Sweep do
  @moduledoc """
  The minute sweep's two reads over every destination
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1, §8.8, §13.1): which
  destinations to queue a run for, and the lag of a 15-minute slot of them,
  each destination's slot claimed on its cursor first so it is measured
  once (D432).
  `Kanban.AuditStream.due_for_dispatch/2` and
  `Kanban.AuditStream.measure_lag/3` document both and are the only callers.

  Both read plain destination and cursor fields only, never the structs,
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
  @spec measure_lag(DateTime.t(), DateTime.t(), keyword()) :: [map()]
  def measure_lag(%DateTime{} = tick, %DateTime{} = now, opts \\ []) do
    {residue, slot} = lag_slot(tick)

    case claim_lag_slot(residue, slot) do
      [] ->
        []

      ids ->
        from([d, _c] in sweep_rows(), where: d.id in ^ids)
        |> Repo.all()
        |> Enum.map(&lag(&1, now, opts))
    end
  end

  @doc """
  The residue (`id` modulo 15) of the destinations whose slot `tick` is,
  and the start of the 15-minute slot `tick` falls in, to the minute.
  """
  @spec lag_slot(DateTime.t()) :: {0..14, DateTime.t()}
  def lag_slot(%DateTime{} = tick) do
    residue = rem(tick.minute, @lag_slots)
    start = DateTime.add(%{tick | second: 0, microsecond: {0, 6}}, -residue * 60, :second)
    {residue, start}
  end

  # Moves `lag_measured_slot` forward to `slot` on the cursor of every enabled
  # destination of this residue that has not been measured in it yet, in one
  # conditional UPDATE, and returns their ids. A second sweep of the slot,
  # running alongside or after, finds the column already at `slot` and claims
  # nothing, on any node: Postgres re-checks the condition on a row a
  # concurrent claim locked once that claim commits. A sweep that crashes
  # after claiming loses that slot's sample only; the next slot is later, so
  # it claims as usual.
  defp claim_lag_slot(residue, slot) do
    query =
      from(c in Cursor,
        join: d in Destination,
        on: d.id == c.destination_id,
        where:
          d.enabled and fragment("? % ?", d.id, ^@lag_slots) == ^residue and
            (is_nil(c.lag_measured_slot) or c.lag_measured_slot < ^slot),
        select: c.destination_id,
        update: [set: [lag_measured_slot: ^slot]]
      )

    {_count, ids} = Repo.update_all(query, [])
    ids
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
