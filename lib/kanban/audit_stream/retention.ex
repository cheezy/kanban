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

  The steps live in three modules: `Kanban.AuditStream.Retention.Leases`
  takes, renews and releases the leases, `Kanban.AuditStream.Retention.Snapshot`
  takes the counts, and `Kanban.AuditStream.Retention.Losses` records the
  gaps. This module orders them, and holds every rescue and the release.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Retention.Leases
  alias Kanban.AuditStream.Retention.Losses
  alias Kanban.AuditStream.Retention.Snapshot
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
    case Leases.take_all(
           ids,
           deadline(opts),
           setting(opts, :lease_poll_ms, @default_lease_poll_ms)
         ) do
      {:ok, leases} -> snapshot(organization_id, leases, cutoff, known)
      :held -> :lease_held
    end
  end

  defp snapshot(organization_id, leases, cutoff, known) do
    Leases.extend_all(leases)

    {:ok,
     %{leases: leases, snapshots: Snapshot.list(organization_id, leases, cutoff), known: known}}
  rescue
    error ->
      Leases.release_all(leases)
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

  defp deadline(opts),
    do:
      System.monotonic_time(:millisecond) + setting(opts, :lease_wait_ms, @default_lease_wait_ms)

  # Never stops the purge: without the counts, a destination created during
  # it records nothing, as before.
  defp safe_counts_by_action(organization_id, cutoff) do
    Snapshot.counts_by_action(organization_id, cutoff)
  rescue
    error ->
      log_error("audit stream retention counts not taken", organization_id, error)
      nil
  end

  # --- 3, 4, 5: purge, record, release ------------------------------------------

  # With no destinations there are no leases and no snapshots, and the purge
  # runs exactly as before.
  defp purge_leased(organization_id, cutoff, purge_fun, prepared) do
    %{leases: leases, snapshots: snapshots, known: {ids, by_action}} = prepared
    result = run_purge(purge_fun, fn -> Leases.extend_all(leases) end)
    Enum.each(snapshots, &record_loss(organization_id, &1, cutoff))
    record_created(organization_id, cutoff, ids, by_action)
    finish(result)
  after
    Leases.release_all(prepared.leases)
  end

  defp run_purge(purge_fun, keep_alive) do
    {:ok, purge_fun.(keep_alive)}
  rescue
    error -> {:raised, error, __STACKTRACE__}
  end

  defp finish({:ok, result}), do: result
  defp finish({:raised, error, stacktrace}), do: reraise(error, stacktrace)

  defp record_loss(organization_id, snapshot, cutoff) do
    Losses.record(organization_id, snapshot, cutoff)
  rescue
    error -> log_error("audit stream gap not recorded", snapshot.id, error)
  end

  defp record_created(_organization_id, _cutoff, _known_ids, nil), do: :ok

  defp record_created(organization_id, cutoff, known_ids, by_action) do
    Losses.record_created(organization_id, cutoff, known_ids, by_action)
  rescue
    error -> log_error("audit stream gap not recorded", organization_id, error)
  end

  # --- helpers -----------------------------------------------------------------

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
