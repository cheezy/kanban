defmodule KanbanWeb.WorkspaceMetricsExcelExportTest do
  @moduledoc """
  Unit tests for the workspace metrics Excel workbook.

  Every test calls `generate/1` DIRECTLY with plain maps — no connection, no
  database, no fixtures — mirroring `KanbanWeb.MetricsExcelExportTest`, because
  the module only reads fields off the overview it is handed.

  Two extraction helpers are needed rather than one. Elixlsx interns STRING
  cells in `xl/sharedStrings.xml` but writes NUMERIC cells inline into
  `xl/worksheets/sheet1.xml`, so asserting a number against the shared-string
  table would pass vacuously. `strings/1` covers labels and guarded text;
  `sheet_xml/1` covers numbers — and is what proves the injection guard leaves
  non-strings alone.
  """

  use ExUnit.Case, async: true

  alias Kanban.Metrics.Workspace
  alias KanbanWeb.WorkspaceMetricsExcelExport

  @module_path "lib/kanban_web/export/workspace_metrics_excel.ex"

  defp series(minutes_list) do
    minutes_list
    |> Enum.with_index()
    |> Enum.map(fn {minutes, index} ->
      %{date: Date.add(~D[2026-07-01], index), minutes: minutes}
    end)
  end

  defp overview(attrs \\ %{}) do
    Map.merge(
      %{
        kpis: %{
          cycle_time_median_minutes: 161,
          cycle_time_delta_pct: -12.5,
          lead_time_p50_minutes: 2880,
          lead_time_delta_pct: 4.0,
          throughput_per_day: 3.25,
          throughput_delta_pct: 10.0,
          review_wait_minutes: 45,
          review_wait_delta_pct: 0.0
        },
        cycle_series: series([30, 60, 90]),
        lead_series: series([120, 240, 360]),
        throughput_series: [1, 4, 2],
        leaderboard: [
          %{name: "Claude Opus 4.8", kind: :agent, completed: 12, success_pct: 91.6}
        ],
        flow_snapshots: [
          %{date: ~D[2026-07-01], backlog: 5, ready: 3, doing: 2, review: 1, done: 8},
          %{date: ~D[2026-07-02], backlog: 4, ready: 4, doing: 3, review: 2, done: 11}
        ]
      },
      attrs
    )
  end

  defp assigns(attrs) do
    Map.merge(
      %{
        overview: overview(),
        window_days: 14,
        timezone: "Etc/UTC",
        exclude_weekends: false,
        generated_at: ~U[2026-07-19 12:00:00Z],
        board_ids: nil
      },
      attrs
    )
  end

  defp generate(attrs \\ %{}), do: attrs |> assigns() |> WorkspaceMetricsExcelExport.generate()

  defp assert_valid_xlsx({:ok, binary}) do
    assert is_binary(binary)
    assert byte_size(binary) > 0
    assert <<0x50, 0x4B, _rest::binary>> = binary
    binary
  end

  defp extract_entry({:ok, bytes}, path) do
    {:ok, handle} = :zip.zip_open(bytes, [:memory])
    {:ok, {_path, xml}} = :zip.zip_get(path, handle)
    :zip.zip_close(handle)
    to_string(xml)
  end

  defp strings(attrs \\ %{}), do: attrs |> generate() |> extract_entry(~c"xl/sharedStrings.xml")

  defp sheet_xml(attrs \\ %{}),
    do: attrs |> generate() |> extract_entry(~c"xl/worksheets/sheet1.xml")

  # An overview whose sole leaderboard participant carries the given name, used
  # to drive one hostile name through the guard per test.
  defp hostile(name) do
    %{
      overview:
        overview(%{leaderboard: [%{name: name, kind: :agent, completed: 1, success_pct: 50.0}]})
    }
  end

  describe "generate/1 — workbook structure" do
    test "returns an in-memory xlsx binary" do
      assert_valid_xlsx(generate())
    end

    test "contains a section for every area of the workspace metrics page" do
      xml = strings()

      assert xml =~ "Summary"
      assert xml =~ "Cycle time · daily median (min)"
      assert xml =~ "Throughput · tasks completed per day"
      assert xml =~ "Agents · last 14 days"
      assert xml =~ "Cumulative flow"
    end

    test "includes the lead time section as a section distinct from cycle time" do
      xml = strings()

      assert xml =~ "Lead time · daily median (min)"
      assert xml =~ "Cycle time · daily median (min)"
    end
  end

  describe "generate/1 — header block" do
    test "names the applied window, timezone, weekend filter and generation time" do
      xml = strings(%{window_days: 30, timezone: "America/Toronto"})

      assert xml =~ "Last 30 days"
      assert xml =~ "America/Toronto"
      assert xml =~ "Exclude Weekends"
      assert xml =~ "Generated"
      assert xml =~ "2026-07-19"
    end

    test "reports the board selection as a count for every scope shape" do
      assert strings(%{board_ids: nil}) =~ "All boards"
      assert strings(%{board_ids: [7]}) =~ "1 board"
      assert strings(%{board_ids: [7, 9]}) =~ "2 boards"
      assert strings(%{board_ids: []}) =~ "0 boards"
    end
  end

  describe "generate/1 — KPI section" do
    test "writes the page's formatted KPI values, not raw minutes" do
      xml = strings()

      assert xml =~ "Cycle time · median"
      assert xml =~ "2h 41m"
      assert xml =~ "Wait time · Review"
    end

    test "writes throughput without the minute formatter and signs the deltas" do
      xml = strings()

      assert xml =~ "3.25"
      assert xml =~ "-12.5%"
      assert xml =~ "+4.0%"
    end
  end

  describe "generate/1 — series sections" do
    test "writes ISO dates and numeric minute cells" do
      assert strings() =~ "2026-07-01"

      # Minutes are numeric cells, so they live inline in the sheet and are
      # absent from the shared-string table.
      assert sheet_xml() =~ "<v>90</v>"
      assert sheet_xml() =~ "<v>360</v>"
      refute strings() =~ ">90<"
    end

    test "borrows throughput dates from the cycle series rather than inferring them" do
      # Non-consecutive dates are what weekend exclusion produces; inferring a
      # date range would mislabel every bar.
      gapped = [
        %{date: ~D[2026-07-03], minutes: 10},
        %{date: ~D[2026-07-06], minutes: 20}
      ]

      xml = strings(%{overview: overview(%{cycle_series: gapped, throughput_series: [4, 7]})})

      assert xml =~ "2026-07-03"
      assert xml =~ "2026-07-06"
    end

    test "writes an empty date cell when throughput outruns the borrowed dates" do
      attrs = %{overview: overview(%{cycle_series: series([30]), throughput_series: [1, 2, 3]})}

      assert_valid_xlsx(generate(attrs))
      assert sheet_xml(attrs) =~ "<v>3</v>"
    end
  end

  describe "generate/1 — leaderboard section" do
    test "writes the translated headers and the participant row" do
      xml = strings()

      assert xml =~ "Agent"
      assert xml =~ "Completed"
      assert xml =~ "Success"
      assert xml =~ "Claude Opus 4.8"
      assert xml =~ "92%"
    end

    test "keeps the completed count as a numeric cell" do
      assert sheet_xml() =~ "<v>12</v>"
    end
  end

  describe "generate/1 — cumulative flow section" do
    test "writes a column per stage in the order the chart stacks them" do
      xml = strings()

      assert xml =~ "Backlog"
      assert xml =~ "Ready"
      assert xml =~ "Doing"
      assert xml =~ "Review"
      assert xml =~ "Done"
    end

    test "writes one row of numeric counts per snapshot" do
      xml = sheet_xml()

      assert xml =~ "<v>5</v>"
      assert xml =~ "<v>11</v>"
    end
  end

  describe "generate/1 — empty workspace" do
    test "produces headers with no data rows rather than raising" do
      empty =
        overview(%{
          cycle_series: [],
          lead_series: [],
          throughput_series: [],
          leaderboard: [],
          flow_snapshots: []
        })

      xml = strings(%{overview: empty})

      assert xml =~ "Agents · last 14 days"
      assert xml =~ "Agent"
      assert xml =~ "Cumulative flow"
      refute xml =~ "Claude Opus 4.8"
    end

    test "renders the context's own placeholder overview" do
      placeholder = Workspace.placeholder_overview(window_days: 14, timezone: "Etc/UTC")

      assert_valid_xlsx(generate(%{overview: placeholder}))
    end

    test "does not raise on an overview missing every key" do
      xml = strings(%{overview: %{}})

      assert xml =~ "Cumulative flow"
    end
  end

  describe "generate/1 — translation" do
    setup do
      on_exit(fn -> Gettext.put_locale(KanbanWeb.Gettext, "en") end)
      :ok
    end

    test "renders labels through the active locale" do
      Gettext.put_locale(KanbanWeb.Gettext, "ja")
      xml = strings()

      # One reused msgid and one msgid this module introduced — the second is
      # what proves the new strings were merged into the locale catalogs.
      refute xml =~ "Cumulative flow"
      refute xml =~ "Tasks completed"
    end

    test "falls back to the source strings under the default locale" do
      Gettext.put_locale(KanbanWeb.Gettext, "en")
      xml = strings()

      assert xml =~ "Cumulative flow"
      assert xml =~ "Tasks completed"
    end
  end

  describe "generate/1 — formula injection sanitization" do
    test "wraps an equals-prefixed participant name with an apostrophe" do
      xml = strings(hostile("=cmd|'/C calc'!A1"))

      refute xml =~ ~r/<t[^>]*>=cmd/
      assert xml =~ "'=cmd|" or xml =~ "&apos;=cmd|"
    end

    test "wraps a plus-prefixed participant name with an apostrophe" do
      xml = strings(hostile("+HYPERLINK(\"http://evil/\")"))

      refute xml =~ ~r/<t[^>]*>\+HYPERLINK/
      assert xml =~ "'+HYPERLINK" or xml =~ "&apos;+HYPERLINK"
    end

    test "wraps a minus-prefixed participant name with an apostrophe" do
      xml = strings(hostile("-malicious"))

      refute xml =~ ~r/<t[^>]*>-malicious/
      assert xml =~ "'-malicious" or xml =~ "&apos;-malicious"
    end

    test "wraps an at-prefixed participant name with an apostrophe" do
      xml = strings(hostile("@phish.example.com"))

      refute xml =~ ~r/<t[^>]*>@phish/
      assert xml =~ "'@phish" or xml =~ "&apos;@phish"
    end

    test "wraps a tab-prefixed participant name with an apostrophe" do
      xml = strings(hostile("\tSUM(A1:A10)"))

      refute xml =~ ~r/<t[^>]*>\tSUM/

      assert xml =~ "'\tSUM" or xml =~ "&apos;\tSUM" or xml =~ "&apos;&#9;SUM" or
               xml =~ "&apos;&#x9;SUM"
    end

    test "wraps a CR-prefixed participant name with an apostrophe" do
      xml = strings(hostile("\r=BAD()"))

      refute xml =~ ~r/<t[^>]*>\r=BAD/

      assert xml =~ "'\r=BAD" or xml =~ "&apos;\r=BAD" or xml =~ "&apos;&#13;=BAD" or
               xml =~ "&apos;&#xD;=BAD"
    end

    test "leaves a benign participant name unchanged" do
      xml = strings(hostile("Alice"))

      assert xml =~ "Alice"
      refute xml =~ "'Alice"
    end

    test "passes non-string values through the guard untouched" do
      # A negative number is the direct probe: `-` is a guarded prefix byte, so
      # if the guard were ever applied to non-strings this cell would gain an
      # apostrophe, become a string, and stop being chartable.
      attrs = %{
        overview:
          overview(%{
            leaderboard: [%{name: "Alice", kind: :agent, completed: -5, success_pct: 50.0}],
            cycle_series: [%{date: ~D[2026-07-01], minutes: -30}]
          })
      }

      assert sheet_xml(attrs) =~ "<v>-5</v>"
      assert sheet_xml(attrs) =~ "<v>-30</v>"
      refute strings(attrs) =~ "'-5"
      refute strings(attrs) =~ "'-30"
    end

    test "never resolves board names, so none can reach a cell" do
      # The acceptance criterion names board names alongside participant names.
      # It is inherited from the board-scoped sibling task: this export reports
      # the board selection as a COUNT and performs no board query, so a board
      # name has no path into a cell. Guard that structurally.
      code = File.read!(@module_path)

      refute code =~ "Kanban.Boards"
      refute code =~ "Repo."
      assert strings(%{board_ids: [7, 9]}) =~ "2 boards"
    end
  end
end
