defmodule Kanban.AuditLog.Export do
  @moduledoc """
  Pure encoders turning batches of `Kanban.AuditLog.AuditEvent` rows into CSV
  or JSON chunks for the admin audit-log export.

  CSV cells go through the shared `Kanban.CSV` encoder, so every cell is
  neutralised against spreadsheet formula injection and RFC-4180 quoted. JSON
  is a single array of objects whose metadata maps are kept intact.

  The column keys are data identifiers (stable across locales), not UI copy,
  so they are deliberately not translated.
  """

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.CSV

  @columns ~w(id inserted_at action actor_user_id actor_email ip metadata)

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
