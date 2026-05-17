defmodule KanbanWeb.MetricsLive.Workspace do
  @moduledoc """
  Workspace-level Metrics page at `/metrics`.

  Composes the W580-W584 component chain — `MetricsKpiStrip`,
  `MetricsCycleTimeChart`, `MetricsThroughputChart`,
  `MetricsAgentLeaderboard`, and `MetricsCumulativeFlow` — against the
  workspace-scoped read functions added in W579
  (`Kanban.Metrics.workspace_kpis/1` and the four daily/per-bucket
  helpers).

  All data flows through `Kanban.Metrics`; no Ecto in this module
  per project rules. Distinct from `KanbanWeb.MetricsLive.Dashboard`
  (board-scoped) — the existing dashboard LiveView is unchanged.

  Toolbar buttons ("All boards", "Last 14 days", "Filter") are
  decorative placeholders in v1: they render as styled buttons without
  `phx-click` handlers, matching the design source. Wiring them is
  tracked as a follow-up.
  """
  use KanbanWeb, :live_view

  alias Kanban.Metrics
  alias KanbanWeb.MetricsAgentLeaderboard
  alias KanbanWeb.MetricsCumulativeFlow
  alias KanbanWeb.MetricsCycleTimeChart
  alias KanbanWeb.MetricsKpiStrip
  alias KanbanWeb.MetricsThroughputChart

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Stride · Metrics")
     |> assign(:kpis, Metrics.workspace_kpis(scope: scope))
     |> assign(:cycle_series, Metrics.cycle_time_daily(scope: scope))
     |> assign(:throughput_series, Metrics.throughput_daily(scope: scope))
     |> assign(:leaderboard, Metrics.agent_leaderboard(scope: scope))
     |> assign(:flow_snapshots, Metrics.cumulative_flow(scope: scope))
     |> assign(:window_label, window_label())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:metrics}>
      <:breadcrumbs>
        <span>{gettext("Workspace")}</span>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("Metrics")}</span>
      </:breadcrumbs>

      <div
        data-metrics-workspace
        class="stride-screen"
        style="display: flex; flex-direction: column; min-height: 0;"
      >
        <header
          data-metrics-header
          class="flex flex-wrap items-baseline gap-3 px-3 md:px-7 pt-5 pb-2"
        >
          <h1 style={[
            "margin: 0;",
            "font-size: 22px; font-weight: 600;",
            "letter-spacing: -0.02em;",
            "color: var(--ink);"
          ]}>
            {gettext("Metrics")}
          </h1>
          <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
            {@window_label}
          </span>
          <span style="flex: 1;" />
          <.toolbar_button label={gettext("All boards")} />
          <.toolbar_button label={gettext("Last 14 days")} />
          <.toolbar_button label={gettext("Filter")} />
        </header>

        <div class="flex-1 overflow-y-auto px-3 md:px-7 pt-2 pb-7 flex flex-col gap-3.5">
          <MetricsKpiStrip.kpi_strip kpis={@kpis} />

          <MetricsCycleTimeChart.cycle_time_chart data={@cycle_series} />

          <div class="flex flex-col md:grid md:grid-cols-[1.4fr_1fr] gap-3.5">
            <MetricsThroughputChart.throughput_chart series={@throughput_series} />
            <MetricsAgentLeaderboard.leaderboard rows={@leaderboard} />
          </div>

          <MetricsCumulativeFlow.cumulative_flow snapshots={@flow_snapshots} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Decorative toolbar -------------------------------------------------

  attr :label, :string, required: true

  defp toolbar_button(assigns) do
    ~H"""
    <button
      type="button"
      data-metrics-toolbar-placeholder
      aria-disabled="true"
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 4px 10px; border-radius: 5px;",
        "font: inherit; font-size: 12px; font-weight: 500;",
        "color: var(--ink-2);",
        "background: var(--surface); border: 1px solid var(--line);",
        "cursor: not-allowed; opacity: 0.75;"
      ]}
    >
      {@label}
    </button>
    """
  end

  # --- Helpers ------------------------------------------------------------

  defp window_label do
    today = Date.utc_today()
    start = Date.add(today, -13)

    "#{Calendar.strftime(start, "%b %-d")} – #{Calendar.strftime(today, "%b %-d")} · #{gettext("all boards")}"
  end
end
