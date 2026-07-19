defmodule KanbanWeb.WorkspaceMetricsPdfHTML do
  @moduledoc """
  Workspace metrics PDF export — renders the whole-workspace report as
  printable HTML for the headless renderer.

  The workspace counterpart to `KanbanWeb.MetricsPdfHTML`, which covers the
  four board-scoped metric reports. This module renders the `/metrics` page's
  bundle instead: KPIs, the cycle and lead series, throughput, the agent
  leaderboard, and the cumulative-flow snapshots.

  ## Theming policy: fixed palette, theme-independent.

  PDFs are meant to be printed, archived, and shared outside the app.
  A teammate opening a generated PDF should see the same visual result
  regardless of their browser theme, their OS appearance, or whoever
  rendered the PDF originally. To enforce that:

    * All colors in this module are inline hex codes (e.g. `#1f2937`,
      `#3b82f6`) — **never** a `var(--…)` reference to a daisyUI or Stride
      design token. The theme tokens flip with `[data-theme]`, which would
      make PDF output non-deterministic.
    * SVG chart fills, strokes, and gridlines also use hex codes for the
      same reason.

  `KanbanWeb.MetricsPdfHTMLPolicyTest` guards this policy for the board-scoped
  PDF module today; its paths are hardcoded, so it does NOT yet read this
  module. W1725 extends it to cover this module as it fills in the report
  sections — the policy is stated here so that extension is a one-liner.
  If the PDF aesthetic ever needs to evolve, change the hex codes here — do
  not migrate the PDF onto theme tokens.

  ## Scope of this module (W1724 / W1725)

  W1724 froze the `report/1` contract and shipped a minimal body so the export
  route is provably end-to-end. W1725 fills in the full page sections and the
  inline vector charts. The contract — the assigns map `report/1` accepts — is
  what the export controller depends on, so it is deliberately stable:

      %{
        overview: map(),            # Kanban.Metrics.Workspace.overview/1, verbatim
        window_days: pos_integer(), # RESOLVED (allow-listed) window
        timezone: String.t(),       # validated IANA zone
        exclude_weekends: boolean(),
        generated_at: DateTime.t()
      }

  Every value is already resolved by the controller — `report/1` renders what
  it is handed and performs no parsing, validation, or data loading of its own.
  """

  use KanbanWeb, :html

  @doc """
  Renders the workspace metrics report as printable HTML.

  See the moduledoc for the assigns contract. W1725 replaces this body with
  the full section set; the function head and its assigns must not change.
  """
  attr :overview, :map, required: true
  attr :window_days, :integer, required: true
  attr :timezone, :string, required: true
  attr :exclude_weekends, :boolean, required: true
  attr :generated_at, DateTime, required: true

  def report(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>{gettext("Metrics")}</title>
        <style>
          body { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
                 color: #1f2937; margin: 32px; }
          h1 { font-size: 24px; margin: 0 0 4px; }
          .meta { color: #6b7280; font-size: 12px; margin-bottom: 24px; }
          table { border-collapse: collapse; width: 100%; }
          th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #e5e7eb;
                   font-size: 13px; }
          th { color: #6b7280; font-weight: 600; }
        </style>
      </head>
      <body>
        <h1>{gettext("Metrics")}</h1>
        <p class="meta">
          {gettext("Last %{count} days", count: @window_days)} · {@timezone} · {Calendar.strftime(
            @generated_at,
            "%Y-%m-%d %H:%M UTC"
          )}
        </p>

        <table>
          <tbody>
            <tr :for={{label, value} <- kpi_rows(@overview)}>
              <th>{label}</th>
              <td>{value}</td>
            </tr>
          </tbody>
        </table>
      </body>
    </html>
    """
  end

  # The KPI bundle rendered as label/value pairs. Labels reuse the msgids the
  # on-screen KPI strip already ships (KanbanWeb.MetricsKpiStrip) so the export
  # reads the same as the page in every locale and introduces no new msgid.
  #
  # Reads through Map.get/3 so the zero-shape overview (the empty-workspace
  # case) renders a valid report rather than raising — an empty workspace is a
  # success, not an error.
  defp kpi_rows(overview) do
    kpis = Map.get(overview, :kpis) || %{}

    [
      {gettext("Cycle time · median"), format_minutes(kpis[:cycle_time_median_minutes])},
      {gettext("Lead time · median"), format_minutes(kpis[:lead_time_p50_minutes])},
      {gettext("Throughput"), format_number(kpis[:throughput_per_day])},
      {gettext("Wait time · Review"), format_minutes(kpis[:review_wait_minutes])}
    ]
  end

  defp format_minutes(minutes) when is_number(minutes), do: "#{round(minutes)}m"
  defp format_minutes(_), do: "—"

  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(_), do: "—"
end
