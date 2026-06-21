defmodule KanbanWeb.MetricsThroughputChart do
  @moduledoc """
  Inline-SVG area sparkline rendering daily completed-task counts over
  the trailing 14 days.

  Consumes the list shape returned by
  `Kanban.Metrics.throughput_daily/1` — a list of non-negative integers
  ordered oldest-to-newest.

  The plot is a 140px-tall responsive SVG with a `var(--stride-orange)`
  stroke, a vertical gradient fill below the line (same orange, alpha
  25%→0%), and a point dot at each data sample. The viewBox is fixed at
  `0 0 600 140` and stretched to fill its container via
  `preserveAspectRatio="none"`.

  Mirrors `design_handoff_stride/design_source/screens/extras.jsx`
  lines 833-865. Pure function component — no LiveView wiring, no JS.
  """
  use KanbanWeb, :html

  @view_w 600
  @view_h 140
  @top_padding_px 20
  @bottom_padding_px 10
  @line_color "oklch(68% 0.17 47)"
  @gradient_id "metrics-throughput-grad"

  @doc """
  Renders the sparkline.

  ## Attrs

    * `series` — required. List of non-negative integers (any length,
      though `Kanban.Metrics.throughput_daily/1` always returns 14).
  """
  attr :series, :list, required: true
  attr :window_days, :integer, default: 14

  def throughput_chart(assigns) do
    series = assigns.series
    geometry = compute_geometry(series)
    peak = Enum.max(series, fn -> 0 end)

    assigns =
      assigns
      |> assign(:view_w, @view_w)
      |> assign(:view_h, @view_h)
      |> assign(:line_color, @line_color)
      |> assign(:gradient_id, @gradient_id)
      |> assign(:points, geometry.points)
      |> assign(:area_path, geometry.area_path)
      |> assign(:line_path, geometry.line_path)
      |> assign(:peak, peak)
      |> assign(:y_ticks, y_ticks(peak))
      |> assign(:value_labels, value_labels(series, geometry.points))

    ~H"""
    <section
      data-metrics-throughput-chart
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "padding: 18px;"
      ]}
    >
      <header class="flex flex-wrap items-baseline gap-3 mb-3.5">
        <span style="font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {gettext("Throughput · tasks completed per day")}
        </span>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("%{count} days", count: @window_days)}
        </span>
      </header>

      <div
        data-metrics-throughput-plot
        style={"position: relative; height: #{@view_h}px;"}
      >
        <svg
          width="100%"
          height="100%"
          viewBox={"0 0 #{@view_w} #{@view_h}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={gettext("Throughput sparkline")}
        >
          <defs>
            <linearGradient id={@gradient_id} x1="0" x2="0" y1="0" y2="1">
              <stop offset="0%" stop-color={@line_color} stop-opacity="0.25" />
              <stop offset="100%" stop-color={@line_color} stop-opacity="0.0" />
            </linearGradient>
          </defs>

          <path
            data-metrics-throughput-area
            d={@area_path}
            fill={"url(##{@gradient_id})"}
          />

          <path
            data-metrics-throughput-line
            d={@line_path}
            fill="none"
            stroke={@line_color}
            stroke-width="1.6"
            stroke-linejoin="round"
          />

          <circle
            :for={{x, y} <- @points}
            data-metrics-throughput-point
            cx={Float.to_string(x)}
            cy={Float.to_string(y)}
            r="2.4"
            fill={@line_color}
          />
        </svg>

        <span
          :for={tick <- @y_ticks}
          data-metrics-throughput-gridline={tick}
          style={[
            "position: absolute; left: 0; right: 0;",
            "bottom: #{gridline_bottom_pct(tick, @peak)}%;",
            "border-top: 1px dashed var(--line-2);",
            "font-size: 10px; font-family: var(--font-mono);",
            "color: var(--ink-4); text-align: right; padding-right: 2px;",
            "font-variant-numeric: tabular-nums; pointer-events: none;"
          ]}
        >
          {tick}
        </span>

        <span
          :for={label <- @value_labels}
          data-metrics-throughput-value-label
          style={[
            "position: absolute;",
            "left: #{label.left_pct}%; bottom: #{label.bottom_pct}%;",
            "transform: translate(#{label.shift_x}, -2px);",
            "font-size: 9px; font-family: var(--font-mono);",
            "color: var(--ink-3); font-variant-numeric: tabular-nums;",
            "white-space: nowrap; pointer-events: none;"
          ]}
        >
          {label.value}
        </span>
      </div>
    </section>
    """
  end

  # --- Geometry ------------------------------------------------------------

  @doc false
  # Exposed for testability. Returns the inputs the SVG `d` attributes
  # consume — the per-point `{x, y}` coordinates, the area path
  # (closed at the bottom), and the line path (open).
  def compute_geometry([]) do
    %{
      points: [],
      area_path: "M0,#{baseline_y()} L#{@view_w},#{baseline_y()} Z",
      line_path: ""
    }
  end

  def compute_geometry(series) when is_list(series) do
    points = compute_points(series)

    %{
      points: points,
      area_path: build_area_path(points),
      line_path: build_line_path(points)
    }
  end

  defp compute_points(series) do
    peak = Enum.max(series, fn -> 0 end)
    step_x = step_x_for(length(series))
    plot_h = plot_height()

    series
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      x = index * step_x
      y = @view_h - @bottom_padding_px - point_height(value, peak, plot_h)
      {Float.round(x * 1.0, 2), Float.round(y, 2)}
    end)
  end

  # --- Y-axis scale + per-day value labels ---------------------------------

  # A flat series (peak 0) shows only the zero baseline; otherwise anchor the
  # scale on the series peak so the magnitude is readable ("at least the peak").
  defp y_ticks(0), do: [0]
  defp y_ticks(peak) when is_integer(peak), do: [peak, 0]

  # Vertical position of a y-axis tick, mirroring how compute_points/1 places a
  # data value: bottom offset = bottom padding + the value's plotted height.
  defp gridline_bottom_pct(value, peak) do
    pct = (@bottom_padding_px + point_height(value, peak, plot_height())) / @view_h * 100
    Float.round(pct, 2)
  end

  # One label per day, positioned over its point. left/bottom are percentages of
  # the fixed viewBox so they track the stretched SVG; shift_x keeps the first
  # and last labels from overflowing the plot's left/right edges.
  defp value_labels(series, points) do
    total = length(series)

    series
    |> Enum.zip(points)
    |> Enum.with_index()
    |> Enum.map(fn {{value, point}, index} -> value_label(value, point, index, total) end)
  end

  defp value_label(value, {x, y}, index, total) do
    %{
      value: value,
      left_pct: Float.round(x / @view_w * 100, 2),
      bottom_pct: Float.round((@view_h - y) / @view_h * 100, 2),
      shift_x: label_shift_x(index, total)
    }
  end

  defp label_shift_x(0, _total), do: "0"
  defp label_shift_x(index, total) when index == total - 1, do: "-100%"
  defp label_shift_x(_index, _total), do: "-50%"

  defp step_x_for(1), do: 0.0
  defp step_x_for(length) when is_integer(length), do: @view_w / (length - 1)

  defp plot_height, do: @view_h - @top_padding_px - @bottom_padding_px

  defp point_height(0, _peak, _plot_h), do: 0.0
  defp point_height(_value, 0, _plot_h), do: 0.0

  defp point_height(value, peak, plot_h) when is_integer(value) and is_integer(peak) do
    value / peak * plot_h
  end

  defp baseline_y, do: @view_h - @bottom_padding_px

  defp build_area_path([]), do: "M0,#{baseline_y()} L#{@view_w},#{baseline_y()} Z"

  defp build_area_path(points) do
    {first_x, _} = hd(points)
    {last_x, _} = List.last(points)

    line = Enum.map_join(points, " ", fn {x, y} -> "L#{x},#{y}" end)
    "M#{first_x},#{baseline_y()} #{line} L#{last_x},#{baseline_y()} Z"
  end

  defp build_line_path([]), do: ""

  defp build_line_path(points) do
    "M" <> Enum.map_join(points, " L", fn {x, y} -> "#{x},#{y}" end)
  end
end
