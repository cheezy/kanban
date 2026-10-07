defmodule KanbanWeb.MetricsLive.Components.TrendChart do
  @moduledoc """
  The SVG trend chart for the board metrics pages: daily averages drawn as a
  polyline, with an optional dashed trend line, date and value axis labels,
  and an empty state when there is no data. Pure SVG, so it renders in the
  PDF export.

  Split from `KanbanWeb.MetricsLive.Components` to keep that module under the
  module-size guidance in `AGENTS.md`. `KanbanWeb.MetricsLive.Components`
  still delegates `trend_chart/1` here, so callers keep importing it.
  """
  use Phoenix.Component

  import KanbanWeb.MetricsLive.Components.Icon

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

      <div :if={length(@daily_times) > 0} style="position: relative; overflow-x: auto;">
        <%!-- W1394: the 800x400 viewBox scales font-size:11 axis labels down to
             ~4px on a 375px phone. Pin a min-width so the chart scrolls
             horizontally (per docs/responsive-audit.md) and the labels stay
             legible, rather than squashing illegibly. The min-width is inert on
             desktop where the container is already wider. --%>
        <svg
          viewBox="0 0 800 400"
          style="width: 100%; min-width: 640px; height: auto; display: block;"
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
end
