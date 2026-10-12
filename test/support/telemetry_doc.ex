defmodule Kanban.TelemetryDoc do
  @moduledoc """
  Test-only helpers that keep `docs/telemetry.md` in step with
  `Kanban.Telemetry.Catalog` (W2346).

  The doc's "Event reference" section is rendered from the catalog by
  `reference/0` and sits between two HTML comment markers. The drift test in
  `test/kanban/telemetry_docs_test.exs` compares the text between the markers
  with a fresh render, so a catalog change that is not copied into the doc
  fails the test, and so does an event the doc names that the catalog lacks.

  To refresh the section after changing the catalog, render it and paste the
  output between the markers:

      MIX_ENV=test mix run --no-start -e 'IO.write(Kanban.TelemetryDoc.reference())'

  Everything here reads the catalog through its public API,
  `Kanban.Telemetry.Catalog.events/0`, never one catalog file.
  """

  alias Kanban.Telemetry.Catalog

  @start_marker "<!-- event-reference:start -->"
  @end_marker "<!-- event-reference:end -->"
  @span_suffixes [:start, :stop, :exception]
  @event_name ~r/\[:kanban(?:, :[a-z0-9_]+)+\]/
  @backticked_key ~r/`([a-z0-9_]+)`/

  @doc "The path of the telemetry doc, from the project root."
  def doc_path, do: Path.join([File.cwd!(), "docs", "telemetry.md"])

  @doc "The marker line that opens the generated event reference."
  def start_marker, do: @start_marker

  @doc "The marker line that closes the generated event reference."
  def end_marker, do: @end_marker

  @doc "The suffixes `:telemetry` appends to a span prefix."
  def span_suffixes, do: @span_suffixes

  @doc """
  Renders the event reference from the catalog: one table per domain, in
  alphabetical domain order, with the events in catalog order, followed by the
  emitted names of each span in that domain.
  """
  def reference(events \\ Catalog.events()) do
    events
    |> Enum.group_by(& &1.domain)
    |> Enum.sort_by(fn {domain, _entries} -> Atom.to_string(domain) end)
    |> Enum.map_join("\n", fn {domain, entries} -> domain_section(domain, entries) end)
  end

  @doc "Renders the reference table row for one catalog entry."
  def row(entry) do
    cells = [
      "`#{format_name(entry.name)}`",
      kind_label(entry),
      measurements_cell(entry),
      keys_cell(entry.metadata),
      escape_cell(entry.description)
    ]

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  @doc """
  Returns the text between the event reference markers, or `:error` when
  either marker is missing or they are out of order.
  """
  def generated_section(markdown) when is_binary(markdown) do
    with [_before, rest] <- String.split(markdown, @start_marker <> "\n", parts: 2),
         [section, _after] <- String.split(rest, @end_marker, parts: 2) do
      {:ok, section}
    else
      _missing -> :error
    end
  end

  @doc """
  Returns the reference rows in `markdown`, as a map from event name to the
  row's line, for every table row in the generated section that starts with
  an event name.
  """
  def reference_rows(markdown) when is_binary(markdown) do
    case generated_section(markdown) do
      {:ok, section} ->
        section
        |> String.split("\n")
        |> Enum.flat_map(&row_entry/1)
        |> Map.new()

      :error ->
        %{}
    end
  end

  @doc """
  Returns every event name written in `markdown` as an Elixir list of atoms,
  such as `[:kanban, :task, :claimed]`, in prose, tables and code examples
  alike. Placeholders such as `[:kanban, domain, action]` are not names.
  """
  def named_events(markdown) when is_binary(markdown) do
    @event_name
    |> Regex.scan(markdown)
    |> Enum.map(fn [literal] -> parse_name(literal) end)
    |> MapSet.new()
  end

  @doc """
  Returns every name the app can emit: each catalog event, plus each span
  prefix and the three names `:telemetry` derives from it.
  """
  def emittable_names(events \\ Catalog.events()) do
    events
    |> Enum.flat_map(fn
      %{kind: :span, name: name} -> [name | Enum.map(@span_suffixes, &(name ++ [&1]))]
      %{name: name} -> [name]
    end)
    |> MapSet.new()
  end

  @doc """
  Returns the metadata keys each hand-written table in `markdown` lists, as
  `{line_number, event_name, keys}` tuples, for every table whose header has
  an `Event` column and a `Metadata` column.
  """
  def table_metadata(markdown) when is_binary(markdown) do
    {_header, rows} =
      markdown
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({nil, []}, &collect_table_row/2)

    Enum.reverse(rows)
  end

  defp domain_section(domain, entries) do
    header = [
      "### Domain `#{domain}`",
      "",
      "| Event | Kind | Measurements | Metadata | Description |",
      "|---|---|---|---|---|"
    ]

    spans = for %{kind: :span} = entry <- entries, do: span_line(entry)
    span_block = if spans == [], do: [], else: [""] ++ spans

    Enum.join(header ++ Enum.map(entries, &row/1) ++ span_block, "\n") <> "\n"
  end

  defp span_line(entry) do
    [start, stop, exception] = Enum.map(@span_suffixes, &"`#{format_name(entry.name ++ [&1])}`")

    "- `#{format_name(entry.name)}` is a span: it emits #{start}, #{stop} and #{exception}."
  end

  defp kind_label(%{kind: :span}), do: "span"
  defp kind_label(%{legacy: true}), do: "event, legacy"
  defp kind_label(_entry), do: "event"

  defp measurements_cell(%{kind: :span, measurements: []}),
    do: "`duration` on `:stop` and `:exception`"

  defp measurements_cell(%{kind: :span, measurements: extra}),
    do: "`duration` on `:stop` and `:exception`; #{keys_cell(extra)} on `:stop`"

  defp measurements_cell(%{measurements: measurements}), do: keys_cell(measurements)

  defp keys_cell([]), do: "none"
  defp keys_cell(keys), do: Enum.map_join(keys, ", ", &"`#{&1}`")

  defp escape_cell(text), do: String.replace(text, "|", "\\|")

  defp format_name(name), do: "[" <> Enum.map_join(name, ", ", &inspect/1) <> "]"

  defp parse_name(literal) do
    literal
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(", ")
    |> Enum.map(fn ":" <> segment -> String.to_existing_atom(segment) end)
  rescue
    ArgumentError -> {:unknown, literal}
  end

  defp row_entry("| `[:kanban" <> _rest = line) do
    case Regex.run(@event_name, line) do
      [literal] -> [{parse_name(literal), line}]
      nil -> []
    end
  end

  defp row_entry(_line), do: []

  defp collect_table_row({"|" <> _rest = line, number}, {header, rows}) do
    cells = table_cells(line)

    cond do
      "Event" in cells and "Metadata" in cells ->
        {cells, rows}

      header != nil ->
        {header, metadata_row(header, cells, number, rows)}

      true ->
        {header, rows}
    end
  end

  defp collect_table_row({_line, _number}, {_header, rows}), do: {nil, rows}

  defp metadata_row(header, cells, number, rows) do
    event_cell = column(header, cells, "Event")
    metadata_cell = column(header, cells, "Metadata")

    case Regex.run(@event_name, event_cell) do
      [literal] ->
        keys = for [_match, key] <- Regex.scan(@backticked_key, metadata_cell), do: key
        [{number, parse_name(literal), keys} | rows]

      nil ->
        rows
    end
  end

  defp column(header, cells, title),
    do: Enum.at(cells, Enum.find_index(header, &(&1 == title)), "")

  defp table_cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&String.trim/1)
  end
end
