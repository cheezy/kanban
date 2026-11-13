defmodule Kanban.AuditStream.Reseed do
  @moduledoc """
  Re-seeds every destination's cursor after a logical database move
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.8): a dump and restore,
  logical replication, or a major-version upgrade done by dump. Transaction
  ids belong to one Postgres server, so after such a move every new row has a
  `txid` lower than every cursor: no destination receives anything new, and
  `Kanban.AuditStream.DispatchWorker` halts one with events waiting with
  `txid_reset`.

  Only a cursor the move left behind is re-seeded: one halted with
  `txid_reset`, or whose `last_txid` or `pending_last_txid` is at or above
  the snapshot's `xmax`, which only another server's transaction ids can be.
  A cursor already re-seeded (at `(0, 0)`), one created on the new server,
  and one the new server's ids already passed (a move that kept the ids
  higher, so nothing sorts behind it) are left as they are, so running the
  re-seed again changes nothing and records nothing twice.

  For each such cursor, under the destination's lease (`Kanban.AuditStream.Lease`),
  `run/1` sets `last_txid` and `last_event_id` to 0 and `not_before` to
  `last_inserted_at`, or to the destination's `inserted_at` when nothing was
  ever delivered. It discards the pending batch, whose range is in the old
  server's ids, and clears a `txid_reset` halt. Every other halt stays: each
  waits for a person. The destination's `state` is left as it is, so the next
  delivery records `audit_stream_recovered` and returns it to healthy, and
  the minute sweep picks it up because nothing halts it any more.

  Each destination then receives every event written on the new server since
  the last one it received. `not_before` is inclusive, so events at that
  exact time may arrive twice, and receivers drop them by `id`.

  Restored rows keep the old server's `txid`, which sorts after every row the
  new server writes, so a (`txid`, `id`) cursor cannot deliver both. Before
  moving a cursor, the re-seed finds the Organization's restored rows (every
  row with a `txid` at or above the snapshot's `xmax`, which no committed
  transaction of this server can have, apart from its own transaction's
  rows) and records, as one `database_move` gap
  (`Kanban.AuditStream.Gaps`), every event after the old position that the
  new cursor will never read: a restored one, or one inserted before
  `not_before`, and every event of the new server stamped before
  `not_before` by a skewed clock. The bound of the restored rows (the highest restored `id`
  and that `xmax`) is stored on the cursor, so they are never read for it
  again, delivered or not, and every other event is either received or in
  the gap. The bound relies on the `id` sequence being restored with the
  table, as `pg_dump` does, so every row the new server writes has a higher
  `id`. `run/1` checks that before reading anything: it raises when the
  sequence has not reached the highest `id` in the table, because every
  event the new server then wrote into the bound would be hidden and counted
  nowhere. A later move replaces a cursor's bound with that move's: the
  earlier restored rows were inserted before the new `not_before`, so they
  stay unread. The runbook in
  `docs/audit-log-database-roles.md` still has every destination catch up
  before the dump, which leaves nothing for the gap.

  The leases of one Organization are taken first, waiting up to
  `:lease_wait_ms` in all for a run that holds one; its cursors are then
  re-seeded in one transaction, with one `audit_stream_cursors_reseeded`
  event (no actor). Each destination's row is locked before its cursor, the
  order `Kanban.AuditStream.DispatchWorker` takes them in, and one deleted
  meanwhile is skipped. The filters of the gap are read under that lock. A
  destination whose lease is still held is counted as
  busy and left as it was, so running the re-seed again picks it up. Only
  plain fields are read, so no destination secret is decrypted.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  @default_lease_wait_ms 15_000
  @default_lease_poll_ms 500

  @typedoc """
  Organizations with at least one re-seeded destination, the destinations
  re-seeded, and those left as they were because a run held their lease.
  """
  @type counts :: %{
          organizations: non_neg_integer(),
          destinations: non_neg_integer(),
          busy: non_neg_integer()
        }

  @doc """
  Re-seeds every destination's cursor and returns `{:ok, counts}`.

  Raises before anything is written when the `audit_events` id sequence is
  behind the highest event id, as after logical replication that did not
  copy it: advance it with `setval` and run the re-seed again.

  Options, of which an unknown one or a wrong type raises `ArgumentError`
  before anything is read or written:

    * `:dry_run` - when `true`, counts the Organizations and destinations
      that would be re-seeded and writes nothing, taking no lease
      (default `false`)
    * `:lease_wait_ms` - how long to wait, per Organization, for runs that
      hold a lease (default 15 seconds)
    * `:lease_poll_ms` - how often to try again while waiting (default 500)
  """
  @spec run(keyword()) :: {:ok, counts()}
  def run(opts \\ []) do
    opts = validate!(opts)
    ensure_ids_restored!()

    counts =
      rows()
      |> Enum.chunk_by(& &1.organization_id)
      |> Enum.map(&organization(&1, opts[:dry_run], opts))
      |> Enum.reduce(%{organizations: 0, destinations: 0, busy: 0}, &add/2)

    {:ok, counts}
  end

  # Raises before anything is read or written, so a misspelt `dry_run` can
  # never turn a count into a real re-seed.
  defp validate!(opts) do
    opts =
      Keyword.validate!(opts,
        dry_run: false,
        lease_wait_ms: @default_lease_wait_ms,
        lease_poll_ms: @default_lease_poll_ms
      )

    unless is_boolean(opts[:dry_run]),
      do: raise(ArgumentError, ":dry_run must be a boolean")

    for key <- [:lease_wait_ms, :lease_poll_ms],
        not (is_integer(opts[key]) and opts[key] > 0),
        do: raise(ArgumentError, "#{inspect(key)} must be a positive integer")

    opts
  end

  # The restored bound hides every row with an id at or below it, so every id
  # the new server draws must be above every restored one. An id above the
  # sequence means it was not restored with the table.
  defp ensure_ids_restored! do
    %{rows: [[max_id, sequence_at]]} =
      Repo.query!("""
      SELECT (SELECT max(id) FROM audit_events),
             pg_sequence_last_value(pg_get_serial_sequence('audit_events', 'id')::regclass)
      """)

    if max_id && (is_nil(sequence_at) or sequence_at < max_id),
      do:
        raise(
          "the audit_events id sequence is behind the highest event id; " <>
            "advance it with setval before re-seeding"
        )

    :ok
  end

  defp organization(rows, true, _opts), do: {length(rows), 0}

  defp organization([%{organization_id: organization_id} | _] = rows, false, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:lease_wait_ms]
    {leases, busy} = take_all(rows, deadline, opts[:lease_poll_ms])
    reseed_held(organization_id, leases, busy)
  end

  # The leases are released whatever the transaction does.
  defp reseed_held(organization_id, leases, busy) do
    {:ok, {recorded, expired}} = Repo.transact(fn -> reseed_locked(organization_id, leases) end)
    Enum.each(recorded, &Gaps.emit_recorded/1)
    {length(recorded), busy + expired}
  after
    Enum.each(leases, fn {row, token} -> Lease.release(row.id, token) end)
  end

  defp add({0, busy}, acc), do: %{acc | busy: acc.busy + busy}

  defp add({reseeded, busy}, acc),
    do: %{
      organizations: acc.organizations + 1,
      destinations: acc.destinations + reseeded,
      busy: acc.busy + busy
    }

  # The cursors a move left behind, grouped by Organization. Plain fields
  # only, so no secret is decrypted. xmax is read after the rows, so it is at
  # least as new as every cursor.
  defp rows do
    query =
      from(d in Destination,
        join: c in Cursor,
        on: c.destination_id == d.id,
        order_by: [asc: d.organization_id, asc: d.id],
        select: %{
          id: d.id,
          organization_id: d.organization_id,
          inserted_at: d.inserted_at,
          halted_reason: d.halted_reason,
          last_txid: c.last_txid,
          pending_last_txid: c.pending_last_txid
        }
      )

    rows = Repo.all(query)

    %{rows: [[xmax]]} =
      Repo.query!("SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint")

    Enum.filter(rows, &moved?(&1, &1, xmax))
  end

  # Halted with txid_reset, or holding a txid no transaction of this server
  # has completed: another server's.
  defp moved?(%{halted_reason: :txid_reset}, _cursor, _xmax), do: true

  defp moved?(_destination, cursor, xmax),
    do: max(cursor.last_txid, cursor.pending_last_txid || 0) >= xmax

  # --- leases -----------------------------------------------------------------

  defp take_all(rows, deadline, poll_ms) do
    Enum.reduce(rows, {[], 0}, fn row, {leases, busy} ->
      case take(row.id, deadline, poll_ms) do
        {:ok, token} -> {[{row, token} | leases], busy}
        :held -> {leases, busy + 1}
        :gone -> {leases, busy}
      end
    end)
  end

  defp take(id, deadline, poll_ms) do
    case Lease.take(id) do
      {:ok, token} -> {:ok, token}
      :held -> wait(id, deadline, poll_ms)
    end
  end

  # No cursor means the destination was deleted after it was listed.
  defp wait(id, deadline, poll_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      is_nil(Lease.seconds_left(id)) ->
        :gone

      remaining <= 0 ->
        :held

      true ->
        poll_ms |> min(remaining) |> Process.sleep()
        take(id, deadline, poll_ms)
    end
  end

  # --- writes -----------------------------------------------------------------

  # One entry per re-seeded destination (its recorded gap, or nil), and the
  # number whose lease expired.
  defp reseed_locked(organization_id, leases) do
    {restored, xmax} = restored_bound(organization_id)
    results = Enum.map(leases, fn {row, token} -> reseed(row, token, restored, xmax) end)
    recorded = Enum.reject(results, &(&1 in [:expired, :gone, :unmoved]))

    if recorded != [],
      do: DestinationEvents.cursors_reseeded(organization_id, length(recorded))

    {:ok, {recorded, Enum.count(results, &(&1 == :expired))}}
  end

  # The destination row first and then the cursor, as the worker and a
  # delete take them, so neither waits on the other in a cycle. Gaps.record
  # needs that row lock too. A destination deleted since it was listed is
  # skipped, and so is a cursor no longer left behind when re-read here.
  defp reseed(row, token, restored, xmax) do
    case lock_destination(row.id) do
      nil -> :gone
      locked -> reseed_guarded(Map.merge(row, locked), token, restored, xmax)
    end
  end

  # A lease that expired while the others were taken is left for another run.
  defp reseed_guarded(row, token, restored, xmax) do
    case Lease.guard(row.id, token) do
      %Cursor{} = cursor ->
        if moved?(row, cursor, xmax), do: reseed_cursor(row, cursor, restored), else: :unmoved

      nil ->
        :expired
    end
  end

  defp reseed_cursor(row, cursor, restored) do
    not_before = cursor.last_inserted_at || row.inserted_at
    recorded = record_move_loss(row, cursor, restored, not_before)
    cursor |> Cursor.changeset(reseeded_attrs(not_before, restored)) |> Repo.update!()
    clear_txid_reset(row.id)
    recorded
  end

  # The Organization's rows written by another server. xmax is one past the
  # latest transaction this server completed, so a committed row of this
  # server has a txid below it; only a row of this transaction, still
  # running, can be at or above it, and those are left out. Their highest id
  # and that xmax, or nil when there are none, and the xmax.
  defp restored_bound(organization_id) do
    %{rows: [[max_id, xmax]]} =
      Repo.query!(
        """
        SELECT max(e.id), s.xmax
        FROM (
          SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint AS xmax,
                 COALESCE(pg_current_xact_id_if_assigned()::text::bigint, -1) AS own
        ) AS s
        LEFT JOIN audit_events AS e
          ON e.organization_id = $1 AND e.txid >= s.xmax AND e.txid <> s.own
        GROUP BY s.xmax
        """,
        [organization_id]
      )

    {if(max_id, do: {max_id, xmax}), xmax}
  end

  # Every event after the old position that the re-seeded cursor never
  # reads. The caller holds the destination's row lock, as Gaps requires.
  defp record_move_loss(row, cursor, bound, not_before) do
    position = {cursor.last_txid, cursor.last_event_id}
    filters = PendingBatch.filters(row, cursor)

    case Reader.move_losses(row.organization_id, position, bound, not_before, filters) do
      %{events: 0} ->
        nil

      loss ->
        {:ok, recorded} = Gaps.record(row, :database_move, loss, DateTime.utc_now())
        recorded
    end
  end

  # The fields the gap's filters and the moved check read, as they are now.
  defp lock_destination(id) do
    query =
      from(d in Destination,
        where: d.id == ^id,
        lock: "FOR UPDATE",
        select: %{
          kind: d.kind,
          halted_reason: d.halted_reason,
          excluded_actions: d.excluded_actions,
          include_personal_data: d.include_personal_data
        }
      )

    Repo.one(query)
  end

  defp reseeded_attrs(not_before, bound) do
    {max_id, min_txid} = bound || {nil, nil}

    Outcome.cleared_pending_attrs()
    |> Map.merge(Lease.release_attrs())
    |> Map.merge(%{
      last_txid: 0,
      last_event_id: 0,
      not_before: not_before,
      restored_max_event_id: max_id,
      restored_min_txid: min_txid
    })
  end

  # One conditional statement on the status column only, so a secret is
  # never loaded, lock_version never moves, and another halt is never cleared.
  defp clear_txid_reset(destination_id) do
    query =
      from(d in Destination,
        where: d.id == ^destination_id and d.halted_reason == ^:txid_reset
      )

    Repo.update_all(query,
      set: [
        halted_reason: nil,
        state_reason: Outcome.reseeded_reason(),
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end
end
