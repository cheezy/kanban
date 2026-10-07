defmodule KanbanWeb.MetricsLive.Components do
  @moduledoc """
  Shared UI components for metrics pages.

  Provides reusable function components for displaying metrics data,
  including stat cards, bar charts, and filter controls. All components
  support light and dark mode via the stride-screen CSS variable system
  (`var(--surface)`, `var(--line)`, `var(--ink)`, `var(--ink-3)`) and are
  optimized for PDF export (no JavaScript). Originally daisyUI-styled;
  re-skinned to the stride-screen aesthetic in W588 to match the
  workspace `/metrics` page shipped in W580-W585.

  The stat card, bar chart, summary stats and empty state live here. The rest
  were split into focused modules to keep this one under the module-size
  guidance in `AGENTS.md`; callers import or alias those modules directly, so
  HEEx still checks each call's attributes at compile time:

    * `KanbanWeb.MetricsLive.Components.Filters` - the filter form and the
      standalone time range, agent and weekend controls
    * `KanbanWeb.MetricsLive.Components.TrendChart` - the SVG trend chart
    * `KanbanWeb.MetricsLive.Components.ExportDropdown` - the board and
      workspace PDF/Excel export dropdowns
    * `KanbanWeb.MetricsLive.Components.TaskListPanel` - the date-grouped
      task list panel
    * `KanbanWeb.MetricsLive.Components.Icon` - the icon helper they share
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.MetricsLive.Components.Icon

  @doc """
  Renders a stat card with title, value, and optional subtitle.

  ## Examples

      <.stat_card title="Throughput" value="42" subtitle="tasks completed" icon="hero-chart-bar" />
      <.stat_card title="Cycle Time" value="2.5h" subtitle="median: 2.1h" icon="hero-clock" />
  """
  attr :title, :string, required: true, doc: "the card title"
  attr :value, :string, required: true, doc: "the main value to display"
  attr :subtitle, :string, default: nil, doc: "optional subtitle text"
  attr :icon, :string, default: nil, doc: "heroicon name for the card icon"
  attr :link, :string, default: nil, doc: "optional link URL for 'View details'"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def stat_card(assigns) do
    ~H"""
    <div
      class={@class}
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "overflow: hidden;"
      ]}
    >
      <div style="padding: 14px 18px;">
        <div style="display: flex; align-items: center; gap: 14px;">
          <span :if={@icon} style="display: inline-flex; color: var(--ink-3);">
            <.icon name={@icon} class="h-5 w-5" />
          </span>
          <div style="flex: 1; min-width: 0;">
            <dl>
              <dt style={[
                "margin: 0;",
                "font-size: 9.5px; font-weight: 600;",
                "text-transform: uppercase; letter-spacing: 0.08em;",
                "color: var(--ink-3);",
                "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
              ]}>
                {@title}
              </dt>
              <dd style={[
                "margin: 4px 0 0;",
                "font-size: 24px; font-weight: 600;",
                "letter-spacing: -0.025em;",
                "color: var(--ink);",
                "font-variant-numeric: tabular-nums;"
              ]}>
                {@value}
              </dd>
              <dd
                :if={@subtitle}
                style={[
                  "margin: 2px 0 0;",
                  "font-size: 11.5px; color: var(--ink-3);"
                ]}
              >
                {@subtitle}
              </dd>
            </dl>
          </div>
        </div>
      </div>
      <div
        :if={@link}
        style={[
          "padding: 8px 18px;",
          "background: var(--surface-sunken);",
          "border-top: 1px solid var(--line);",
          "font-size: 12px;"
        ]}
      >
        <a href={@link} style="color: var(--ink-2); text-decoration: underline;">
          {gettext("View details")}
        </a>
      </div>
    </div>
    """
  end

  @doc """
  Renders a horizontal bar chart using pure CSS (no JavaScript).

  Each bar displays a label, value, and percentage-based width.
  Designed to work in PDF exports and print media.

  ## Examples

      <.bar_chart
        title="Throughput by Day"
        data={[
          %{label: "Monday", value: 5, max: 10},
          %{label: "Tuesday", value: 8, max: 10}
        ]}
      />
  """
  attr :title, :string, required: true, doc: "the chart title"
  attr :data, :list, required: true, doc: "list of maps with :label, :value, and :max keys"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def bar_chart(assigns) do
    ~H"""
    <div
      class={@class}
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "padding: 18px;"
      ]}
    >
      <h3 style={[
        "margin: 0 0 14px;",
        "font-size: 13.5px; font-weight: 600;",
        "color: var(--ink);"
      ]}>
        {@title}
      </h3>
      <div style="display: flex; flex-direction: column; gap: 10px;">
        <div :for={item <- @data} style="position: relative;">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink);">
              {item.label}
            </span>
            <span style="font-size: 12px; color: var(--ink-3); font-family: var(--font-mono); font-variant-numeric: tabular-nums;">
              {item.value}
            </span>
          </div>
          <div style={[
            "width: 100%; height: 6px; border-radius: 3px;",
            "background: var(--surface-sunken); overflow: hidden;"
          ]}>
            <div
              style={[
                "height: 100%; border-radius: 3px;",
                "background: var(--stride-orange);",
                "width: #{calculate_percentage(item.value, item.max)}%;"
              ]}
              role="progressbar"
              aria-valuenow={item.value}
              aria-valuemin="0"
              aria-valuemax={item.max}
              aria-label={"#{item.label}: #{item.value}"}
            >
            </div>
          </div>
        </div>
        <div
          :if={Enum.empty?(@data)}
          style={[
            "text-align: center; padding: 24px 0;",
            "font-size: 12px; color: var(--ink-3); font-style: italic;"
          ]}
        >
          {gettext("No data available")}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a 4-card summary statistics display.

  Cards (Average / Median / Min / Max) share a neutral stride-screen
  surface; the value is the visual anchor via 24px tabular-numerics.
  """
  attr :stats, :map, required: true
  attr :format_fn, :any, required: true

  def summary_stats(assigns) do
    ~H"""
    <div
      data-summary-stats
      class="grid grid-cols-2 md:grid-cols-4 gap-3"
      style="margin-top: 18px;"
    >
      <.summary_stat_cell
        marker="average"
        label={gettext("Average")}
        value={@format_fn.(@stats.average_hours * 3600)}
        icon="hero-clock-solid"
      />
      <.summary_stat_cell
        marker="median"
        label={gettext("Median")}
        value={@format_fn.(@stats.median_hours * 3600)}
        icon="hero-chart-bar-solid"
      />
      <.summary_stat_cell
        marker="min"
        label={gettext("Min")}
        value={@format_fn.(@stats.min_hours * 3600)}
        icon="hero-arrow-down-solid"
      />
      <.summary_stat_cell
        marker="max"
        label={gettext("Max")}
        value={@format_fn.(@stats.max_hours * 3600)}
        icon="hero-arrow-up-solid"
      />
    </div>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true

  defp summary_stat_cell(assigns) do
    ~H"""
    <div
      data-metric-summary-cell={@marker}
      style={[
        "padding: 14px 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <header style="display: flex; align-items: center; gap: 8px; margin-bottom: 4px;">
        <span style="display: inline-flex; color: var(--ink-3);">
          <.icon name={@icon} class="h-4 w-4" />
        </span>
        <span style={[
          "font-size: 9.5px; font-weight: 600;",
          "text-transform: uppercase; letter-spacing: 0.08em;",
          "color: var(--ink-3);"
        ]}>
          {@label}
        </span>
      </header>
      <div style={[
        "font-size: 24px; font-weight: 600;",
        "letter-spacing: -0.025em;",
        "color: var(--ink);",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  @doc """
  Renders a centered empty state with icon and message.
  """
  attr :icon_name, :string, required: true
  attr :message, :string, required: true
  attr :size, :string, default: "large"

  def empty_state(assigns) do
    icon_class =
      if assigns.size == "large",
        do: "h-12 w-12",
        else: "h-8 w-8"

    text_size_px =
      if assigns.size == "large",
        do: "14px",
        else: "12.5px"

    assigns = assign(assigns, icon_class: icon_class, text_size_px: text_size_px)

    ~H"""
    <div style="text-align: center; padding: 48px 0;">
      <span style="display: inline-flex; color: var(--ink-4);">
        <.icon name={@icon_name} class={@icon_class} />
      </span>
      <p style={"margin: 12px 0 0; font-size: #{@text_size_px}; color: var(--ink-3); font-style: italic;"}>
        {@message}
      </p>
    </div>
    """
  end

  # Helper function to calculate percentage for bar chart
  defp calculate_percentage(_value, 0), do: 0

  defp calculate_percentage(value, max) when value > 0 and max > 0 do
    min(Float.round(value / max * 100, 1), 100)
  end

  defp calculate_percentage(_, _), do: 0
end
