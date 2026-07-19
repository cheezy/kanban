defmodule KanbanWeb.WorkspaceMetricsExcelExport do
  @moduledoc """
  Generates the workspace metrics Excel (.xlsx) export.

  The workspace counterpart to `KanbanWeb.MetricsExcelExport`, which covers the
  four board-scoped metric reports. That module is board- and metric-specific —
  every sheet builder pattern-matches a single board and one metric name, and
  reads per-task rows — so it cannot serve the workspace bundle, whose shape is
  aggregated daily series plus KPI deltas and a leaderboard.

  ## Scope of this module (W1724 / W1726)

  W1724 froze the `generate/1` contract and shipped a minimal single-sheet body
  so the export route is provably end-to-end in both formats. W1726 fills in the
  full workbook — a sheet per page section, the filter header block, translated
  labels, and formula-injection-safe cells. The contract is what the export
  controller depends on, so it is deliberately stable:

      %{
        overview: map(),            # Kanban.Metrics.Workspace.overview/1, verbatim
        window_days: pos_integer(), # RESOLVED (allow-listed) window
        timezone: String.t(),       # validated IANA zone
        exclude_weekends: boolean(),
        generated_at: DateTime.t()
      }

  Every value is already resolved by the controller — `generate/1` renders what
  it is handed and performs no parsing, validation, or data loading of its own.

  Returns `{:ok, binary}` or `{:error, reason}`; the controller logs the reason
  and shows the user a generic message, so a failure here must never carry
  user-facing copy.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Elixlsx.Sheet
  alias Elixlsx.Workbook

  @bold [bold: true]

  @doc """
  Builds the workbook and returns its binary.

  See the moduledoc for the assigns contract. W1726 replaces this body with the
  full sheet set; the function head and its assigns must not change.
  """
  @spec generate(map()) :: {:ok, binary()} | {:error, term()}
  def generate(%{} = assigns) do
    workbook = %Workbook{sheets: [build_sheet(assigns)]}

    case Elixlsx.write_to_memory(workbook, "workspace_metrics.xlsx") do
      {:ok, {_filename, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_sheet(assigns) do
    kpis = Map.get(assigns.overview, :kpis) || %{}

    rows =
      [
        [[gettext("Metrics")] ++ @bold],
        [
          [gettext("Last %{count} days", count: assigns.window_days)],
          [assigns.timezone]
        ],
        []
      ] ++ kpi_rows(kpis)

    %Sheet{name: gettext("Metrics"), rows: rows}
  end

  # Labels reuse the msgids the on-screen KPI strip already ships
  # (KanbanWeb.MetricsKpiStrip), so the export reads the same as the page in
  # every locale and introduces no new msgid.
  #
  # Values are written as numbers, not strings, so a spreadsheet can chart them
  # directly; a missing key writes an empty cell rather than raising, since the
  # zero-shape overview (empty workspace) is a success case.
  defp kpi_rows(kpis) do
    [
      {gettext("Cycle time · median"), kpis[:cycle_time_median_minutes]},
      {gettext("Lead time · median"), kpis[:lead_time_p50_minutes]},
      {gettext("Throughput"), kpis[:throughput_per_day]},
      {gettext("Wait time · Review"), kpis[:review_wait_minutes]}
    ]
    |> Enum.map(fn {label, value} -> [[label] ++ @bold, cell_value(value)] end)
  end

  defp cell_value(value) when is_number(value), do: value
  defp cell_value(_), do: ""
end
