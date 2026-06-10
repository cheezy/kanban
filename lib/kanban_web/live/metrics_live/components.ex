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
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

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
  Renders a time range filter dropdown.

  ## Examples

      <.time_range_filter
        current_range={:last_30_days}
        on_change="filter_time_range"
      />
  """
  attr :current_range, :atom, required: true, doc: "currently selected time range atom"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def time_range_filter(assigns) do
    ~H"""
    <div class={@class} style="flex: 1; min-width: 200px;">
      <label style={[
        "display: block; margin-bottom: 6px;",
        "font-size: 11px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {gettext("Time Range")}
      </label>
      <select
        phx-change={@on_change}
        name="time_range"
        style={[
          "display: block; width: 100%;",
          "padding: 6px 10px; border-radius: 6px;",
          "border: 1px solid var(--line);",
          "background: var(--surface); color: var(--ink);",
          "font-size: 12.5px;"
        ]}
        aria-label="Select time range"
      >
        <option value="last_7_days" selected={@current_range == :last_7_days}>
          {gettext("Last 7 Days")}
        </option>
        <option value="last_30_days" selected={@current_range == :last_30_days}>
          {gettext("Last 30 Days")}
        </option>
        <option value="last_90_days" selected={@current_range == :last_90_days}>
          {gettext("Last 90 Days")}
        </option>
        <option value="all_time" selected={@current_range == :all_time}>{gettext("All Time")}</option>
      </select>
    </div>
    """
  end

  @doc """
  Renders an agent filter dropdown.

  ## Examples

      <.agent_filter
        agents={["Claude Sonnet 4.5", "GPT-4"]}
        current_agent={nil}
        on_change="filter_agent"
      />
  """
  attr :agents, :list, default: [], doc: "list of available agent names"
  attr :current_agent, :string, default: nil, doc: "currently selected agent name"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def agent_filter(assigns) do
    ~H"""
    <div class={@class} style="flex: 1; min-width: 200px;">
      <label style={[
        "display: block; margin-bottom: 6px;",
        "font-size: 11px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {gettext("Agent Filter")}
      </label>
      <select
        phx-change={@on_change}
        name="agent_name"
        style={[
          "display: block; width: 100%;",
          "padding: 6px 10px; border-radius: 6px;",
          "border: 1px solid var(--line);",
          "background: var(--surface); color: var(--ink);",
          "font-size: 12.5px;"
        ]}
        aria-label="Filter by agent"
      >
        <option value="" selected={is_nil(@current_agent)}>{gettext("All Agents")}</option>
        <option
          :for={agent <- @agents}
          value={agent}
          selected={@current_agent == agent}
        >
          {agent}
        </option>
      </select>
    </div>
    """
  end

  @doc """
  Renders a weekend exclusion toggle checkbox.

  ## Examples

      <.weekend_toggle
        exclude_weekends={false}
        on_change="toggle_weekends"
      />
  """
  attr :exclude_weekends, :boolean, required: true, doc: "whether weekends are excluded"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def weekend_toggle(assigns) do
    ~H"""
    <div
      class={@class}
      style="display: inline-flex; align-items: center; gap: 8px; margin-top: 24px;"
    >
      <input
        type="checkbox"
        id="exclude_weekends"
        phx-change={@on_change}
        name="exclude_weekends"
        value={to_string(!@exclude_weekends)}
        checked={@exclude_weekends}
        style="width: 14px; height: 14px; accent-color: var(--stride-orange);"
        aria-label="Exclude weekends from calculations"
      />
      <label
        for="exclude_weekends"
        style="font-size: 12px; font-weight: 500; color: var(--ink-2);"
      >
        {gettext("Exclude Weekends")}
      </label>
    </div>
    """
  end

  # Private helper for .icon component
  attr :name, :string, required: true
  attr :class, :string, default: nil

  defp icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

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
            <label style={[
              "font-size: 9.5px; font-weight: 600;",
              "text-transform: uppercase; letter-spacing: 0.08em;",
              "color: var(--ink-3);"
            ]}>
              {gettext("Time Range")}
            </label>
            <select
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
            <label style={[
              "font-size: 9.5px; font-weight: 600;",
              "text-transform: uppercase; letter-spacing: 0.08em;",
              "color: var(--ink-3);"
            ]}>
              {gettext("Agent Filter")}
            </label>
            <select
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

  @doc """
  Renders a 4-card summary statistics display.

  Cards (Average / Median / Min / Max) share a neutral stride-screen
  surface; the value is the visual anchor via 24px tabular-numerics.
  """
  attr :stats, :map, required: true
  attr :format_fn, :any, required: true

  def summary_stats(assigns) do
    ~H"""
    <div style={[
      "margin-top: 18px;",
      "display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px;"
    ]}>
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
  Renders an SVG trend chart with optional trend line.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :daily_times, :list, required: true
  attr :format_fn, :any, required: true
  attr :empty_message, :string, default: "No data available"

  def trend_chart(assigns) do
    ~H"""
    <section
      data-metric-trend-chart
      style={[
        "margin-top: 18px; padding: 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <header style={[
        "display: flex; align-items: center; gap: 8px;",
        "margin-bottom: 14px; padding-bottom: 10px;",
        "border-bottom: 1px solid var(--line);"
      ]}>
        <span style="display: inline-flex; color: var(--stride-orange);">
          <.icon name="hero-chart-bar-solid" class="h-4 w-4" />
        </span>
        <h3 style="margin: 0; font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {@title}
        </h3>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {@subtitle}
        </span>
      </header>

      <div :if={length(@daily_times) > 0} style="position: relative;">
        <svg
          viewBox="0 0 800 400"
          style="width: 100%; height: auto;"
          xmlns="http://www.w3.org/2000/svg"
        >
          <%= for i <- 0..4 do %>
            <line
              x1="60"
              y1={50 + i * 75}
              x2="780"
              y2={50 + i * 75}
              stroke="var(--line-2)"
              stroke-width="1"
              stroke-dasharray="2,3"
            />
          <% end %>
          <%= if length(@daily_times) > 0 do %>
            <% max_hours = KanbanWeb.MetricsLive.Helpers.get_max_time(@daily_times) %>
            <% label_interval = max(1, div(length(@daily_times), 10)) %>
            <% points =
              @daily_times
              |> Enum.with_index()
              |> Enum.map(fn {day, index} ->
                x = 60 + index * (720 / max(length(@daily_times) - 1, 1))
                y = 350 - day.average_hours / max(max_hours, 0.001) * 300
                "#{x},#{y}"
              end)
              |> Enum.join(" ") %>
            <polyline
              points={points}
              fill="none"
              stroke="oklch(68% 0.17 47)"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <%= if trend = KanbanWeb.MetricsLive.Helpers.calculate_trend_line(@daily_times) do %>
              <% trend_points =
                [0, length(@daily_times) - 1]
                |> Enum.map(fn index ->
                  x = 60 + index * (720 / max(length(@daily_times) - 1, 1))
                  trend_y = trend.slope * index + trend.intercept
                  y = 350 - trend_y / max(max_hours, 0.001) * 300
                  "#{x},#{y}"
                end)
                |> Enum.join(" ") %>
              <polyline
                points={trend_points}
                fill="none"
                stroke="var(--ink-4)"
                stroke-width="1.5"
                stroke-dasharray="5,5"
                stroke-linecap="round"
                opacity="0.7"
              />
            <% end %>
            <%= for {day, index} <- Enum.with_index(@daily_times) do %>
              <% x = 60 + index * (720 / max(length(@daily_times) - 1, 1)) %>
              <% y = 350 - day.average_hours / max(max_hours, 0.001) * 300 %>
              <% last_index = length(@daily_times) - 1 %>
              <% is_last = index == last_index %>
              <% is_interval_match = rem(index, label_interval) == 0 %>
              <% distance_from_last = last_index - index %>
              <% show_label =
                is_interval_match or (is_last and distance_from_last >= div(label_interval, 2)) %>
              <circle
                cx={x}
                cy={y}
                r="3"
                fill="oklch(68% 0.17 47)"
                stroke="var(--surface)"
                stroke-width="1.5"
              />
              <%= if show_label do %>
                <text
                  x={x}
                  y="380"
                  text-anchor="middle"
                  fill="var(--ink-3)"
                  font-size="11"
                  font-family="var(--font-mono)"
                >
                  {Calendar.strftime(day.date, "%m/%d")}
                </text>
              <% end %>
            <% end %>
            <%= for i <- 0..4 do %>
              <% value = max_hours * (4 - i) / 4 %>
              <text
                x="50"
                y={55 + i * 75}
                text-anchor="end"
                fill="var(--ink-3)"
                font-size="11"
                font-family="var(--font-mono)"
              >
                {@format_fn.(value)}
              </text>
            <% end %>
          <% end %>
        </svg>
      </div>

      <div
        :if={length(@daily_times) == 0}
        style="text-align: center; padding: 32px 0;"
      >
        <span style="display: inline-flex; color: var(--ink-4);">
          <.icon name="hero-chart-bar" class="h-8 w-8" />
        </span>
        <p style="margin: 8px 0 0; font-size: 12.5px; color: var(--ink-3); font-style: italic;">
          {@empty_message}
        </p>
      </div>
    </section>
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

  @doc """
  Renders the metrics export dropdown (PDF + Excel) with shared filter query params.

  The `export_base_path` is the URL path to the export endpoint without
  query parameters (e.g., `"/boards/1/metrics/cycle-time/export"`). The
  current filter values are appended as a query string for the PDF link
  and an additional `format=excel` parameter is added for the Excel link.
  """
  attr :export_base_path, :string, required: true
  attr :time_range, :atom, required: true
  attr :agent_name, :string, default: nil
  attr :exclude_weekends, :boolean, default: false

  def export_dropdown(assigns) do
    assigns =
      assign(assigns,
        pdf_href: build_export_href(assigns, :pdf),
        excel_href: build_export_href(assigns, :excel)
      )

    ~H"""
    <div style="position: relative; margin-left: 8px;" id="export-dropdown" phx-hook="Dropdown">
      <button
        type="button"
        data-dropdown-toggle
        style={[
          "display: inline-flex; align-items: center; gap: 6px;",
          "padding: 6px 10px; border-radius: 6px;",
          "background: var(--surface); color: var(--ink-2);",
          "border: 1px solid var(--line);",
          "font: inherit; font-size: 12px; font-weight: 500;",
          "cursor: pointer;"
        ]}
      >
        <span style="display: inline-flex; color: var(--ink-3);">
          <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
        </span>
        {gettext("Export")}
        <span style="display: inline-flex; color: var(--ink-4);">
          <.icon name="hero-chevron-down" class="h-3 w-3" />
        </span>
      </button>
      <div
        data-dropdown-menu
        class="hidden"
        style={[
          "position: absolute; right: 0; top: 100%; margin-top: 4px;",
          "min-width: 140px; padding: 4px 0; z-index: 50;",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 6px;",
          "box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);"
        ]}
      >
        <a
          href={@pdf_href}
          target="_blank"
          style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 8px 12px;",
            "font-size: 12px; color: var(--ink-2);",
            "text-decoration: none;"
          ]}
        >
          <.icon name="hero-document" class="h-4 w-4" /> {gettext("PDF")}
        </a>
        <a
          href={@excel_href}
          style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 8px 12px;",
            "font-size: 12px; color: var(--ink-2);",
            "text-decoration: none;"
          ]}
        >
          <.icon name="hero-table-cells" class="h-4 w-4" /> {gettext("Excel")}
        </a>
      </div>
    </div>
    """
  end

  defp build_export_href(assigns, format) do
    params = [
      {"time_range", Atom.to_string(assigns.time_range)},
      {"agent_name", assigns.agent_name || ""},
      {"exclude_weekends", to_string(assigns.exclude_weekends)}
    ]

    params =
      case format do
        :excel -> [{"format", "excel"} | params]
        _ -> params
      end

    "#{assigns.export_base_path}?#{URI.encode_query(params)}"
  end

  @doc """
  Renders a panel containing a date-grouped list of tasks with per-task slots.

  The `:task_metadata` slot is rendered as the small metadata row beneath the
  task title; the `:task_badge` slot renders the right-aligned summary badge
  (e.g., the cycle-time pill). Both slots receive the current task as `task`.

  `date_accent` selects the color used for date group headers. Supported
  values are `:purple`, `:blue`, `:amber`, and `:indigo` — under the
  restyle every accent collapses to the same neutral var(--ink-3) tone
  since the new aesthetic uses uniform header chrome; the attribute is
  preserved for downstream-caller API compatibility.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon_name, :string, required: true
  attr :icon_gradient, :string, required: true
  attr :grouped_tasks, :list, required: true
  attr :date_accent, :atom, default: :purple
  attr :empty_icon, :string, default: "hero-clock"
  attr :empty_message, :string, required: true
  attr :show_day_count, :boolean, default: false

  slot :task_metadata, required: true do
    attr :task, :map
  end

  slot :task_badge, required: true do
    attr :task, :map
  end

  def task_list_panel(assigns) do
    ~H"""
    <section
      data-metric-task-list
      style={[
        "margin-top: 18px; padding: 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <header style={[
        "display: flex; align-items: center; gap: 8px;",
        "margin-bottom: 14px; padding-bottom: 10px;",
        "border-bottom: 1px solid var(--line);"
      ]}>
        <span style="display: inline-flex; color: var(--stride-orange);">
          <.icon name={@icon_name} class="h-4 w-4" />
        </span>
        <h3 style="margin: 0; font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {@title}
        </h3>
        <span
          :if={@subtitle}
          style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
        >
          {@subtitle}
        </span>
      </header>

      <div :if={length(@grouped_tasks) > 0} style="display: flex; flex-direction: column; gap: 16px;">
        <div
          :for={{date, day_tasks} <- @grouped_tasks}
          style="display: flex; flex-direction: column; gap: 6px;"
        >
          <div style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 6px 10px; border-radius: 6px;",
            "background: var(--surface-sunken);",
            "border-left: 2px solid var(--ink-3);"
          ]}>
            <span style="display: inline-flex; color: var(--ink-3);">
              <.icon name="hero-calendar" class="h-3 w-3" />
            </span>
            <div style="flex: 1; display: flex; align-items: center; justify-content: space-between;">
              <h4 style="margin: 0; font-size: 12.5px; font-weight: 600; color: var(--ink);">
                {KanbanWeb.MetricsLive.Helpers.format_date(date)}
              </h4>
              <span
                :if={@show_day_count}
                style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
              >
                {length(day_tasks)} {if length(day_tasks) == 1,
                  do: gettext("task"),
                  else: gettext("tasks")}
              </span>
            </div>
          </div>

          <div style="margin-left: 12px; display: flex; flex-direction: column; gap: 6px;">
            <div
              :for={task <- day_tasks}
              style={[
                "padding: 10px 12px; border-radius: 6px;",
                "background: var(--surface-sunken);",
                "border: 1px solid var(--line);"
              ]}
            >
              <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 14px;">
                <div style="flex: 1; min-width: 0;">
                  <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
                    <span style={[
                      "display: inline-flex; padding: 1px 7px; border-radius: 4px;",
                      "background: var(--st-done-soft); color: var(--st-done);",
                      "font-size: 10.5px; font-weight: 500; font-family: var(--font-mono);"
                    ]}>
                      {task.identifier}
                    </span>
                    <span style={[
                      "font-size: 12.5px; font-weight: 500; color: var(--ink);",
                      "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                    ]}>
                      {task.title}
                    </span>
                  </div>
                  <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 14px; font-size: 11px; color: var(--ink-3);">
                    {render_slot(@task_metadata, task)}
                  </div>
                </div>
                <div style="flex-shrink: 0;">
                  {render_slot(@task_badge, task)}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={length(@grouped_tasks) == 0} style="text-align: center; padding: 48px 0;">
        <span style="display: inline-flex; color: var(--ink-4);">
          <.icon name={@empty_icon} class="h-12 w-12" />
        </span>
        <p style="margin: 12px 0 0; font-size: 13px; font-weight: 500; color: var(--ink-3); font-style: italic;">
          {@empty_message}
        </p>
      </div>
    </section>
    """
  end

  # Helper function to calculate percentage for bar chart
  defp calculate_percentage(_value, 0), do: 0

  defp calculate_percentage(value, max) when value > 0 and max > 0 do
    min(Float.round(value / max * 100, 1), 100)
  end

  defp calculate_percentage(_, _), do: 0
end
