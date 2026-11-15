defmodule Kanban.AuditStream.Retention.Losses do
  @moduledoc """
  The gaps `Kanban.AuditStream.Retention` records for the events a purge
  deleted before a destination received them
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6, §1), each a
  `Kanban.AuditStream.Gaps` gap with reason `retention`.

  A leased destination's loss is its count before the purge minus what is
  still there (`Kanban.AuditStream.Retention.Snapshot`), and a pending batch
  that lost events is discarded so the next run cuts a new one under a new
  `batch_id` (§8.3). A destination created while the purge ran, starting
  from everything, is charged every gone event of an action it does not
  exclude, which can overstate its loss. Like a leased destination's, its
  gap's last time never names an event that is still there: when a purge
  that failed part way left events of an action it does not exclude, the
  last time is no later than the earliest of them. It is counted by action,
  so it can be earlier than a leased destination's for the same loss.

  For both, the gap's last time is never earlier than its first. An event
  older than every counted one, written outside the app while the purge
  ran, is the earliest left; the last time is then the first time, not the
  older event's.

  Neither function rescues: `Kanban.AuditStream.Retention` catches and logs
  an error raised here, so it never stops the purge job.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Retention.Snapshot
  alias Kanban.Repo

  require Logger

  @doc """
  Records the gap of a leased destination that lost events to the purge of
  Organization `organization_id` at `cutoff`, from its `snapshot`, and
  discards its pending batch when that lost events too. A destination that
  lost nothing, or was deleted meanwhile, records nothing.
  """
  @spec record(pos_integer(), Snapshot.t(), DateTime.t()) :: term()
  def record(_organization_id, %{before: %{events: 0}}, _cutoff), do: :ok

  def record(organization_id, snapshot, cutoff) do
    after_purge = Snapshot.loss_counts(organization_id, snapshot, cutoff)

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
  end

  @doc """
  Records the gaps of the destinations of Organization `organization_id`
  created during its purge at `cutoff`: those not in `known_ids` that start
  from everything, charged what `by_action` (`Snapshot.counts_by_action/2`,
  taken before the purge) counted and is now gone.
  """
  @spec record_created(pos_integer(), DateTime.t(), [integer()], map()) :: :ok
  def record_created(organization_id, cutoff, known_ids, by_action) do
    case created_from_everything(organization_id, known_ids) do
      [] -> :ok
      created -> record_created_losses(organization_id, cutoff, created, by_action)
    end
  end

  # The purge deletes oldest first, so the lost events are the oldest of the
  # first count. When some are still there, the last lost one is gone and
  # the first survivor's time bounds it, but never below the first time.
  defp lost_range(before, %{events: 0}, lost),
    do: %{events: lost, first_at: before.first_at, last_at: before.last_at}

  defp lost_range(before, after_purge, lost),
    do: %{
      events: lost,
      first_at: before.first_at,
      last_at: bounded_last(before.first_at, before.last_at, after_purge.first_at)
    }

  # The last lost time, bounded by the earliest survivor's time. An event
  # older than the first counted one, written outside the app while the purge
  # ran, can be that survivor; the first time then bounds it from below, so a
  # gap never ends before it starts.
  defp bounded_last(first_at, last_at, first_left),
    do: Enum.max([Enum.min([last_at, first_left], DateTime), first_at], DateTime)

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
    pending_lost =
      snapshot.pending_before - Snapshot.pending_count(organization_id, snapshot, cutoff)

    if pending_lost > 0 and cursor.pending_batch_id == snapshot.pending_batch_id,
      do: cursor |> Cursor.changeset(Outcome.cleared_pending_attrs()) |> Repo.update(),
      else: {:ok, nil}
  end

  # --- destinations created during the purge -----------------------------------

  defp record_created_losses(organization_id, cutoff, created, by_action) do
    after_purge = Snapshot.counts_by_action(organization_id, cutoff)
    gone = gone_by_action(by_action, after_purge)
    Enum.each(created, &record_created_loss(&1, gone, after_purge))
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

  defp record_created_loss(%{id: id, excluded_actions: excluded}, gone, after_purge) do
    excluded = MapSet.new(excluded || [], &to_string/1)
    lost = for {_action, %{events: n} = loss} <- owed(gone, excluded), n > 0, do: loss

    if lost != [],
      do: write_created_loss(id, lost |> combine() |> bound_by(owed(after_purge, excluded))),
      else: :ok
  end

  # The by-action counts of the actions a destination does not exclude.
  defp owed(by_action, excluded),
    do:
      for(
        {action, counts} <- by_action,
        not MapSet.member?(excluded, action),
        do: {action, counts}
      )

  defp combine(losses),
    do: %{
      events: losses |> Enum.map(& &1.events) |> Enum.sum(),
      first_at: losses |> Enum.map(& &1.first_at) |> Enum.min(DateTime),
      last_at: losses |> Enum.map(& &1.last_at) |> Enum.max(DateTime)
    }

  # As lost_range/3 does for a leased destination: the purge deletes oldest
  # first across every action, so while any event of an action the
  # destination does not exclude is still there, the earliest of them bounds
  # the last lost one. With none left, every lost event is gone and the
  # newest counted time stands. bounded_last/3 keeps the last time at or
  # after the first.
  defp bound_by(loss, []), do: loss

  defp bound_by(loss, survivors) do
    first_left =
      survivors |> Enum.map(fn {_action, left} -> left.first_at end) |> Enum.min(DateTime)

    %{loss | last_at: bounded_last(loss.first_at, loss.last_at, first_left)}
  end

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

  # Plain fields only, so a destination's secrets are never decrypted here.
  defp lock_destination(id) do
    from(d in Destination,
      where: d.id == ^id,
      lock: "FOR UPDATE",
      select: %{id: d.id, organization_id: d.organization_id, kind: d.kind}
    )
    |> Repo.one()
  end
end
