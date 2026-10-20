defmodule Kanban.AuditLog.Export do
  @moduledoc """
  The audit-log export: reading matching events in keyset batches and encoding
  them as CSV or JSON chunks for the site-admin and org-admin downloads.

  `Kanban.AuditLog` delegates `export_stream/3` and `export_truncated?/3` here,
  so callers keep using the context's public API. The reading half was split
  out of `Kanban.AuditLog` to keep that module focused on writing, listing and
  purging events.

  ## Reading

  `export_stream/3` walks the table newest first in keyset batches of
  `:batch_size` rows (never by offset) and stops at the optional TOTAL
  `:max_rows` cap. `export_truncated?/3` tells the caller beforehand whether
  that cap will cut the file.

  ## Encoding

  The encoders (`encode_stream/2`, `csv_rows/1`, `json_rows/2`, `row_map/1`)
  are pure. CSV cells go through the shared `Kanban.CSV` encoder, so every
  cell is neutralised against spreadsheet formula injection and RFC-4180
  quoted. JSON is a single array of objects whose metadata maps are kept
  intact.

  The column keys are data identifiers (stable across locales), not UI copy,
  so they are deliberately not translated.
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.OrganizationScope
  alias Kanban.AuditLog.Query
  alias Kanban.CSV
  alias Kanban.Repo

  @columns ~w(id inserted_at action actor_user_id actor_email ip metadata)
  @default_batch_size 500

  @doc """
  A lazy stream of export chunks (iodata) for every event matching `filters`
  (see `Kanban.AuditLog.list_events/2`), newest first, as `:csv` (header line
  then rows) or `:json` (one array of objects).

  Events are fetched in keyset batches as the stream is consumed, so an export
  never loads the whole table and holds no transaction or connection while the
  response is being sent. Events inserted after the export starts are newer
  than its first batch and are therefore not included.

  `opts` (any other key raises `ArgumentError`):

    * `:batch_size` — rows fetched per round trip (default #{@default_batch_size}).
    * `:max_rows` — the TOTAL number of rows the export may hold (default
      `:infinity`), applied before encoding, so a capped file is still
      well-formed. `Kanban.AuditLog.stream_events/2` has no such option; its
      per-round-trip size is `:batch_size`, as here.
    * `:redact_actors_outside` — an Organization id; see
      `Kanban.AuditLog.list_events_page/2`.
  """
  @spec export_stream(keyword(), :csv | :json, keyword()) :: Enumerable.t()
  def export_stream(filters, format, opts \\ []) when format in [:csv, :json] do
    opts =
      Keyword.validate!(opts,
        batch_size: @default_batch_size,
        max_rows: :infinity,
        redact_actors_outside: nil
      )

    {nil, opts[:max_rows]}
    |> Stream.unfold(&next_batch(filters, &1, opts[:batch_size]))
    |> Stream.map(&redact(&1, opts[:redact_actors_outside]))
    |> encode_stream(format)
  end

  @doc """
  Whether `export_stream/3` capped at `max_rows` would omit a matching event
  (reads at most `max_rows + 1` rows). `pending`, a row about to be written,
  takes a place if `filters` admit it (`Kanban.AuditLog.Query.matches?/2`).
  """
  @spec export_truncated?(keyword(), pos_integer(), map()) :: boolean()
  def export_truncated?(filters, max_rows, pending) when is_integer(max_rows) and max_rows > 0 do
    filters = Keyword.delete(filters, :cursor)
    existing = filters |> Query.bounded_count(max_rows + 1) |> Repo.one()
    existing + if(Query.matches?(filters, pending), do: 1, else: 0) > max_rows
  end

  # A counted keyset loop: no batch asks for more rows than the cap has left.
  defp next_batch(_filters, :done, _batch_size), do: nil
  defp next_batch(_filters, {_cursor, 0}, _batch_size), do: nil

  defp next_batch(filters, {cursor, remaining}, batch_size) do
    limit = min(batch_size, remaining)

    case fetch_batch(Keyword.put(filters, :cursor, cursor), limit) do
      [] -> nil
      batch when length(batch) < limit -> {batch, :done}
      batch -> {batch, {batch |> List.last() |> keyset_position(), spend(remaining, limit)}}
    end
  end

  # Newest first with the actor preloaded, as `Kanban.AuditLog.list_events/2`.
  defp fetch_batch(filters, limit) do
    filters
    |> Query.events(:desc)
    |> Query.with_actor()
    |> limit(^limit)
    |> Repo.all()
  end

  defp spend(:infinity, _rows), do: :infinity
  defp spend(remaining, rows), do: remaining - rows

  defp keyset_position(%AuditEvent{inserted_at: at, id: id}), do: {at, id}

  defp redact(events, nil), do: events

  defp redact(events, organization_id),
    do: OrganizationScope.redact_outside_actors(events, organization_id)

  @doc """
  Wraps a stream of event batches into a stream of export chunks: for `:csv`
  the header line then one chunk per batch; for `:json` a single array, so an
  export with no rows is `[]`.
  """
  @spec encode_stream(Enumerable.t(), :csv | :json) :: Enumerable.t()
  def encode_stream(batches, :csv) do
    Stream.concat([csv_header()], Stream.map(batches, &csv_rows/1))
  end

  def encode_stream(batches, :json) do
    rows =
      batches
      |> Stream.with_index()
      |> Stream.map(fn {batch, index} -> json_rows(batch, index == 0) end)

    Stream.concat([["["], rows, ["]"]])
  end

  @doc "The CSV header line, CRLF-terminated."
  @spec csv_header() :: binary()
  def csv_header, do: CSV.encode_row(@columns) <> "\r\n"

  @doc "Encodes a batch of events as CSV lines, each CRLF-terminated."
  @spec csv_rows([AuditEvent.t()]) :: iodata()
  def csv_rows(events) do
    Enum.map(events, fn event ->
      row = row_map(event)

      fields =
        Enum.map(@columns, fn
          "metadata" -> Jason.encode!(row["metadata"])
          column -> row[column]
        end)

      [CSV.encode_row(fields), "\r\n"]
    end)
  end

  @doc """
  Encodes a batch of events as comma-separated JSON objects (no brackets).
  `first?` says whether this batch opens the array, i.e. whether it needs a
  leading comma.
  """
  @spec json_rows([AuditEvent.t()], boolean()) :: iodata()
  def json_rows([], _first?), do: []

  def json_rows(events, first?) do
    body = Enum.map_intersperse(events, ",", &Jason.encode_to_iodata!(row_map(&1)))
    if first?, do: body, else: [",", body]
  end

  @doc """
  The exported shape of one event. `actor_email` is `nil` when the event has no
  actor or the actor's account was deleted; `actor_user_id` then falls back to
  the `user_id` kept in the metadata, so a deleted actor is still identifiable.
  """
  @spec row_map(AuditEvent.t()) :: %{String.t() => term()}
  def row_map(%AuditEvent{} = event) do
    %{
      "id" => event.id,
      "inserted_at" => DateTime.to_iso8601(event.inserted_at),
      "action" => event.action,
      "actor_user_id" => event.actor_user_id || event.metadata["user_id"],
      "actor_email" => actor_email(event),
      "ip" => event.ip,
      "metadata" => event.metadata || %{}
    }
  end

  defp actor_email(%AuditEvent{actor_user: %{email: email}}), do: email
  defp actor_email(_event), do: nil
end
