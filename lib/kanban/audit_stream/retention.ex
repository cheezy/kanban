defmodule Kanban.AuditStream.Retention do
  @moduledoc """
  The audit stream's part of the daily retention purge
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6): retention is never held
  back for a destination, so the events a destination has not received yet
  can be deleted, and every such loss is recorded as a gap rather than lost
  silently (§1).

  `Kanban.Retention.PurgeWorker` runs each Organization's audit purge
  through `purge/4`. For an Organization with no destinations the purge runs
  exactly as before. Otherwise, in this order:

    1. take the lease (`Kanban.AuditStream.Lease`) of each of its
       destinations, retrying for up to 30 seconds, so no run sends while the
       purge counts and deletes. When one can't be taken, the leases already
       taken are released, nothing is purged and `:lease_held` is returned:
       the Organization's purge waits for the next day;
    2. count, per destination, the events after its cursor, in (`txid`,
       `id`) order, inserted before the cutoff, leaving out the actions it
       excludes, with their first and last times
       (`Kanban.AuditStream.Reader.loss_counts/4`);
    3. purge, batch by batch, renewing the leases before each batch;
    4. count again: what was lost is the first count minus what is still
       there, so a refused purge, or one that failed before removing
       anything, records nothing. Each destination that lost events gets a
       gap (`Kanban.AuditStream.Gaps`, reason `retention`), and a pending
       batch that lost events is discarded so the next run cuts a new one
       under a new `batch_id` (§8.3);
    5. release the leases.

  The purge deletes in (`inserted_at`, `id`) order, so a destination's lost
  events are the oldest it was owed: the gap's first time is exact, and its
  last time is exact unless the purge failed part way. Then the last lost
  event is gone with the rest, and the gap's last time is that of the first
  event still there, the latest the lost events can be.

  Paused, failing and halted destinations lose events like any other, so
  they get gaps too. One deleted meanwhile is skipped. A destination created
  while the purge runs, starting from everything the audit log holds, holds
  no lease and was not counted in step 2, so its loss is counted from the
  Organization's events by action, taken before the purge: every event of an
  action it does not exclude that is gone. That includes any deleted before
  it was created, so its gap can overstate the loss; it is still recorded,
  since an overstated gap is visible and a missing one is not. A destination
  created from now, or from a recent window, was owed nothing the purge
  deletes.

  An error in steps 1, 2 or 4 is caught and logged here, so it never stops
  the purge job's other steps: before the purge it returns `:error` and
  purges nothing for the day; after it, the purge's own result stands. An
  error raised by the purge itself is re-raised once the losses it caused
  are recorded and the leases released, so the job handles it as before.

  `:lease_wait_ms` (default 30 seconds) and `:lease_poll_ms` (default 500)
  are options, or `config :kanban, #{inspect(__MODULE__)}`, for tests.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  require Logger

  @default_lease_wait_ms 30_000
  @default_lease_poll_ms 500

  @typedoc """
  The purge: called with a keep-alive function to call before each batch,
  returns the rows removed.
  """
  @type purge_fun :: ((-> :ok) -> {:ok, non_neg_integer()})

  @doc """
  Runs `purge_fun` for Organization `organization_id` at `cutoff` with the
  gap steps around it, as above. Returns what `purge_fun` returns,
  `:lease_held` when a destination's lease could not be taken in time, or
  `:error` when a step before the purge failed.
  """
  @spec purge(pos_integer(), DateTime.t(), purge_fun(), keyword()) ::
          {:ok, non_neg_integer()} | :lease_held | :error
  def purge(organization_id, %DateTime{} = cutoff, purge_fun, opts \\ [])
      when is_integer(organization_id) and is_function(purge_fun, 1) do
    case prepare(organization_id, cutoff, opts) do
      {:ok, prepared} -> purge_leased(organization_id, cutoff, purge_fun, prepared)
      other -> other
    end
  end

  # --- 1, 2: leases and the first count ---------------------------------------

  defp prepare(organization_id, cutoff, opts) do
    ids = destination_ids(organization_id)
    by_action = safe_counts_by_action(organization_id, cutoff)

    case ids do
      [] -> {:ok, %{leases: [], snapshots: [], known: {[], by_action}}}
      ids -> leased(organization_id, ids, cutoff, opts, {ids, by_action})
    end
  rescue
    error ->
      log_error("audit stream retention not started", organization_id, error)
      :error
  end

  defp leased(organization_id, ids, cutoff, opts, known) do
    case take_leases(ids, deadline(opts), setting(opts, :lease_poll_ms, @default_lease_poll_ms)) do
      {:ok, leases} -> snapshot(organization_id, leases, cutoff, known)
      :held -> :lease_held
    end
  end

  defp snapshot(organization_id, leases, cutoff, known) do
    extend_all(leases)
    {:ok, %{leases: leases, snapshots: snapshots(organization_id, leases, cutoff), known: known}}
  rescue
    error ->
      release_all(leases)
      reraise error, __STACKTRACE__
  end

  defp destination_ids(organization_id) do
    from(d in Destination,
      where: d.organization_id == ^organization_id,
      order_by: d.id,
      select: d.id
    )
    |> Repo.all()
  end

  defp take_leases(ids, deadline, poll_ms) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, leases} ->
      case take(id, deadline, poll_ms) do
        {:ok, token} ->
          {:cont, {:ok, [{id, token} | leases]}}

        :gone ->
          {:cont, {:ok, leases}}

        :held ->
          release_all(leases)
          {:halt, :held}
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

  defp deadline(opts),
    do:
      System.monotonic_time(:millisecond) + setting(opts, :lease_wait_ms, @default_lease_wait_ms)

  # Plain fields only, so a destination's secrets are never decrypted here.
  defp snapshots(organization_id, leases, cutoff) do
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
        pending_last_id: c.pending_last_id
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row
      |> Map.put(:token, Map.fetch!(tokens, row.id))
      |> Map.put(
        :before,
        Reader.loss_counts(organization_id, position(row), cutoff, filters(row))
      )
      |> Map.put(:pending_before, pending_count(organization_id, row, cutoff))
    end)
  end

  # --- 3, 4, 5: purge, record, release ------------------------------------------

  # With no destinations there are no leases and no snapshots, and the purge
  # runs exactly as before.
  defp purge_leased(organization_id, cutoff, purge_fun, prepared) do
    %{leases: leases, snapshots: snapshots, known: {ids, by_action}} = prepared
    result = run_purge(purge_fun, fn -> extend_all(leases) end)
    Enum.each(snapshots, &record_loss(organization_id, &1, cutoff))
    record_created(organization_id, cutoff, ids, by_action)
    finish(result)
  after
    release_all(prepared.leases)
  end

  defp run_purge(purge_fun, keep_alive) do
    {:ok, purge_fun.(keep_alive)}
  rescue
    error -> {:raised, error, __STACKTRACE__}
  end

  defp finish({:ok, result}), do: result
  defp finish({:raised, error, stacktrace}), do: reraise(error, stacktrace)

  defp record_loss(_organization_id, %{before: %{events: 0}}, _cutoff), do: :ok

  defp record_loss(organization_id, snapshot, cutoff) do
    after_purge =
      Reader.loss_counts(organization_id, position(snapshot), cutoff, filters(snapshot))

    lost = snapshot.before.events - after_purge.events

    if lost > 0,
      do:
        write_loss(
          organization_id,
          snapshot,
          lost_range(snapshot.before, after_purge, lost),
          cutoff
        ),
      else: :ok
  rescue
    error -> log_error("audit stream gap not recorded", snapshot.id, error)
  end

  # The purge deletes oldest first, so the lost events are the oldest of the
  # first count. When some are still there, the last lost one is gone and
  # the first survivor's time bounds it.
  defp lost_range(before, %{events: 0}, lost),
    do: %{events: lost, first_at: before.first_at, last_at: before.last_at}

  defp lost_range(before, after_purge, lost),
    do: %{
      events: lost,
      first_at: before.first_at,
      last_at: Enum.min([before.last_at, after_purge.first_at], DateTime)
    }

  defp write_loss(organization_id, snapshot, loss, cutoff) do
    result =
      Repo.transact(fn ->
        case lock_destination(snapshot.id) do
          nil -> {:ok, nil}
          destination -> record_locked(organization_id, destination, snapshot, loss, cutoff)
        end
      end)

    case result do
      {:ok, recorded} ->
        Gaps.emit_recorded(recorded)

      {:error, _changeset} ->
        Logger.error("audit stream gap not recorded destination_id=#{snapshot.id} reason=invalid")
    end
  end

  defp record_locked(organization_id, destination, snapshot, loss, cutoff) do
    cursor = leased_cursor(snapshot)

    with {:ok, recorded} <- Gaps.record(destination, :retention, loss, DateTime.utc_now()),
         {:ok, _cursor} <- discard_pending(organization_id, snapshot, cursor, cutoff) do
      {:ok, recorded}
    end
  end

  # The lease is renewed before every batch, so it expires only when a step
  # outlasts it; while its token is unchanged no other run has taken it, and
  # this run still owns the cursor. When another run has taken it, that run
  # may have sent some of the counted events before they were deleted, so
  # the gap can overstate the loss; it is still recorded, since an overstated
  # gap is visible and a missing one is not.
  defp leased_cursor(snapshot) do
    case Lease.owned(snapshot.id, snapshot.token) do
      nil ->
        Logger.warning(
          "audit stream lease lost during retention destination_id=#{snapshot.id}: " <>
            "the gap may overstate the loss"
        )

        nil

      cursor ->
        cursor
    end
  end

  # A pending batch that lost events no longer names the events it was cut
  # as, so it is discarded and the next run cuts a new one (§8.3). Only
  # while this run still holds the lease and the batch is the one counted.
  defp discard_pending(_organization_id, %{pending_before: nil}, _cursor, _cutoff),
    do: {:ok, nil}

  defp discard_pending(_organization_id, %{pending_before: 0}, _cursor, _cutoff), do: {:ok, nil}

  defp discard_pending(_organization_id, _snapshot, nil, _cutoff), do: {:ok, nil}

  defp discard_pending(organization_id, snapshot, %Cursor{} = cursor, cutoff) do
    pending_lost = snapshot.pending_before - pending_count(organization_id, snapshot, cutoff)

    if pending_lost > 0 and cursor.pending_batch_id == snapshot.pending_batch_id,
      do: cursor |> Cursor.changeset(Outcome.cleared_pending_attrs()) |> Repo.update(),
      else: {:ok, nil}
  end

  defp pending_count(_organization_id, %{pending_batch_id: nil}, _cutoff), do: nil

  defp pending_count(organization_id, row, cutoff) do
    through = {row.pending_last_txid, row.pending_last_id}
    opts = [{:through, through} | filters(row)]
    Reader.loss_counts(organization_id, position(row), cutoff, opts).events
  end

  # --- destinations created during the purge -----------------------------------

  defp counts_by_action(organization_id, cutoff) do
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

  # Never stops the purge: without the counts, a destination created during
  # it records nothing, as before.
  defp safe_counts_by_action(organization_id, cutoff) do
    counts_by_action(organization_id, cutoff)
  rescue
    error ->
      log_error("audit stream retention counts not taken", organization_id, error)
      nil
  end

  defp record_created(_organization_id, _cutoff, _known_ids, nil), do: :ok

  defp record_created(organization_id, cutoff, known_ids, by_action) do
    case created_from_everything(organization_id, known_ids) do
      [] -> :ok
      created -> record_created_losses(organization_id, cutoff, created, by_action)
    end
  rescue
    error -> log_error("audit stream gap not recorded", organization_id, error)
  end

  defp record_created_losses(organization_id, cutoff, created, by_action) do
    gone = gone_by_action(by_action, counts_by_action(organization_id, cutoff))
    Enum.each(created, &record_created_loss(&1, gone))
  end

  # Only a destination starting from everything (cursor (0, 0), no
  # not_before) was owed events older than the cutoff.
  defp created_from_everything(organization_id, known_ids) do
    from(d in Destination,
      join: c in Cursor,
      on: c.destination_id == d.id,
      where:
        d.organization_id == ^organization_id and d.id not in ^known_ids and
          c.last_txid == 0 and c.last_event_id == 0 and is_nil(c.not_before),
      order_by: d.id,
      select: %{id: d.id, excluded_actions: d.excluded_actions}
    )
    |> Repo.all()
  end

  defp gone_by_action(by_action, after_purge) do
    Map.new(by_action, fn {action, before} ->
      left = after_purge |> Map.get(action, %{events: 0}) |> Map.fetch!(:events)
      {action, Map.put(before, :events, before.events - left)}
    end)
  end

  defp record_created_loss(%{id: id, excluded_actions: excluded}, gone) do
    excluded = MapSet.new(excluded || [], &to_string/1)

    lost =
      for {action, %{events: n} = loss} <- gone,
          n > 0,
          not MapSet.member?(excluded, action),
          do: loss

    if lost != [], do: write_created_loss(id, combine(lost)), else: :ok
  end

  defp combine(losses),
    do: %{
      events: losses |> Enum.map(& &1.events) |> Enum.sum(),
      first_at: losses |> Enum.map(& &1.first_at) |> Enum.min(DateTime),
      last_at: losses |> Enum.map(& &1.last_at) |> Enum.max(DateTime)
    }

  defp write_created_loss(id, loss) do
    Logger.warning(
      "audit stream destination created during retention destination_id=#{id}: " <>
        "the gap may overstate the loss"
    )

    result =
      Repo.transact(fn ->
        case lock_destination(id) do
          nil -> {:ok, nil}
          destination -> Gaps.record(destination, :retention, loss, DateTime.utc_now())
        end
      end)

    case result do
      {:ok, recorded} ->
        Gaps.emit_recorded(recorded)

      {:error, _changeset} ->
        Logger.error("audit stream gap not recorded destination_id=#{id} reason=invalid")
    end
  end

  defp lock_destination(id) do
    from(d in Destination,
      where: d.id == ^id,
      lock: "FOR UPDATE",
      select: %{id: d.id, organization_id: d.organization_id, kind: d.kind}
    )
    |> Repo.one()
  end

  defp extend_all(leases), do: Enum.each(leases, fn {id, token} -> Lease.extend(id, token) end)

  defp release_all(leases), do: Enum.each(leases, fn {id, token} -> Lease.release(id, token) end)

  # --- helpers -----------------------------------------------------------------

  defp position(row), do: {row.last_txid, row.last_event_id}

  defp filters(row), do: PendingBatch.filters(row, row)

  defp setting(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      Application.get_env(:kanban, __MODULE__, []) |> Keyword.get(key, default)
    end)
  end

  # The exception type and SQLSTATE are code-defined, never row data, so they
  # are safe to log.
  defp log_error(message, id, error) do
    Logger.error("#{message} id=#{id} reason=#{reason(error)}")
    :ok
  end

  defp reason(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp reason(%module{}), do: inspect(module)
end
