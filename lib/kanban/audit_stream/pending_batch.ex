defmodule Kanban.AuditStream.PendingBatch do
  @moduledoc """
  The batch a destination is sending: re-read while it is pending, cut when
  there is none (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.2, §8.3).

  `prepare/4` runs inside the run's first transaction, on the cursor the run
  holds the lease on, and returns the batch to send with the cursor fields to
  write before the send:

    * a pending batch cut under the destination's current `filter_version`
      is re-read with `Kanban.AuditStream.Reader.read_range/4`, exactly the
      same range under the same `batch_id`, however many events arrived
      since;
    * a pending batch cut under an older `filter_version` is discarded and a
      new batch is cut, with a new `batch_id`, under the current settings
      (D16), so a `batch_id` always names the same events. So is a pending
      batch whose first or last event is gone, which is how retention
      (§8.6), deleting the oldest events, shrinks a range: the survivors go
      out under a new `batch_id`, never as a smaller batch under the old
      one. Retention records the gap it makes;
    * otherwise the next batch is cut with `Reader.next_batch/3`: up to 500
      events and 900,000 bytes, measured as the JSON size of each built
      `Kanban.AuditStream.Payload` event plus one separator. Its `batch_id`
      is new, and the cut records the destination's `filter_version` as
      `pending_filter_version`.

  When nothing is waiting it returns `{:empty, attrs}`; `attrs` then discards
  a stale pending batch, if there was one, and the cursor stays where it is.
  """

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Payload
  alias Kanban.AuditStream.Reader

  @type batch :: %{
          batch_id: Ecto.UUID.t(),
          events: [Kanban.AuditLog.AuditEvent.t()],
          payloads: [Payload.t()],
          bytes: non_neg_integer(),
          first: Reader.pair(),
          last: Reader.pair()
        }

  @doc """
  The batch to send for `destination` at `cursor`, and the cursor fields to
  write before sending it, or `{:empty, attrs}` when no event is waiting.

  Options: `:horizon` and `:batch_size`, passed to `Reader.next_batch/3`.
  """
  @spec prepare(Destination.t(), Cursor.t(), Payload.organization(), keyword()) ::
          {:ok, batch(), map()} | {:empty, map()}
  def prepare(%Destination{} = destination, %Cursor{} = cursor, organization, opts \\ []) do
    filters = filters(destination, cursor)

    destination
    |> reread(cursor, organization, filters)
    |> prepared({destination, cursor, organization, filters, opts})
  end

  defp prepared({:ok, events}, {_destination, cursor, organization, _filters, _opts}),
    do: {:ok, batch(cursor.pending_batch_id, events, organization), %{}}

  defp prepared(:discard, {destination, cursor, organization, filters, opts}),
    do: cut(destination, cursor, organization, filters, opts, Outcome.cleared_pending_attrs())

  defp prepared(:none, {destination, cursor, organization, filters, opts}),
    do: cut(destination, cursor, organization, filters, opts, %{})

  @doc """
  The `Kanban.AuditStream.Reader` filters of `destination` at `cursor`: its
  `not_before`, excluded actions and personal-data choice. Either may be a
  map with those fields rather than the struct.
  """
  @spec filters(Destination.t() | map(), Cursor.t() | map()) :: keyword()
  def filters(destination, cursor) do
    [
      not_before: cursor.not_before,
      excluded_actions: destination.excluded_actions,
      include_personal_data: destination.include_personal_data
    ]
  end

  defp reread(_destination, %Cursor{pending_batch_id: nil}, _organization, _filters), do: :none

  defp reread(
         %Destination{filter_version: version},
         %Cursor{pending_filter_version: version} = cursor,
         organization,
         filters
       ) do
    first = {cursor.pending_first_txid, cursor.pending_first_id}
    last = {cursor.pending_last_txid, cursor.pending_last_id}

    organization.id
    |> Reader.read_range(first, last, filters)
    |> whole_range(first, last)
  end

  # Cut under another filter_version (D16), or before versions were recorded.
  defp reread(_destination, _cursor, _organization, _filters), do: :discard

  # The re-read still spans the range it was cut as, end to end.
  defp whole_range([], _first, _last), do: :discard

  defp whole_range([%{txid: txid, id: id} | _] = events, {txid, id}, last) do
    case List.last(events) do
      %{txid: last_txid, id: last_id} when {last_txid, last_id} == last -> {:ok, events}
      _shrunk -> :discard
    end
  end

  defp whole_range(_events, _first, _last), do: :discard

  defp cut(destination, cursor, organization, filters, opts, attrs) do
    read_opts =
      filters ++
        [size_fun: &encoded_size(&1, organization)] ++ Keyword.take(opts, [:horizon, :batch_size])

    case Reader.next_batch(organization.id, {cursor.last_txid, cursor.last_event_id}, read_opts) do
      [] ->
        {:empty, attrs}

      events ->
        batch = batch(Ecto.UUID.generate(), events, organization)
        {first_txid, first_id} = batch.first
        {last_txid, last_id} = batch.last

        pending = %{
          pending_batch_id: batch.batch_id,
          pending_first_txid: first_txid,
          pending_first_id: first_id,
          pending_last_txid: last_txid,
          pending_last_id: last_id,
          pending_attempts: 0,
          pending_filter_version: destination.filter_version
        }

        {:ok, batch, Map.merge(attrs, pending)}
    end
  end

  defp batch(batch_id, events, organization) do
    payloads = Enum.map(events, &Payload.build(&1, organization))
    first = hd(events)
    last = List.last(events)

    %{
      batch_id: batch_id,
      events: events,
      payloads: payloads,
      bytes: payloads |> Enum.map(&payload_size/1) |> Enum.sum(),
      first: {first.txid, first.id},
      last: {last.txid, last.id}
    }
  end

  defp encoded_size(event, organization),
    do: event |> Payload.build(organization) |> payload_size()

  defp payload_size(payload),
    do: payload |> Jason.encode_to_iodata!() |> IO.iodata_length() |> Kernel.+(1)
end
