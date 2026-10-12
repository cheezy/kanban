defmodule Kanban.TelemetryDocsTest do
  @moduledoc """
  Keeps `docs/telemetry.md` in step with `Kanban.Telemetry.Catalog` (W2346).

  The catalog is read through `Kanban.Telemetry.Catalog.events/0` only, so a
  new catalog submodule is covered without touching this test.
  """
  use ExUnit.Case, async: true

  alias Kanban.Telemetry.Catalog
  alias Kanban.TelemetryDoc

  @refresh_hint "Refresh it with: MIX_ENV=test mix run --no-start -e 'IO.write(Kanban.TelemetryDoc.reference())'"

  setup_all do
    %{doc: File.read!(TelemetryDoc.doc_path()), events: Catalog.events()}
  end

  describe "docs/telemetry.md" do
    test "every catalog event is documented", %{doc: doc, events: events} do
      rows = TelemetryDoc.reference_rows(doc)

      problems =
        for entry <- events, Map.get(rows, entry.name) != TelemetryDoc.row(entry) do
          case Map.fetch(rows, entry.name) do
            {:ok, row} ->
              "#{inspect(entry.name)} is out of date:\n  doc:      #{row}\n  expected: #{TelemetryDoc.row(entry)}"

            :error ->
              "#{inspect(entry.name)} is missing; expected: #{TelemetryDoc.row(entry)}"
          end
        end

      assert problems == [], Enum.join(problems, "\n") <> "\n" <> @refresh_hint
    end

    test "the event reference matches a fresh render of the catalog", %{doc: doc, events: events} do
      assert {:ok, section} = TelemetryDoc.generated_section(doc),
             "docs/telemetry.md must hold #{TelemetryDoc.start_marker()} and #{TelemetryDoc.end_marker()}, in that order"

      assert section == TelemetryDoc.reference(events), @refresh_hint
    end

    test "span events documented with suffixes", %{doc: doc, events: events} do
      spans = Enum.filter(events, &(&1.kind == :span))
      assert spans != [], "the catalog has no span, so this test checks nothing"

      named = TelemetryDoc.named_events(doc)
      rows = TelemetryDoc.reference_rows(doc)

      for %{name: prefix} <- spans do
        assert rows[prefix] =~ "| span |", "#{inspect(prefix)} is not marked as a span"

        for suffix <- TelemetryDoc.span_suffixes() do
          assert MapSet.member?(named, prefix ++ [suffix]),
                 "docs/telemetry.md never names #{inspect(prefix ++ [suffix])}"
        end
      end
    end

    test "doc names no unknown event", %{doc: doc, events: events} do
      unknown =
        doc
        |> TelemetryDoc.named_events()
        |> MapSet.difference(TelemetryDoc.emittable_names(events))
        |> Enum.map(&describe_name/1)

      assert unknown == [],
             "docs/telemetry.md names events the catalog does not have: " <>
               Enum.join(unknown, ", ")
    end

    test "legacy events are marked", %{doc: doc, events: events} do
      rows = TelemetryDoc.reference_rows(doc)
      legacy = Enum.filter(events, & &1.legacy)
      assert legacy != [], "the catalog has no legacy event, so this test checks nothing"

      for entry <- events do
        marked? = rows |> Map.get(entry.name, "") |> String.contains?("| event, legacy |")

        assert marked? == entry.legacy,
               "#{inspect(entry.name)} has legacy: #{entry.legacy} in the catalog, " <>
                 "but its reference row says otherwise. " <> @refresh_hint
      end
    end

    test "hand-written event tables list the catalog's metadata keys", %{doc: doc} do
      rows = TelemetryDoc.table_metadata(doc)
      assert length(rows) > 100, "expected the doc's event tables to be parsed"

      problems =
        for {line, name, keys} <- rows,
            problem = metadata_problem(name, keys),
            do: "docs/telemetry.md:#{line}: #{problem}"

      assert problems == [], Enum.join(problems, "\n")
    end
  end

  describe "docs/UNCLAIM-TASKS.md" do
    test "names only events the catalog has", %{events: events} do
      doc = [File.cwd!(), "docs", "UNCLAIM-TASKS.md"] |> Path.join() |> File.read!()
      named = TelemetryDoc.named_events(doc)

      assert MapSet.member?(named, [:kanban, :task, :unclaimed])
      assert MapSet.member?(named, [:kanban, :api, :task_unclaimed])

      unknown =
        named
        |> MapSet.difference(TelemetryDoc.emittable_names(events))
        |> Enum.map(&describe_name/1)

      assert unknown == [],
             "docs/UNCLAIM-TASKS.md names unknown events: " <> Enum.join(unknown, ", ")
    end

    test "lists the catalog's metadata keys for the unclaim events" do
      doc = [File.cwd!(), "docs", "UNCLAIM-TASKS.md"] |> Path.join() |> File.read!()
      rows = TelemetryDoc.table_metadata(doc)

      assert rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
               [[:kanban, :api, :task_unclaimed], [:kanban, :task, :unclaimed]]

      problems =
        for {line, name, keys} <- rows,
            problem = metadata_problem(name, keys),
            do: "docs/UNCLAIM-TASKS.md:#{line}: #{problem}"

      assert problems == [], Enum.join(problems, "\n")
    end
  end

  describe "Kanban.TelemetryDoc" do
    test "row/1 renders an event, a legacy event and a span" do
      event = %{
        name: [:kanban, :thing, :happened],
        kind: :event,
        legacy: false,
        measurements: [:count],
        metadata: [:board_id, :user_id],
        description: "A thing happened. a | b."
      }

      assert TelemetryDoc.row(event) ==
               "| `[:kanban, :thing, :happened]` | event | `count` | `board_id`, `user_id` | A thing happened. a \\| b. |"

      assert TelemetryDoc.row(%{event | legacy: true, metadata: []}) =~
               "| event, legacy | `count` | none |"

      span = %{event | name: [:kanban, :thing], kind: :span, measurements: [:row_count]}

      assert TelemetryDoc.row(span) =~
               "| span | `duration` on `:stop` and `:exception`; `row_count` on `:stop` |"

      assert TelemetryDoc.row(%{span | measurements: []}) =~
               "| span | `duration` on `:stop` and `:exception` |"
    end

    test "reference/1 groups by domain and lists span names" do
      events = [
        %{
          name: [:kanban, :zed, :done],
          domain: :zed,
          kind: :event,
          legacy: false,
          measurements: [:count],
          metadata: [],
          description: "Z."
        },
        %{
          name: [:kanban, :alpha],
          domain: :alpha,
          kind: :span,
          legacy: false,
          measurements: [],
          metadata: [:kind],
          description: "A."
        }
      ]

      rendered = TelemetryDoc.reference(events)

      assert [alpha, zed] = String.split(rendered, "\n### ", trim: true)
      assert alpha =~ "### Domain `alpha`"

      assert alpha =~
               "it emits `[:kanban, :alpha, :start]`, `[:kanban, :alpha, :stop]` and `[:kanban, :alpha, :exception]`."

      assert zed =~ "Domain `zed`"
      refute zed =~ "is a span"
    end

    test "generated_section/1 needs both markers in order" do
      start = TelemetryDoc.start_marker()
      stop = TelemetryDoc.end_marker()

      assert TelemetryDoc.generated_section("a\n#{start}\nbody\n#{stop}\nz") == {:ok, "body\n"}
      assert TelemetryDoc.generated_section("a\n#{start}\nbody") == :error
      assert TelemetryDoc.generated_section("#{stop}\n#{start}\n") == :error
      assert TelemetryDoc.reference_rows("no markers here") == %{}
    end

    test "named_events/1 finds names, skips placeholders and flags unknown atoms" do
      named =
        TelemetryDoc.named_events("""
        `[:kanban, :task, :claimed]` and [:kanban, :export, :stop]
        `[:kanban, domain, action]` and `[:kanban, :api, action]`
        `[:kanban, :w2346_no_such_atom_zq, :ever]`
        """)

      assert MapSet.member?(named, [:kanban, :task, :claimed])
      assert MapSet.member?(named, [:kanban, :export, :stop])
      assert MapSet.member?(named, {:unknown, "[:kanban, :w2346_no_such_atom_zq, :ever]"})
      assert MapSet.size(named) == 3
    end

    test "emittable_names/1 expands spans" do
      names =
        TelemetryDoc.emittable_names([
          %{name: [:kanban, :a, :b], kind: :event},
          %{name: [:kanban, :c], kind: :span}
        ])

      assert names ==
               MapSet.new([
                 [:kanban, :a, :b],
                 [:kanban, :c],
                 [:kanban, :c, :start],
                 [:kanban, :c, :stop],
                 [:kanban, :c, :exception]
               ])
    end

    test "table_metadata/1 reads only tables with Event and Metadata columns" do
      markdown = """
      | Event | Kind | Metadata | Emitted by |
      |---|---|---|---|
      | `[:kanban, :task, :claimed]` | event | `task_id`, `board_id` | `Kanban.Tasks` |

      | Field | Value |
      |---|---|
      | `[:kanban, :task, :moved]` | `task_id` |
      """

      assert TelemetryDoc.table_metadata(markdown) == [
               {3, [:kanban, :task, :claimed], ["task_id", "board_id"]}
             ]
    end
  end

  defp metadata_problem(name, keys) do
    case Catalog.fetch(name) do
      {:ok, entry} ->
        declared = Enum.map(entry.metadata, &Atom.to_string/1)

        if Enum.sort(keys) != Enum.sort(declared),
          do:
            "#{inspect(name)} lists #{inspect(keys)} but the catalog declares #{inspect(declared)}"

      :error ->
        "#{describe_name(name)} is not in the catalog"
    end
  end

  defp describe_name({:unknown, literal}), do: literal
  defp describe_name(name), do: inspect(name)
end
