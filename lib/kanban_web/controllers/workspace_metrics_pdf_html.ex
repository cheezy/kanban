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

    * All colors in `pdf_css/0` and in the templates under
      `workspace_metrics_pdf_html/` are inline hex codes (e.g. `#1f2937`,
      `#3b82f6`) — **never** a `var(--…)` reference to a daisyUI or Stride
      design token. The theme tokens flip with `[data-theme]`, which would
      make PDF output non-deterministic.
    * SVG chart fills, strokes, and gridlines also use hex codes for the
      same reason.

  `KanbanWeb.MetricsPdfHTMLPolicyTest` guards this policy for BOTH PDF
  modules and both template directories, greping each for `var(--…)` and
  failing the build if one appears. If the PDF aesthetic ever needs to
  evolve, change the hex codes here — do not migrate the PDF onto theme
  tokens.

  Hex codes live in the `<style>` block and in SVG presentation attributes
  (`fill=`, `stroke=`), never inside a `style=` attribute — `mix dark_mode.scan`
  flags inline-style hex across `lib/kanban_web/**`, and this module is not
  exempt from that scan just because its output is a PDF.

  ## Why the charts are re-implemented here

  The on-screen components (`MetricsCycleTimeChart`, `MetricsThroughputChart`,
  `MetricsAgentLeaderboard`, `MetricsCumulativeFlow`) cannot be reused: every
  one of them styles with `var(--…)` design tokens, so calling them would
  violate the policy above and fail the guard test. Their *geometry* is
  re-derived here against a fixed palette, exactly as
  `KanbanWeb.MetricsPdfHTML` re-derives the board charts rather than calling
  the live components.

  This knowingly adds another y-scale implementation to the codebase. That is
  the accepted trade-off for a print-stable export. Two things limit the
  duplication: the tick math comes from the shared `KanbanWeb.MetricsYAxisScale`
  (which also removes the divide-by-zero class of bug structurally — its
  empty-state scale is never zero), and the cumulative-flow stacking reuses
  `KanbanWeb.MetricsCumulativeFlow.build_layers/1`, so the PDF and the page
  cannot disagree about how work stacks.

  ## Translation

  Unlike the board PDF templates, which are untranslated English, every
  visible string here goes through Gettext. A sibling task retrofits
  translation onto the board export so the two end up consistent.

  ## Contract

  `report/1` takes the assigns the export controller builds. Every value is
  already resolved — this module renders what it is handed and performs no
  parsing, validation, or data loading of its own:

      %{
        overview: map(),            # Kanban.Metrics.Workspace.overview/1, verbatim
        window_days: pos_integer(), # RESOLVED (allow-listed) window
        timezone: String.t(),       # validated IANA zone
        exclude_weekends: boolean(),
        generated_at: DateTime.t(),
        board_ids: [integer()] | nil
      }

  `board_ids` reports the applied board selection as a COUNT only. Board names
  are deliberately absent: rendering them would require a board query, and the
  controller is documented as never resolving board identifiers. `nil` means no
  subset was requested (all visible boards).
  """

  use KanbanWeb, :html

  alias KanbanWeb.Duration
  alias KanbanWeb.MetricsCumulativeFlow
  alias KanbanWeb.MetricsYAxisScale

  embed_templates "workspace_metrics_pdf_html/*"

  # Shared chart frame. The plot area is inset by @chart_inset_x to leave room
  # for the y-axis tick labels, matching the board PDF's layout.
  @chart_w 560
  @chart_h 180
  @chart_inset_x 45
  @max_x_labels 8

  @doc """
  Renders the workspace metrics report as printable HTML.

  See the moduledoc for the assigns contract. Declared bodyless: the
  implementation is the embedded `workspace_metrics_pdf_html/report.html.heex`.
  """
  attr :overview, :map, required: true
  attr :window_days, :integer, required: true
  attr :timezone, :string, required: true
  attr :exclude_weekends, :boolean, required: true
  attr :generated_at, DateTime, required: true
  attr :board_ids, :list, default: nil

  def report(assigns)

  @doc """
  A single-series line chart with the area beneath it filled.

  Used for both the cycle and lead series; `stroke` is what makes the two
  visually distinct in print, since they sit one above the other on the page.
  Colors arrive as hex through SVG presentation attributes, never through a
  `style=` attribute — see the moduledoc.
  """
  attr :series, :list, required: true
  attr :stroke, :string, required: true
  attr :marker_prefix, :string, required: true

  def line_chart(assigns) do
    assigns = assign(assigns, :geometry, line_chart_geometry(assigns.series))

    ~H"""
    <div class="chart-container">
      <svg width={svg_width()} height={svg_height()} role="img">
        <g transform={"translate(#{chart_inset_x()}, 8)"}>
          <line
            :for={tick <- @geometry.ticks}
            x1="0"
            y1={tick.y}
            x2={chart_width()}
            y2={tick.y}
            stroke="#e5e7eb"
            stroke-width="1"
          />
          <text
            :for={tick <- @geometry.ticks}
            x="-8"
            y={tick.y + 3}
            text-anchor="end"
            class="axis-label"
          >
            {tick.value}
          </text>
          <polygon
            :if={@geometry.area != ""}
            points={@geometry.area}
            fill={@stroke}
            fill-opacity="0.12"
          />
          <polyline
            :if={@geometry.polyline != ""}
            points={@geometry.polyline}
            fill="none"
            stroke={@stroke}
            stroke-width="2"
          />
          <circle
            :for={{point, index} <- Enum.with_index(@geometry.points)}
            id={"#{@marker_prefix}-point-#{index}"}
            cx={point.x}
            cy={point.y}
            r="2.5"
            fill={@stroke}
          />
        </g>
        <g transform={"translate(#{chart_inset_x()}, #{chart_height() + 22})"}>
          <text
            :for={label <- x_axis_labels(Enum.map(@series, & &1.date))}
            x={label_x(label.index, length(@series))}
            text-anchor="middle"
            class="axis-label"
          >
            {format_short_date(label.date)}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  @doc """
  The throughput chart, rendered as vertical bars.

  Bars rather than a third line: the cycle and lead charts already occupy the
  line-chart idiom directly above, and three stacked line charts read as one
  smear in print. Bars also render integer counts legibly.
  """
  attr :counts, :list, required: true
  attr :dates, :list, required: true

  def bar_chart(assigns) do
    assigns = assign(assigns, :geometry, bar_chart_geometry(assigns.counts, assigns.dates))

    ~H"""
    <div class="chart-container">
      <svg width={svg_width()} height={svg_height()} role="img">
        <g transform={"translate(#{chart_inset_x()}, 8)"}>
          <line
            :for={tick <- @geometry.ticks}
            x1="0"
            y1={tick.y}
            x2={chart_width()}
            y2={tick.y}
            stroke="#e5e7eb"
            stroke-width="1"
          />
          <text
            :for={tick <- @geometry.ticks}
            x="-8"
            y={tick.y + 3}
            text-anchor="end"
            class="axis-label"
          >
            {tick.value}
          </text>
          <rect
            :for={bar <- @geometry.bars}
            x={bar.x}
            y={bar.y}
            width={bar.width}
            height={bar.height}
            fill="#3b82f6"
          />
        </g>
        <g transform={"translate(#{chart_inset_x()}, #{chart_height() + 22})"}>
          <text
            :for={label <- x_axis_labels(@dates)}
            x={bar_label_x(label.index, length(@dates))}
            text-anchor="middle"
            class="axis-label"
          >
            {format_short_date(label.date)}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  @doc """
  The cumulative-flow diagram as stacked areas, with a translated legend.
  """
  attr :snapshots, :list, required: true

  def cumulative_flow(assigns) do
    assigns = assign(assigns, :geometry, flow_chart_geometry(assigns.snapshots))

    ~H"""
    <div class="legend">
      <div :for={layer <- @geometry.layers} class="legend-item">
        <svg width="10" height="10" class="legend-swatch" role="presentation">
          <rect width="10" height="10" rx="2" fill={layer_color(layer.name)} />
        </svg>
        <span>{layer_label(layer.name)}</span>
      </div>
    </div>
    <div class="chart-container">
      <svg width={svg_width()} height={svg_height()} role="img">
        <g transform={"translate(#{chart_inset_x()}, 8)"}>
          <polygon
            :for={layer <- @geometry.layers}
            points={layer.points}
            fill={layer_color(layer.name)}
            fill-opacity="0.85"
          />
        </g>
      </svg>
    </div>
    """
  end

  # The x position of a thinned axis label for a LINE chart, matching the point
  # projection so a label sits directly under its data point.
  @doc false
  def label_x(index, count), do: point_x(index, count, @chart_w)

  # Bars sit on a band scale rather than a point scale, so their labels centre
  # on the band. Using label_x/2 here would offset every label by half a slot
  # and push the last one past the final bar.
  @doc false
  def bar_label_x(_index, count) when count <= 0, do: @chart_w / 2
  def bar_label_x(index, count), do: (index + 0.5) * (@chart_w / count)

  @doc false
  def svg_width, do: @chart_w + @chart_inset_x + 15

  @doc false
  def svg_height, do: @chart_h + 40

  @doc false
  def chart_width, do: @chart_w

  @doc false
  def chart_height, do: @chart_h

  @doc false
  def chart_inset_x, do: @chart_inset_x

  @doc """
  Projects a `[%{date, minutes}]` series onto the chart frame.

  Returns the point list, a ready-to-render polyline string, the closed area
  polygon, and the y-axis ticks with their pixel positions.

  Degenerate inputs are handled structurally rather than by ad-hoc guards: the
  scale maximum comes from `MetricsYAxisScale.scale/1`, which never returns
  zero, so the projection cannot divide by zero for an empty or all-zero
  series. A single point is centred horizontally, since a one-point series has
  no span to distribute across.
  """
  def line_chart_geometry(series, width \\ @chart_w, height \\ @chart_h) do
    values = Enum.map(series, & &1.minutes)
    scale = MetricsYAxisScale.scale(values)
    points = project_points(series, scale.max, width, height)

    %{
      points: points,
      polyline: points_to_polyline(points),
      area: points_to_area(points, height),
      ticks: y_ticks(scale, height),
      max: scale.max
    }
  end

  defp project_points([], _max, _width, _height), do: []

  defp project_points(series, max, width, height) do
    count = length(series)

    series
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      %{x: point_x(index, count, width), y: point_y(entry.minutes, max, height)}
    end)
  end

  # A one-point series has no span, so centre it rather than dividing by zero.
  defp point_x(_index, count, width) when count <= 1, do: width / 2
  defp point_x(index, count, width), do: index / (count - 1) * width

  defp point_y(value, max, height), do: height - value / max * height

  @doc false
  def points_to_polyline(points),
    do: Enum.map_join(points, " ", fn %{x: x, y: y} -> "#{round(x)},#{round(y)}" end)

  # Closes the line back down to the baseline so the area beneath it can be
  # filled. An empty or single point has no area worth drawing.
  @doc false
  def points_to_area(points, height \\ @chart_h)
  def points_to_area(points, _height) when length(points) < 2, do: ""

  def points_to_area(points, height) do
    first = List.first(points)
    last = List.last(points)

    "#{round(first.x)},#{height} " <>
      points_to_polyline(points) <> " #{round(last.x)},#{height}"
  end

  defp y_ticks(scale, height) do
    Enum.map(scale.ticks, fn tick ->
      %{value: tick, y: height - tick / scale.max * height}
    end)
  end

  @doc """
  Projects a bare count series onto vertical bars.

  `throughput_series` carries no dates of its own, so the caller supplies them
  from the cycle series — with weekends excluded the days are non-consecutive,
  and inferring them would mislabel every bar.
  """
  def bar_chart_geometry(counts, dates, width \\ @chart_w, height \\ @chart_h) do
    scale = MetricsYAxisScale.scale(counts)
    count = length(counts)
    slot = if count > 0, do: width / count, else: width
    bar_w = max(slot * 0.6, 1.0)

    bars =
      counts
      |> Enum.with_index()
      |> Enum.map(
        &build_bar(&1, dates, %{max: scale.max, height: height, slot: slot, bar_w: bar_w})
      )

    %{bars: bars, ticks: y_ticks(scale, height), max: scale.max}
  end

  defp build_bar({value, index}, dates, frame) do
    bar_h = bar_height(value, frame.max, frame.height)

    %{
      x: index * frame.slot + (frame.slot - frame.bar_w) / 2,
      y: frame.height - bar_h,
      width: frame.bar_w,
      height: bar_h,
      value: value,
      date: Enum.at(dates, index)
    }
  end

  defp bar_height(_value, max, _height) when max <= 0, do: 0.0
  defp bar_height(value, max, height), do: value / max * height

  @doc """
  Projects the cumulative-flow snapshots into stacked SVG area paths.

  Stacking is delegated to `MetricsCumulativeFlow.build_layers/1` — the same
  function the on-screen chart uses — so the two cannot drift. Only the
  projection and the palette are re-derived here.
  """
  def flow_chart_geometry(snapshots, width \\ @chart_w, height \\ @chart_h) do
    layers = MetricsCumulativeFlow.build_layers(snapshots)
    peak = layers |> flow_peak() |> max(1)

    %{
      layers: Enum.map(layers, &flow_layer_path(&1, peak, width, height)),
      peak: peak
    }
  end

  defp flow_peak([]), do: 0

  defp flow_peak(layers) do
    layers
    |> Enum.flat_map(& &1.top)
    |> Enum.max(fn -> 0 end)
  end

  defp flow_layer_path(layer, peak, width, height) do
    count = length(layer.top)

    tops =
      layer.top
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        "#{round(point_x(i, count, width))},#{round(height - v / peak * height)}"
      end)

    bottoms =
      layer.bottom
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.map(fn {v, i} ->
        "#{round(point_x(i, count, width))},#{round(height - v / peak * height)}"
      end)

    %{name: layer.name, points: Enum.join(tops ++ bottoms, " ")}
  end

  @doc """
  Thins a date series down to at most `max_labels` evenly spaced x-axis labels.

  A 90-day window would otherwise render 90 overlapping labels. Guards the
  one-entry case, where the stride divisor would otherwise be zero.
  """
  def x_axis_labels(dates, max_labels \\ @max_x_labels)
  def x_axis_labels([], _max_labels), do: []
  def x_axis_labels([single], _max_labels), do: [%{index: 0, date: single}]

  def x_axis_labels(dates, max_labels) do
    count = length(dates)
    wanted = min(count, max_labels)
    # Ceiling division: flooring lets a 14-entry series through at stride 1 and
    # emit all 14 labels, breaking the documented bound.
    stride = max(ceil(count / wanted), 1)

    labels =
      dates
      |> Enum.with_index()
      |> Enum.take_every(stride)
      |> Enum.map(fn {date, index} -> %{index: index, date: date} end)

    append_last_label(labels, dates, count, wanted)
  end

  # take_every/2 drops the final date whenever the stride does not divide the
  # series evenly, leaving the chart's right edge unlabelled.
  defp append_last_label(labels, dates, count, max_labels) do
    last_index = count - 1

    case List.last(labels) do
      %{index: ^last_index} ->
        labels

      _ ->
        # Drop a slot before appending: appending unconditionally would push the
        # count to max_labels + 1 and break the bound this function documents.
        Enum.take(labels, max_labels - 1) ++
          [%{index: last_index, date: List.last(dates)}]
    end
  end

  @doc """
  The four KPI cards, in the order the on-screen strip renders them.

  Labels reuse the msgids `KanbanWeb.MetricsKpiStrip` already ships, and the
  minute values are formatted with `KanbanWeb.Duration.format_minutes/2` — the
  same formatter the strip uses — so the export and the page never disagree
  about what "2h 41m" means.
  """
  def kpi_cards(overview, window_days) do
    kpis = Map.get(overview, :kpis) || %{}
    vs_prev = gettext("vs prev %{count}d", count: window_days)

    [
      cycle_card(kpis, vs_prev),
      lead_card(kpis),
      throughput_card(kpis, vs_prev),
      review_card(kpis)
    ]
  end

  defp cycle_card(kpis, vs_prev) do
    %{
      label: gettext("Cycle time · median"),
      value: format_minutes(kpis[:cycle_time_median_minutes]),
      sub: vs_prev,
      delta: kpis[:cycle_time_delta_pct],
      tone: "amber"
    }
  end

  defp lead_card(kpis) do
    %{
      label: gettext("Lead time · median"),
      value: format_minutes(kpis[:lead_time_p50_minutes]),
      sub: gettext("idea → done"),
      delta: kpis[:lead_time_delta_pct],
      tone: "purple"
    }
  end

  defp throughput_card(kpis, vs_prev) do
    %{
      label: gettext("Throughput"),
      value: format_throughput(kpis[:throughput_per_day]),
      sub: vs_prev,
      delta: kpis[:throughput_delta_pct],
      tone: "blue"
    }
  end

  defp review_card(kpis) do
    %{
      label: gettext("Wait time · Review"),
      value: format_minutes(kpis[:review_wait_minutes]),
      sub: gettext("human response avg"),
      delta: kpis[:review_wait_delta_pct],
      tone: "green"
    }
  end

  @doc """
  The applied-filter rows shown beneath the title.

  The board selection is reported as a count, never as names — see the
  moduledoc.
  """
  def filter_rows(assigns) do
    [
      {gettext("Boards"), board_scope_label(assigns[:board_ids])},
      {gettext("Last %{count} days", count: assigns.window_days),
       window_range_label(assigns.window_days, assigns.generated_at, assigns.timezone)},
      {gettext("Exclude Weekends"), yes_no(assigns.exclude_weekends)},
      {gettext("Time zone"), assigns.timezone},
      {gettext("Generated"), format_datetime(assigns.generated_at)}
    ]
  end

  # Reuses the board-count msgids the page's own scope label already ships. An
  # empty list reads as "0 boards", which is exactly right: the controller
  # documents [] as "every requested board id was forged", i.e. a zero report.
  @doc false
  def board_scope_label(nil), do: gettext("All boards")
  def board_scope_label([_single]), do: gettext("1 board")
  def board_scope_label(ids) when is_list(ids), do: gettext("%{count} boards", count: length(ids))

  # Anchored on the report's OWN clock, not UTC. The row sits directly beside
  # the one naming the timezone, and the series it describes are bucketed in
  # that zone — anchoring on Date.utc_today/0 prints a range that disagrees with
  # the charts by a day for anyone far enough from UTC.
  defp window_range_label(window_days, generated_at, timezone) do
    today = local_date(generated_at, timezone)
    start = Date.add(today, -(window_days - 1))

    "#{format_short_date(start)} – #{format_short_date(today)}"
  end

  defp local_date(%DateTime{} = at, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _reason} -> DateTime.to_date(at)
    end
  end

  defp local_date(%DateTime{} = at, _timezone), do: DateTime.to_date(at)

  defp yes_no(true), do: gettext("Yes")
  defp yes_no(_), do: gettext("No")

  @doc false
  def layer_label(:backlog), do: gettext("Backlog")
  def layer_label(:ready), do: gettext("Ready")
  def layer_label(:doing), do: gettext("Doing")
  def layer_label(:review), do: gettext("Review")
  def layer_label(:done), do: gettext("Done")
  def layer_label(other), do: to_string(other)

  # Fixed palette — see the theming policy in the moduledoc.
  @doc false
  def layer_color(:backlog), do: "#6b7280"
  def layer_color(:ready), do: "#2563eb"
  def layer_color(:doing), do: "#d97706"
  def layer_color(:review), do: "#7c3aed"
  def layer_color(:done), do: "#15803d"
  def layer_color(_other), do: "#9ca3af"

  @doc false
  def format_minutes(minutes), do: Duration.format_minutes(minutes, pad_remainder: true)

  @doc false
  def format_throughput(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  def format_throughput(value) when is_integer(value), do: Integer.to_string(value)
  def format_throughput(_value), do: "—"

  @doc false
  def format_pct(value) when is_number(value), do: "#{round(value)}%"
  def format_pct(_value), do: "—"

  @doc false
  def format_delta(delta) when is_number(delta) do
    rounded = Float.round(delta / 1, 1)

    if rounded >= 0 do
      "+#{rounded}%"
    else
      "#{rounded}%"
    end
  end

  def format_delta(_delta), do: "—"

  @doc false
  def format_short_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")
  def format_short_date(_date), do: ""

  @doc false
  def format_datetime(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  def format_datetime(_at), do: ""

  @doc """
  The document's stylesheet.

  Returned as a plain string and injected with `Phoenix.HTML.raw/1` in the
  template. That injection is the ONLY sanctioned raw/1 in this module's
  output — it is a literal, code-authored string. User-controlled values (agent
  names in the leaderboard) always render through HEEx `{...}` interpolation,
  which escapes.
  """
  def pdf_css do
    """
    /* Mirrors the board PDF's page block. NOTE: ChromicPDF drives Chrome's
       Page.printToPDF, which does not implement CSS paged-media margin boxes,
       so @bottom-center does not currently reach the rendered page — switching
       to ChromicPDF's footer_template option is what would render it. Kept for
       parity with KanbanWeb.MetricsPdfHTML rather than silently diverging. */
    @page {
      size: letter;
      margin: 0.75in 0.75in 1in 0.75in;
      @bottom-center {
        content: "Generated by Stride";
        font-size: 7pt;
        color: #9ca3af;
        font-family: 'Helvetica Neue', Arial, sans-serif;
      }
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 11pt; line-height: 1.4; color: #1f2937; }
    .header { padding-bottom: 16px; margin-bottom: 16px; }
    .header h1 { font-size: 24pt; font-weight: bold; color: #1f2937; margin-bottom: 8px; }
    .meta { display: flex; flex-wrap: wrap; gap: 16px; background-color: #f3f4f6; padding: 12px; border-radius: 6px; margin-bottom: 24px; font-size: 9pt; }
    .meta-item { display: flex; gap: 6px; }
    .meta-label { font-weight: 600; color: #4b5563; }
    .meta-value { color: #1f2937; }
    .stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 8px; }
    .stat-card { background-color: #ffffff; border: 2px solid #e5e7eb; border-radius: 8px; padding: 12px; }
    .stat-card-blue { border-left: 4px solid #3b82f6; }
    .stat-card-purple { border-left: 4px solid #8b5cf6; }
    .stat-card-green { border-left: 4px solid #22c55e; }
    .stat-card-amber { border-left: 4px solid #f59e0b; }
    .stat-label { font-size: 8pt; color: #6b7280; text-transform: uppercase; letter-spacing: 0.05em; }
    .stat-value { font-size: 18pt; font-weight: bold; color: #1f2937; }
    .stat-sub { font-size: 7pt; color: #9ca3af; }
    .stat-delta { font-size: 8pt; color: #4b5563; }
    .section-title { font-size: 14pt; font-weight: bold; color: #1f2937; margin-top: 24px; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 1px solid #e5e7eb; }
    .chart-container { page-break-inside: avoid; margin-bottom: 8px; }
    .axis-label { font-size: 7pt; fill: #9ca3af; }
    .leaderboard-table { width: 100%; border-collapse: collapse; font-size: 9pt; }
    .leaderboard-table th { text-align: left; color: #6b7280; font-weight: 600; border-bottom: 1px solid #e5e7eb; padding: 6px 8px; }
    .leaderboard-table td { padding: 6px 8px; border-bottom: 1px solid #f3f4f6; color: #1f2937; }
    .legend { display: flex; gap: 16px; font-size: 8pt; color: #4b5563; margin-bottom: 8px; }
    .legend-item { display: flex; align-items: center; gap: 6px; }
    .legend-swatch { width: 10px; height: 10px; border-radius: 2px; }
    .no-data { text-align: center; padding: 24px; color: #6b7280; font-size: 10pt; }
    """
  end
end
