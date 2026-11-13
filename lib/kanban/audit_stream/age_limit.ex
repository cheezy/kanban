defmodule Kanban.AuditStream.AgeLimit do
  @moduledoc """
  Events too old for a destination's kind to accept
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §5.2, §9.6). Datadog drops log
  entries more than 18 hours old, so its adapter's `max_event_age/0` is 17
  hours; the other kinds accept any age (`:infinity`).

  In `Kanban.AuditStream.DispatchWorker`'s prepare step, under the
  destination's row lock and the run's lease, `skip/4` moves the cursor past
  the too-old events at the head of the destination's backlog and records
  them as a gap with reason `too_old` (`Kanban.AuditStream.Gaps`), so they
  are never sent and never lost silently. A pending batch is discarded when
  the cursor moves, since it began with those events. `threshold/2` is also
  passed to `Kanban.AuditStream.PendingBatch` as `:older_than`, which keeps
  a too-old event that sorts after a recent one in commit order out of the
  batch, for the next run to record.
  """

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  @doc """
  The time before which an event is too old for `adapter`'s kind at `now`,
  or `nil` when the kind accepts any age.
  """
  @spec threshold(module(), DateTime.t()) :: DateTime.t() | nil
  def threshold(adapter, %DateTime{} = now) do
    case adapter.max_event_age() do
      :infinity -> nil
      seconds when is_integer(seconds) -> DateTime.add(now, -seconds, :second)
    end
  end

  @doc """
  Moves `cursor` past the too-old events at the head of `destination`'s
  backlog and records them as a gap. Returns the cursor, moved or not, and
  the recorded loss for `Kanban.AuditStream.Gaps.emit_recorded/1` (or
  `nil`). Call it inside the transaction that holds the destination's row
  lock and the cursor's lease. `opts` takes `:horizon`.
  """
  @spec skip(Destination.t(), Cursor.t(), DateTime.t() | nil, keyword()) ::
          {:ok, Cursor.t(), Gaps.recorded() | nil} | {:error, Ecto.Changeset.t()}
  def skip(destination, cursor, threshold, opts \\ [])

  def skip(%Destination{}, %Cursor{} = cursor, nil, _opts), do: {:ok, cursor, nil}

  def skip(%Destination{} = destination, %Cursor{} = cursor, %DateTime{} = threshold, opts) do
    read_opts = PendingBatch.filters(destination, cursor) ++ Keyword.take(opts, [:horizon])
    position = {cursor.last_txid, cursor.last_event_id}

    case Reader.too_old(destination.organization_id, position, threshold, read_opts) do
      nil -> {:ok, cursor, nil}
      too_old -> move_past(destination, cursor, too_old)
    end
  end

  defp move_past(destination, cursor, too_old) do
    {last_txid, last_id} = too_old.last

    attrs =
      cursor
      |> discard_pending()
      |> Map.merge(%{
        last_txid: last_txid,
        last_event_id: last_id,
        last_inserted_at: too_old.last_inserted_at
      })

    with {:ok, recorded} <- Gaps.record(destination, :too_old, too_old, DateTime.utc_now()),
         {:ok, cursor} <- cursor |> Cursor.changeset(attrs) |> Repo.update() do
      {:ok, cursor, recorded}
    end
  end

  defp discard_pending(%Cursor{pending_batch_id: nil}), do: %{}
  defp discard_pending(%Cursor{}), do: Outcome.cleared_pending_attrs()
end
