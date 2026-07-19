defmodule KanbanWeb.MetricsCycleTimeChart do
  @moduledoc """
  Bar chart rendering a trailing-14-day daily series of minute values.

  Defaults to the overall daily median cycle time, and is parameterized
  (colour, title, marker prefix, series name, tick unit) so the same
  component renders the daily p50 lead-time series without a near-identical
  clone — keeping the scale, bar, gridline and trend maths in one place.

  Consumes the list shape returned by `Kanban.Metrics.Workspace.cycle_time_daily/1`
  and `Kanban.Metrics.Workspace.lead_time_daily/1`:

      [%{date: Date.t(), minutes: integer()}, ...]

  Renders a 180px-tall plot with:

    * Dashed gridlines at the tick values `KanbanWeb.MetricsYAxisScale`
      derives from the data, spanning zero to a rounded maximum that
      always covers the peak. The maximum and the labelled ticks come
      from the same scale, so a label can never disagree with a bar.
    * One column per entry — a single bar (`var(--stride-orange)` by
      default, rounded top) whose height is that day's value.
    * A single-letter day-of-week label under each column.
    * A title + subtitle in the header row.

  Pure function component — no Ecto, no LiveView wiring.
  """
  use KanbanWeb, :html

  alias KanbanWeb.MetricsLive.Helpers
  alias KanbanWeb.MetricsYAxisScale

  @chart_height_px 180
  @bars_area_px 170

  # A bar column stacks the bar, a gap, then the day letter, and is anchored
  # to the bottom of the plot — so a bar's zero is the top of the label row,
  # not the plot floor. The label is given an explicit height so that offset
  # is a known constant rather than a font metric, letting the trend overlay
  # anchor to exactly the same baseline the bars grow from.
  @bar_gap_px 4
  @day_label_px 12
  @label_row_px @day_label_px + @bar_gap_px

  @doc """
  Renders the chart.

  Every series-specific value is an attribute defaulting to the cycle-time
  configuration, so the existing call site renders identically without
  passing any of them. A second series (lead time) supplies its own colour,
  title and marker prefix and reuses all of the scale, bar, gridline and
  trend maths unchanged.

  ## Attrs

    * `data` — required. List of `%{date: Date.t(), minutes: integer()}`
      entries. The chart adapts to any length, though
      `Kanban.Metrics.Workspace.cycle_time_daily/1` always returns exactly 14.
    * `window_days` — the trailing window named in the subtitle.
    * `color` — the bar fill, as a CSS custom property reference. Keeping it
      a token (never a Tailwind class) is what lets the dark theme override
      it with no component-side branching. Unlike `marker_prefix` this needs
      no charset guard: it lands in an attribute *value*, which HEEx escapes,
      so it cannot break out of the tag — at worst a caller-set value adds
      CSS declarations to the bar it already styles.
    * `title` — the header label. Defaults to the cycle-time title.
    * `marker_prefix` — the infix in every `data-metrics-*` marker this
      component emits, so two instances on one page stay distinguishable to
      tests and tooling.
    * `series_name` — the value stamped on the per-bar segment marker.
    * `tick_unit` — the unit suffix on the y-axis tick labels.
  """
  attr :data, :list, required: true
  attr :window_days, :integer, default: 14
  attr :color, :string, default: "var(--stride-orange)"
  attr :title, :string, default: nil
  attr :marker_prefix, :string, default: "cycle-time"
  attr :series_name, :string, default: "cycle"
  attr :tick_unit, :string, default: "m"

  def cycle_time_chart(assigns) do
    scale = scale(assigns.data)

    assigns =
      assigns
      |> assign(:chart_max, scale.max)
      |> assign(:ticks, scale.ticks)
      |> assign(:trend, trend(assigns.data, scale.max))
      |> assign(:chart_height_px, @chart_height_px)
      |> assign(:bars_area_px, @bars_area_px)
      |> assign(:label_row_px, @label_row_px)
      |> assign(:title, assigns.title || default_title())

    ~H"""
    <section
      {marker(@marker_prefix, "chart")}
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "padding: 18px;"
      ]}
    >
      <header class="flex flex-wrap items-baseline gap-3 md:gap-3.5 mb-3.5">
        <span style="font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {@title}
        </span>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("last %{count} days", count: @window_days)}
        </span>
      </header>

      <div class="overflow-x-auto md:overflow-visible">
        <div
          {marker(@marker_prefix, "plot")}
          class="min-w-[320px]"
          style={[
            "position: relative;",
            "height: #{@chart_height_px}px;",
            "display: flex; align-items: flex-end; gap: 8px;"
          ]}
        >
          <span
            :for={tick <- @ticks}
            {marker(@marker_prefix, "gridline", tick)}
            style={[
              "position: absolute; left: 0; right: 0;",
              "bottom: #{gridline_bottom_pct(tick, @chart_max)}%;",
              "border-top: 1px dashed var(--line-2);",
              "font-size: 10px; font-family: var(--font-mono);",
              "color: var(--ink-4); padding-left: 2px;"
            ]}
          >
            {tick}{@tick_unit}
          </span>

          <.bar
            :for={entry <- @data}
            entry={entry}
            chart_max={@chart_max}
            bars_area_px={@bars_area_px}
            color={@color}
            marker_prefix={@marker_prefix}
            series_name={@series_name}
          />

          <%!-- The least-squares trend, drawn over the same box the bars
          occupy: anchored to their shared baseline (the top of the label
          row) and spanning the same bar area against the same derived
          maximum, so it tracks the bars at any scale. Its endpoints are
          inset to the first and last bar centres, because the regression's
          first and last points describe those bars rather than the plot
          edges. A non-scaling dashed stroke keeps it legible and distinct
          from the solid coloured bars in both themes. --%>
          <svg
            :if={@trend}
            {marker(@marker_prefix, "trend")}
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            aria-hidden="true"
            style={[
              "position: absolute; left: 0; right: 0;",
              "bottom: #{@label_row_px}px;",
              "width: 100%; height: #{@bars_area_px}px;",
              "pointer-events: none; z-index: 2; overflow: visible;"
            ]}
          >
            <line
              {marker(@marker_prefix, "trend-line")}
              x1={@trend.start_x}
              y1={100 - @trend.start_pct}
              x2={@trend.end_x}
              y2={100 - @trend.end_pct}
              stroke="var(--ink-4)"
              stroke-width="1.5"
              stroke-dasharray="4 3"
              vector-effect="non-scaling-stroke"
            />
          </svg>
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
  attr :color, :string, required: true
  attr :marker_prefix, :string, required: true
  attr :series_name, :string, required: true

  defp bar(assigns) do
    bar_h =
      segment_height_px(assigns.entry.minutes, assigns.chart_max, assigns.bars_area_px)

    assigns =
      assigns
      |> assign(:bar_h, bar_h)
      |> assign(:day_letter, day_letter(assigns.entry.date))
      |> assign(:bar_gap_px, @bar_gap_px)
      |> assign(:day_label_px, @day_label_px)

    ~H"""
    <div
      {marker(@marker_prefix, "bar")}
      {marker(@marker_prefix, "bar-date", Date.to_iso8601(@entry.date))}
      style={[
        "flex: 1;",
        "display: flex; flex-direction: column;",
        "justify-content: flex-end; align-items: center;",
        "gap: #{@bar_gap_px}px; position: relative; z-index: 1;"
      ]}
    >
      <div style="width: 70%; min-width: 14px; display: flex; flex-direction: column;">
        <div
          {marker(@marker_prefix, "segment", @series_name)}
          style={[
            "height: #{@bar_h}px;",
            "background: #{@color};",
            "border-radius: 3px 3px 0 0;"
          ]}
        />
      </div>
      <span style={[
        "font-size: 9.5px; color: var(--ink-3); font-family: var(--font-mono);",
        "height: #{@day_label_px}px; line-height: #{@day_label_px}px;"
      ]}>
        {@day_letter}
      </span>
    </div>
    """
  end

  # --- Markers and labels --------------------------------------------------

  # Builds one `data-metrics-<prefix>-<suffix>` attribute. The prefix is an
  # attribute rather than a literal so two instances of this component on the
  # same page emit distinguishable markers; a value of `true` renders the bare
  # attribute the cycle configuration has always emitted. Returned as a
  # dynamic-attribute list so the name itself can vary.
  #
  # The prefix lands in an attribute NAME, which is the one position HEEx
  # cannot escape its way out of: a prefix containing whitespace would close
  # the marker and open a second, attacker-chosen attribute. The prefix is
  # component configuration set in code and never user input, so this guard
  # should be unreachable — it is here so that stays true by construction
  # rather than by convention. Values are escaped by HEEx as normal.
  defp marker(prefix, suffix, value \\ true) do
    unless prefix =~ ~r/\A[a-z0-9-]+\z/ do
      raise ArgumentError,
            "marker_prefix must match /[a-z0-9-]+/, got: #{inspect(prefix)}. " <>
              "It is interpolated into an HTML attribute name and must never " <>
              "carry user-supplied input."
    end

    [{"data-metrics-#{prefix}-#{suffix}", value}]
  end

  # Kept as a function rather than an `attr` default because `gettext/1`
  # resolves against the request's locale at render time, not at compile time.
  defp default_title, do: gettext("Cycle time · daily median (min)")

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

  # The regression's endpoints as a percentage of the plot, or nil when the
  # series is too short to fit a line through (the shared helper already
  # returns nil for empty and single-point series). Both endpoints are
  # clamped to the plot so an extrapolation below zero or above the
  # maximum cannot escape it.
  defp trend(data, chart_max) do
    regression =
      data
      |> trend_series()
      |> Helpers.calculate_trend_line(:minutes)

    case regression do
      nil ->
        nil

      %{slope: slope, intercept: intercept} ->
        count = length(data)
        last_index = count - 1

        %{
          start_pct: plot_pct(intercept, chart_max),
          end_pct: plot_pct(intercept + slope * last_index, chart_max),
          start_x: bar_centre_x(0, count),
          end_x: bar_centre_x(last_index, count)
        }
    end
  end

  # A day with no median renders as a zero-height bar, so it contributes
  # zero to the regression too. Substituting rather than dropping keeps each
  # remaining day at its own position on the x-axis.
  defp trend_series(data) do
    Enum.map(data, fn entry -> %{minutes: entry.minutes || 0} end)
  end

  # The horizontal centre of the bar at `index`, in the overlay's 0..100
  # viewBox units. The regression's endpoints describe the first and last
  # bars, not the plot edges, so the line is inset by half a bar at each end.
  defp bar_centre_x(index, count) do
    Float.round((index + 0.5) / count * 100, 2)
  end

  defp plot_pct(_value, 0), do: 0.0

  defp plot_pct(value, chart_max) do
    (value / chart_max * 100)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(2)
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
