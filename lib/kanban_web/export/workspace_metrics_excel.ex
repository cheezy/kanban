defmodule KanbanWeb.WorkspaceMetricsExcelExport do
  @moduledoc """
  Generates the workspace metrics Excel (.xlsx) export.

  The workspace counterpart to `KanbanWeb.MetricsExcelExport`, which covers the
  four board-scoped metric reports. That module is board- and metric-specific —
  every sheet builder pattern-matches a single board and one metric name, and
  reads per-task rows — so it cannot serve the workspace bundle, whose shape is
  aggregated daily series plus KPI deltas and a leaderboard.

  ## Contract

  The assigns shape is what the export controller depends on, so it is
  deliberately stable — it was frozen before the workbook body was filled in,
  and the function head must not change:

      %{
        overview: map(),            # Kanban.Metrics.Workspace.overview/1, verbatim
        window_days: pos_integer(), # RESOLVED (allow-listed) window
        timezone: String.t(),       # validated IANA zone
        exclude_weekends: boolean(),
        generated_at: DateTime.t(),
        board_ids: [integer()] | nil
      }

  Every value is already resolved by the controller — `generate/1` renders what
  it is handed and performs no parsing, validation, or data loading of its own.

  `board_ids` reports the applied board selection as a COUNT only. Board names
  are deliberately absent — rendering them would require a board query, and the
  controller is documented as never resolving board identifiers — so the only
  user-controlled string reaching a cell is a leaderboard participant name.
  `nil` means no subset was requested (all visible boards).

  Returns `{:ok, binary}` or `{:error, reason}`; the controller logs the reason
  and shows the user a generic message, so a failure here must never carry
  user-facing copy.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Elixlsx.Sheet
  alias Elixlsx.Workbook
  alias KanbanWeb.WorkspaceMetricsPdfHTML

  # `@col_widths_base` from `KanbanWeb.MetricsExcelExport` with its 12-wide
  # identifier column dropped and the rest shifted left one slot — same width for
  # the same content class. Column 1 carries the long labels (section titles,
  # metric names, agent names) that column 2 carries on the board sheets; six
  # columns because the cumulative-flow section is the widest.
  @col_widths %{1 => 40, 2 => 22, 3 => 22, 4 => 22, 5 => 22, 6 => 20}
  @bold [bold: true]

  # The cumulative-flow columns, in the order the on-screen chart stacks them.
  @flow_stages [:backlog, :ready, :doing, :review, :done]

  @doc """
  Builds the workbook and returns its binary.

  Produces a single sheet whose sections mirror the workspace metrics page —
  the filter header block, then the KPI summary, the cycle and lead series,
  throughput, the agent leaderboard, and the cumulative-flow snapshots. See the
  moduledoc for the assigns contract.
  """
  @spec generate(map()) :: {:ok, binary()} | {:error, term()}
  def generate(%{} = assigns) do
    workbook = %Workbook{sheets: [build_sheet(assigns)]}

    case Elixlsx.write_to_memory(workbook, "workspace_metrics.xlsx") do
      {:ok, {_filename, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  # ONE sheet whose sections are concatenated with spacer rows, mirroring
  # `KanbanWeb.MetricsExcelExport` (its wait-time sheet is the precedent). A
  # sheet per section was rejected: Excel caps sheet names at 31 characters, and
  # the section msgids this module reuses already exceed that in English
  # ("Throughput · tasks completed per day" is 36), so multi-sheet would force
  # six new short names that no other surface ships — and two locales' 31-char
  # truncations can collide into a workbook Excel refuses to open.
  defp build_sheet(assigns) do
    %Sheet{name: gettext("Metrics"), rows: sheet_rows(assigns), col_widths: @col_widths}
  end

  defp sheet_rows(assigns) do
    overview = assigns.overview
    window_days = assigns.window_days

    header_rows(assigns) ++
      kpi_section(overview, window_days) ++
      series_section(gettext("Cycle time · daily median (min)"), overview, :cycle_series) ++
      series_section(gettext("Lead time · daily median (min)"), overview, :lead_series) ++
      throughput_section(overview) ++
      leaderboard_section(overview, window_days) ++
      flow_section(overview)
  end

  # The applied-filter block, built from `WorkspaceMetricsPdfHTML.filter_rows/1`
  # so the two exports state the same filters in the same words and cannot drift
  # — it also means the block introduces no msgid of its own.
  #
  # Written as label/value ROWS rather than the board export's single
  # pipe-joined cell (`MetricsExcelExport.header_rows/3`): a spreadsheet reader
  # sorts and filters by column, so discrete cells are the more useful shape in
  # this format, and it lets `filter_rows/1` be consumed verbatim.
  defp header_rows(assigns) do
    filters =
      assigns
      |> WorkspaceMetricsPdfHTML.filter_rows()
      |> Enum.map(fn {label, value} -> [[label | @bold], value] end)

    [title_row(gettext("Metrics"))] ++ filters ++ [[]]
  end

  # Values are the FORMATTED strings `kpi_cards/2` produces, so the export reads
  # exactly as the page does ("2h 41m", not 161). The chartable raw numbers live
  # in the series sections below.
  defp kpi_section(overview, window_days) do
    rows =
      overview
      |> WorkspaceMetricsPdfHTML.kpi_cards(window_days)
      |> Enum.map(fn card ->
        [card.label, card.value, WorkspaceMetricsPdfHTML.format_delta(card.delta)]
      end)

    section(
      gettext("Summary"),
      [gettext("Metric"), gettext("Value"), gettext("Change")],
      rows
    )
  end

  # Shared by the cycle and lead series, which have identical shape and differ
  # only in title and source key.
  defp series_section(title, overview, key) do
    rows =
      overview
      |> fetch_list(key)
      |> Enum.map(fn entry -> [date_cell(entry[:date]), cell_value(entry[:minutes])] end)

    section(title, [gettext("Date"), gettext("Median (min)")], rows)
  end

  # `throughput_series` carries no dates of its own, so they come from the cycle
  # series — the same borrowing the PDF's bar chart does. Indexed lookup rather
  # than `Enum.zip/2`: zip truncates to the shorter list and would silently drop
  # counts if the series lengths ever disagreed, where `Enum.at/2` yields nil and
  # writes an empty date cell.
  defp throughput_section(overview) do
    dates = overview |> fetch_list(:cycle_series) |> Enum.map(& &1[:date])

    rows =
      overview
      |> fetch_list(:throughput_series)
      |> Enum.with_index()
      |> Enum.map(fn {count, index} -> [date_cell(Enum.at(dates, index)), cell_value(count)] end)

    section(
      gettext("Throughput · tasks completed per day"),
      [gettext("Date"), gettext("Tasks completed")],
      rows
    )
  end

  # `safe_text/1` is applied here and ONLY here: the leaderboard name is the one
  # user-controlled string in the whole workspace overview. Board names never
  # reach this module — the board selection is reported as a count, never as
  # names (see `WorkspaceMetricsPdfHTML`), and this module performs no queries.
  #
  # Unlike the PDF, an empty leaderboard keeps its header row instead of
  # rendering a "no completions" message: headers with no data rows is the
  # documented empty-workspace output for this format.
  defp leaderboard_section(overview, window_days) do
    rows =
      overview
      |> fetch_list(:leaderboard)
      |> Enum.map(fn entry ->
        [
          safe_text(entry[:name]),
          cell_value(entry[:completed]),
          WorkspaceMetricsPdfHTML.format_pct(entry[:success_pct])
        ]
      end)

    section(
      gettext("Agents · last %{count} days", count: window_days),
      [gettext("Agent"), gettext("Completed"), gettext("Success")],
      rows
    )
  end

  defp flow_section(overview) do
    rows = overview |> fetch_list(:flow_snapshots) |> Enum.map(&flow_row/1)

    section(gettext("Cumulative flow"), flow_headers(), rows)
  end

  defp flow_headers do
    [gettext("Date") | Enum.map(@flow_stages, &WorkspaceMetricsPdfHTML.layer_label/1)]
  end

  defp flow_row(snapshot) do
    [date_cell(snapshot[:date]) | Enum.map(@flow_stages, &cell_value(snapshot[&1]))]
  end

  # A section is a bold title row, a bold column-header row, its data rows, and a
  # trailing spacer. `Enum.map` over an empty list yields no data rows, so an
  # empty workspace produces headers and nothing else rather than raising.
  defp section(title, headers, data_rows) do
    [title_row(title), bold_row(headers)] ++ data_rows ++ [[]]
  end

  defp title_row(text), do: [[text | @bold]]

  defp bold_row(cells), do: Enum.map(cells, fn cell -> [cell | @bold] end)

  # Missing keys yield an empty list rather than a KeyError, so a zero-shape or
  # partial overview is a success case.
  defp fetch_list(overview, key), do: Map.get(overview, key) || []

  # Prefix any string that Excel/LibreOffice would interpret as a formula with a
  # single apostrophe so it renders as literal text. Carried over verbatim from
  # `KanbanWeb.MetricsExcelExport`. Non-strings pass through untouched so the
  # numeric and date cell builders are not affected.
  defp safe_text(<<c, _::binary>> = s) when c in [?=, ?+, ?-, ?@, 0x09, 0x0D],
    do: "'" <> s

  defp safe_text(s), do: s

  # Numbers are written as numbers so a spreadsheet can chart them directly.
  defp cell_value(value) when is_number(value), do: value
  defp cell_value(_), do: ""

  # Elixlsx has no %Date{} cell type — handing it one raises at write time — so
  # dates are written as ISO 8601 text, which sorts correctly as a string and is
  # unambiguous in every locale.
  defp date_cell(%Date{} = date), do: Date.to_iso8601(date)
  defp date_cell(_), do: ""
end
