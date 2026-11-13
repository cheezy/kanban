defmodule Kanban.AuditStream.Reseed do
  @moduledoc """
  Re-seeds every destination's cursor after a logical database move
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.8): a dump and restore,
  logical replication, or a major-version upgrade done by dump. Transaction
  ids belong to one Postgres server, so after such a move every new row has a
  `txid` lower than every cursor: no destination receives anything new, and
  `Kanban.AuditStream.DispatchWorker` halts one with events waiting with
  `txid_reset`.

  For each cursor, under the destination's lease (`Kanban.AuditStream.Lease`),
  `run/1` sets `last_txid` and `last_event_id` to 0 and `not_before` to
  `last_inserted_at`, or to the destination's `inserted_at` when nothing was
  ever delivered. It discards the pending batch, whose range is in the old
  server's ids, and clears a `txid_reset` halt. Every other halt stays: each
  waits for a person. The destination's `state` is left as it is, so the next
  delivery records `audit_stream_recovered` and returns it to healthy, and
  the minute sweep picks it up because nothing halts it any more.

  Each destination then receives every event written on the new server since
  the last one it received. `not_before` is inclusive, so events at that
  exact time may arrive twice, and receivers drop them by `id`. Restored rows
  keep the old server's `txid`, so one not yet delivered when the database
  was dumped stays above the horizon (`Kanban.AuditStream.Reader`), or is
  skipped when it is older than `not_before`; the runbook in
  `docs/audit-log-database-roles.md` has every destination catch up before
  the dump for that reason.

  The leases of one Organization are taken first, waiting up to
  `:lease_wait_ms` in all for a run that holds one; its cursors are then
  re-seeded in one transaction, with one `audit_stream_cursors_reseeded`
  event (no actor). A destination whose lease is still held is counted as
  busy and left as it was, so running the re-seed again picks it up. Only
  plain fields are read, so no destination secret is decrypted.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
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

  defp organization(rows, true, _opts), do: {length(rows), 0}

  defp organization([%{organization_id: organization_id} | _] = rows, false, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:lease_wait_ms]
    {leases, busy} = take_all(rows, deadline, opts[:lease_poll_ms])
    reseed_held(organization_id, leases, busy)
  end

  # The leases are released whatever the transaction does.
  defp reseed_held(organization_id, leases, busy) do
    {:ok, reseeded} = Repo.transact(fn -> reseed_locked(organization_id, leases) end)
    {reseeded, busy + length(leases) - reseeded}
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

  # Plain fields only, grouped by Organization, so no secret is decrypted.
  defp rows do
    query =
      from(d in Destination,
        join: c in Cursor,
        on: c.destination_id == d.id,
        order_by: [asc: d.organization_id, asc: d.id],
        select: %{id: d.id, organization_id: d.organization_id, inserted_at: d.inserted_at}
      )

    Repo.all(query)
  end

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

  defp reseed_locked(organization_id, leases) do
    reseeded = Enum.count(leases, fn {row, token} -> reseed(row, token) end)

    if reseeded > 0, do: DestinationEvents.cursors_reseeded(organization_id, reseeded)

    {:ok, reseeded}
  end

  # A lease that expired while the others were taken is left for another run.
  defp reseed(row, token) do
    case Lease.guard(row.id, token) do
      %Cursor{} = cursor ->
        cursor |> Cursor.changeset(reseeded_attrs(cursor, row)) |> Repo.update!()
        clear_txid_reset(row.id)
        true

      nil ->
        false
    end
  end

  defp reseeded_attrs(cursor, row) do
    Outcome.cleared_pending_attrs()
    |> Map.merge(Lease.release_attrs())
    |> Map.merge(%{
      last_txid: 0,
      last_event_id: 0,
      not_before: cursor.last_inserted_at || row.inserted_at
    })
  end

  # One conditional statement on the status column only, so a secret is
  # never loaded, lock_version never moves, and another halt is never cleared.
  defp clear_txid_reset(destination_id) do
    query =
      from(d in Destination,
        where: d.id == ^destination_id and d.halted_reason == ^:txid_reset
      )

    Repo.update_all(query, set: [halted_reason: nil, updated_at: DateTime.utc_now(:second)])
  end
end
