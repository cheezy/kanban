defmodule KanbanWeb.MetricsCycleTimeChart do
  @moduledoc """
  Bar chart rendering the trailing-14-day overall daily median cycle
  time as a single series.

  Consumes the list shape returned by `Kanban.Metrics.Workspace.cycle_time_daily/1`:

      [%{date: Date.t(), minutes: integer()}, ...]

  Renders a 180px-tall plot with:

    * Dashed gridlines at the tick values `KanbanWeb.MetricsYAxisScale`
      derives from the data, spanning zero to a rounded maximum that
      always covers the peak. The maximum and the labelled ticks come
      from the same scale, so a label can never disagree with a bar.
    * One column per entry — a single bar (`var(--stride-orange)`,
      rounded top) whose height is that day's median cycle time.
    * A single-letter day-of-week label under each column.
    * A title + subtitle in the header row.

  Pure function component — no Ecto, no LiveView wiring.
  """
  use KanbanWeb, :html

  alias KanbanWeb.MetricsYAxisScale

  @chart_height_px 180
  @bars_area_px 170

  @doc """
  Renders the chart.

  ## Attrs

    * `data` — required. List of `%{date: Date.t(), minutes: integer()}`
      entries. The chart adapts to any length, though
      `Kanban.Metrics.Workspace.cycle_time_daily/1` always returns exactly 14.
  """
  attr :data, :list, required: true
  attr :window_days, :integer, default: 14

  def cycle_time_chart(assigns) do
    scale = scale(assigns.data)

    assigns =
      assigns
      |> assign(:chart_max, scale.max)
      |> assign(:ticks, scale.ticks)
      |> assign(:chart_height_px, @chart_height_px)
      |> assign(:bars_area_px, @bars_area_px)

    ~H"""
    <section
      data-metrics-cycle-time-chart
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "padding: 18px;"
      ]}
    >
      <header class="flex flex-wrap items-baseline gap-3 md:gap-3.5 mb-3.5">
        <span style="font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {gettext("Cycle time · daily median (min)")}
        </span>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("last %{count} days", count: @window_days)}
        </span>
      </header>

      <div class="overflow-x-auto md:overflow-visible">
        <div
          data-metrics-cycle-time-plot
          class="min-w-[320px]"
          style={[
            "position: relative;",
            "height: #{@chart_height_px}px;",
            "display: flex; align-items: flex-end; gap: 8px;"
          ]}
        >
          <span
            :for={tick <- @ticks}
            data-metrics-cycle-time-gridline={tick}
            style={[
              "position: absolute; left: 0; right: 0;",
              "bottom: #{gridline_bottom_pct(tick, @chart_max)}%;",
              "border-top: 1px dashed var(--line-2);",
              "font-size: 10px; font-family: var(--font-mono);",
              "color: var(--ink-4); padding-left: 2px;"
            ]}
          >
            {tick}m
          </span>

          <.bar
            :for={entry <- @data}
            entry={entry}
            chart_max={@chart_max}
            bars_area_px={@bars_area_px}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true
  # The derived maximum is a number rather than strictly an integer: a
  # peak of one minute scales in sub-unit steps.
  attr :chart_max, :any, required: true
  attr :bars_area_px, :integer, required: true

  defp bar(assigns) do
    bar_h =
      segment_height_px(assigns.entry.minutes, assigns.chart_max, assigns.bars_area_px)

    assigns =
      assigns
      |> assign(:bar_h, bar_h)
      |> assign(:day_letter, day_letter(assigns.entry.date))

    ~H"""
    <div
      data-metrics-cycle-time-bar
      data-metrics-cycle-time-bar-date={Date.to_iso8601(@entry.date)}
      style={[
        "flex: 1;",
        "display: flex; flex-direction: column;",
        "justify-content: flex-end; align-items: center;",
        "gap: 4px; position: relative; z-index: 1;"
      ]}
    >
      <div style="width: 70%; min-width: 14px; display: flex; flex-direction: column;">
        <div
          data-metrics-cycle-time-segment="cycle"
          style={[
            "height: #{@bar_h}px;",
            "background: var(--stride-orange);",
            "border-radius: 3px 3px 0 0;"
          ]}
        />
      </div>
      <span style="font-size: 9.5px; color: var(--ink-3); font-family: var(--font-mono);">
        {@day_letter}
      </span>
    </div>
    """
  end

  # --- Math ---------------------------------------------------------------

  # The rounded maximum and its tick list, fitted to the data. Both the
  # bar heights and the gridline positions read the same `max`, so labels
  # and bars cannot disagree. Entries carrying no median are dropped so a
  # sparse series still scales to the days that do have one.
  defp scale(data) do
    data
    |> Enum.map(fn entry -> entry.minutes end)
    |> Enum.reject(&is_nil/1)
    |> MetricsYAxisScale.scale()
  end

  defp segment_height_px(_minutes, 0, _area), do: 0
  defp segment_height_px(nil, _max, _area), do: 0

  defp segment_height_px(minutes, chart_max, area)
       when is_number(minutes) and is_number(chart_max) and is_number(area) do
    minutes
    |> Kernel./(chart_max)
    |> Kernel.*(area)
    |> Float.round(2)
  end

  defp gridline_bottom_pct(_tick, 0), do: 0.0

  defp gridline_bottom_pct(tick, chart_max) do
    tick / chart_max * 100
  end

  # Returns the first letter of the localized weekday name. Mirrors the
  # design's single-letter axis (`'M', 'T', 'W', ...`).
  defp day_letter(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> "M"
      2 -> "T"
      3 -> "W"
      4 -> "T"
      5 -> "F"
      6 -> "S"
      7 -> "S"
    end
  end
end
