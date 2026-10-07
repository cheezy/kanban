defmodule KanbanWeb.MetricsLive.Components.Filters do
  @moduledoc """
  The filter form for the board metrics pages: `metric_filters/1`, with the
  time range, agent and weekend controls in one form.

  The standalone `time_range_filter/1`, `agent_filter/1` and
  `weekend_toggle/1` controls were removed: every metrics page has used this
  combined form since the "removed duplication" consolidation, and nothing
  called them.

  Split from `KanbanWeb.MetricsLive.Components` to keep that module under the
  module-size guidance in `AGENTS.md`. Callers import or alias this module
  directly, so HEEx checks each call's attributes at compile time.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.MetricsLive.Components.Icon

  @doc """
  Renders the metrics filter form with time range, agent, and weekend toggle.
  """
  attr :time_range, :atom, required: true
  attr :agent_name, :string, default: nil
  attr :exclude_weekends, :boolean, required: true
  attr :agents, :list, required: true
  attr :view_name, :string, required: true
  attr :show_agent_filter, :boolean, default: true

  def metric_filters(assigns) do
    ~H"""
    <section
      data-metric-filters
      style={[
        "margin-top: 18px; padding: 14px 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <header style="display: flex; align-items: center; gap: 8px; margin-bottom: 12px;">
        <span style="display: inline-flex; color: var(--ink-3);">
          <.icon name="hero-funnel-solid" class="h-4 w-4" />
        </span>
        <h3 style={[
          "margin: 0;",
          "font-size: 9.5px; font-weight: 600;",
          "text-transform: uppercase; letter-spacing: 0.08em;",
          "color: var(--ink-3);"
        ]}>
          {gettext("Filters")}
        </h3>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("Customize your %{view_name} view", view_name: @view_name)}
        </span>
      </header>
      <form id="metrics-filter-form" phx-change="filter_change">
        <div style="display: flex; flex-wrap: wrap; align-items: flex-end; gap: 14px;">
          <div style="display: flex; flex-direction: column; gap: 4px; flex: 1; min-width: 220px;">
            <label
              for="metrics-filter-time-range"
              style={[
                "font-size: 9.5px; font-weight: 600;",
                "text-transform: uppercase; letter-spacing: 0.08em;",
                "color: var(--ink-3);"
              ]}
            >
              {gettext("Time Range")}
            </label>
            <select
              id="metrics-filter-time-range"
              name="time_range"
              style={[
                "padding: 6px 10px; border-radius: 6px;",
                "border: 1px solid var(--line);",
                "background: var(--surface); color: var(--ink);",
                "font-size: 12.5px;"
              ]}
            >
              <option value="today" selected={@time_range == :today}>{gettext("Today")}</option>
              <option value="last_7_days" selected={@time_range == :last_7_days}>
                {gettext("Last 7 Days")}
              </option>
              <option value="last_30_days" selected={@time_range == :last_30_days}>
                {gettext("Last 30 Days")}
              </option>
              <option value="last_90_days" selected={@time_range == :last_90_days}>
                {gettext("Last 90 Days")}
              </option>
              <option value="all_time" selected={@time_range == :all_time}>
                {gettext("All Time")}
              </option>
            </select>
          </div>

          <div
            :if={@show_agent_filter}
            style="display: flex; flex-direction: column; gap: 4px; flex: 1; min-width: 220px;"
          >
            <label
              for="metrics-filter-agent"
              style={[
                "font-size: 9.5px; font-weight: 600;",
                "text-transform: uppercase; letter-spacing: 0.08em;",
                "color: var(--ink-3);"
              ]}
            >
              {gettext("Agent Filter")}
            </label>
            <select
              id="metrics-filter-agent"
              name="agent_name"
              style={[
                "padding: 6px 10px; border-radius: 6px;",
                "border: 1px solid var(--line);",
                "background: var(--surface); color: var(--ink);",
                "font-size: 12.5px;"
              ]}
            >
              <option value="" selected={is_nil(@agent_name)}>{gettext("All Agents")}</option>
              <option :for={agent <- @agents} value={agent} selected={@agent_name == agent}>
                {agent}
              </option>
            </select>
          </div>

          <label style={[
            "display: inline-flex; align-items: center; gap: 8px;",
            "padding: 6px 10px; border-radius: 6px;",
            "background: var(--surface-sunken);",
            "border: 1px solid var(--line);",
            "cursor: pointer;"
          ]}>
            <input
              type="checkbox"
              id="exclude_weekends"
              name="exclude_weekends"
              value="true"
              checked={@exclude_weekends}
              style="width: 14px; height: 14px; accent-color: var(--stride-orange);"
            />
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Exclude Weekends")}
            </span>
          </label>
        </div>
      </form>
    </section>
    """
  end
end
