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

  The Organization `prepare/4` is given is the live row, and every event of a
  batch carries its id and name. A cut stores them on the cursor with the
  other `pending_` fields, as `pending_organization_id` and
  `pending_organization_name`, and a re-read builds its events from them, so
  every attempt of one `batch_id` carries the same Organization details even
  when the Organization is renamed between attempts (D428). The batch returned
  carries the Organization it was built for, which is what the request
  envelope names. A pending batch with no stored snapshot (one cut before it
  was recorded), or one recorded for another Organization, is built from the
  live row and the snapshot is stored then. The signature time (`signed_at`)
  is taken afresh, in whole seconds, by the adapter on every attempt. The
  actor fields the Reader reads live, and adapter settings outside the
  filters, are not frozen (design §8.3).

  For a kind with a `max_event_age` (Datadog), `:older_than` is the time
  before which an event is too old to send (§5.2). A batch never holds such
  an event: a pending batch that does is discarded and cut again, and a cut
  stops before the first one. `Kanban.AuditStream.AgeLimit` has already moved
  the cursor past the too-old events at its head, so the event a cut stops
  at becomes the head of the next run's, which records it as a gap.
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
          organization: Payload.organization(),
          first: Reader.pair(),
          last: Reader.pair()
        }

  @doc """
  The batch to send for `destination` at `cursor`, and the cursor fields to
  write before sending it, or `{:empty, attrs}` when no event is waiting.

  Options: `:horizon` and `:batch_size`, passed to `Reader.next_batch/3`,
  and `:older_than`, as above.
  """
  @spec prepare(Destination.t(), Cursor.t(), Payload.organization(), keyword()) ::
          {:ok, batch(), map()} | {:empty, map()}
  def prepare(%Destination{} = destination, %Cursor{} = cursor, organization, opts \\ []) do
    filters = filters(destination, cursor)

    destination
    |> reread(cursor, organization, filters)
    |> within_age(opts[:older_than])
    |> prepared({destination, cursor, organization, filters, opts})
  end

  # A pending batch that now holds a too-old event is cut again, so the
  # event is recorded as a gap rather than sent under its old batch_id.
  defp within_age({:ok, events}, %DateTime{} = older_than) do
    if Enum.any?(events, &too_old?(&1, older_than)), do: :discard, else: {:ok, events}
  end

  defp within_age(reread, _older_than), do: reread

  defp prepared({:ok, events}, {_destination, cursor, organization, _filters, _opts}) do
    {snapshot, attrs} = snapshot(cursor, organization)
    {:ok, batch(cursor.pending_batch_id, events, snapshot), attrs}
  end

  defp prepared(:discard, {destination, cursor, organization, filters, opts}),
    do: cut(destination, cursor, organization, filters, opts, Outcome.cleared_pending_attrs())

  defp prepared(:none, {destination, cursor, organization, filters, opts}),
    do: cut(destination, cursor, organization, filters, opts, %{})

  @doc """
  The Organization a pending batch at `cursor` is built for, and the cursor
  fields to write for it: the snapshot stored when the batch was cut, and no
  fields, when it was stored for `organization`; otherwise `organization`, the
  live row, and the fields that store it.
  """
  @spec snapshot(Cursor.t(), Payload.organization()) :: {Payload.organization(), map()}
  def snapshot(
        %Cursor{pending_organization_id: id, pending_organization_name: name},
        %{id: id}
      )
      when is_binary(name),
      do: {%{id: id, name: name}, %{}}

  def snapshot(%Cursor{}, organization), do: {organization, snapshot_attrs(organization)}

  defp snapshot_attrs(%{id: id, name: name}),
    do: %{pending_organization_id: id, pending_organization_name: name}

  @doc """
  The `Kanban.AuditStream.Reader` filters of `destination` at `cursor`: its
  `not_before`, the restored rows a re-seed recorded as a gap (§8.8),
  excluded actions and personal-data choice. Either may be a map with those
  fields rather than the struct.
  """
  @spec filters(Destination.t() | map(), Cursor.t() | map()) :: keyword()
  def filters(destination, cursor) do
    [
      not_before: cursor.not_before,
      restored: restored(cursor),
      excluded_actions: destination.excluded_actions,
      include_personal_data: destination.include_personal_data
    ]
  end

  defp restored(%{restored_max_event_id: nil, restored_min_txid: nil}), do: nil

  defp restored(%{restored_max_event_id: max_id, restored_min_txid: min_txid}),
    do: {max_id, min_txid}

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

    organization.id
    |> Reader.next_batch({cursor.last_txid, cursor.last_event_id}, read_opts)
    |> recent(opts[:older_than])
    |> case do
      [] ->
        {:empty, attrs}

      events ->
        batch = batch(Ecto.UUID.generate(), events, organization)
        pending = pending_attrs(batch, destination)

        {:ok, batch, attrs |> Map.merge(pending) |> Map.merge(snapshot_attrs(organization))}
    end
  end

  defp pending_attrs(
         %{first: {first_txid, first_id}, last: {last_txid, last_id}} = batch,
         destination
       ) do
    %{
      pending_batch_id: batch.batch_id,
      pending_first_txid: first_txid,
      pending_first_id: first_id,
      pending_last_txid: last_txid,
      pending_last_id: last_id,
      pending_attempts: 0,
      pending_filter_version: destination.filter_version
    }
  end

  defp recent(events, nil), do: events
  defp recent(events, older_than), do: Enum.take_while(events, &(not too_old?(&1, older_than)))

  defp too_old?(event, older_than), do: DateTime.compare(event.inserted_at, older_than) == :lt

  defp batch(batch_id, events, organization) do
    payloads = Enum.map(events, &Payload.build(&1, organization))
    first = hd(events)
    last = List.last(events)

    %{
      batch_id: batch_id,
      events: events,
      payloads: payloads,
      bytes: payloads |> Enum.map(&payload_size/1) |> Enum.sum(),
      organization: organization,
      first: {first.txid, first.id},
      last: {last.txid, last.id}
    }
  end

  defp encoded_size(event, organization),
    do: event |> Payload.build(organization) |> payload_size()

  defp payload_size(payload),
    do: payload |> Jason.encode_to_iodata!() |> IO.iodata_length() |> Kernel.+(1)
end
