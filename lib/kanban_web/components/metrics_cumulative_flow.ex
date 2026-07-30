defmodule KanbanWeb.MetricsCumulativeFlow do
  @moduledoc """
  Stacked-area Cumulative Flow Diagram (CFD) over the trailing window
  (default 14 days; driven by the caller's `:window_days` selection).

  Consumes the list shape returned by
  `Kanban.Metrics.Workspace.cumulative_flow/1`:

      [%{date: Date.t(),
         backlog: integer(), ready: integer(),
         doing: integer(), review: integer(), done: integer()}, ...]

  Renders an 800x200 responsive SVG (preserveAspectRatio='none') with
  stacked layers — bottom-to-top: Done, Review, Doing, Ready, Backlog.
  Each layer is a closed path tinted by its status token
  (var(--st-done) / --st-review / --st-doing / --st-ready /
  --st-backlog) at 0.8 opacity. A header carries the title, subtitle,
  and one legend swatch per rendered band.

  Because the done bucket folds in the whole pre-window completed
  history, its magnitude compresses the four in-flight bands into a
  sliver. Passing `show_done={false}` drops the Done band, re-bases the
  remaining four onto the zero baseline, and rescales the y-axis to the
  four-band peak so those bands use the full plot height. The default
  `show_done={true}` renders all five bands and five swatches.

  Mirrors `design_handoff_stride/design_source/screens/extras.jsx`
  lines 934-973 (CFDChart). The layer-stacking math is extracted to a
  public `build_layers/1` helper for unit-testability.
  """
  use KanbanWeb, :html

  import KanbanWeb.MetricsComponents

  @view_w 800
  @view_h 200
  @top_padding_px 20
  # Order matters — bottom layer first, top layer last. Mirrors the
  # design source's stacking order.
  @layer_order [:done, :review, :doing, :ready, :backlog]

  @doc """
  Renders the CFD.

  ## Attrs

    * `snapshots` — required. List of daily snapshot maps. The chart adapts to
      any length: `Kanban.Metrics.Workspace.cumulative_flow/1` returns one
      snapshot per day in the window, which is fewer than the window's calendar
      length when weekends are excluded.
    * `show_done` — optional, defaults to `true`. When `false`, the Done band is
      omitted, the four remaining bands are re-based onto the zero baseline, and
      the y-axis is rescaled to the four-band peak. The Done legend swatch is
      omitted to match. The `true` default keeps every existing caller rendering
      exactly as before.
  """
  attr :snapshots, :list, required: true
  attr :show_done, :boolean, default: true

  def cumulative_flow(assigns) do
    {layers, peak} = build_geometry(assigns.snapshots, assigns.show_done)

    assigns =
      assigns
      |> assign(:layers, layers)
      |> assign(:peak, peak)
      |> assign(:y_ticks, y_ticks(peak))
      |> assign(:view_w, @view_w)
      |> assign(:view_h, @view_h)

    ~H"""
    <section
      data-metrics-cumulative-flow
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "padding: 18px;"
      ]}
    >
      <header style="display: flex; align-items: baseline; gap: 14px; margin-bottom: 14px; flex-wrap: wrap;">
        <span style="font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {gettext("Cumulative flow")}
        </span>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("work in each column over time")}
        </span>
        <span style="flex: 1;" />
        <.legend_swatch label={gettext("Backlog")} color="var(--st-backlog)" />
        <.legend_swatch label={gettext("Ready")} color="var(--st-ready)" />
        <.legend_swatch label={gettext("Doing")} color="var(--st-doing)" />
        <.legend_swatch label={gettext("Review")} color="var(--st-review)" />
        <.legend_swatch :if={@show_done} label={gettext("Done")} color="var(--st-done)" />
      </header>

      <div
        data-metrics-cumulative-flow-plot
        style={"position: relative; height: #{@view_h}px;"}
      >
        <svg
          width="100%"
          height="100%"
          viewBox={"0 0 #{@view_w} #{@view_h}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={gettext("Cumulative flow diagram")}
        >
          <path
            :for={layer <- @layers}
            data-metrics-cumulative-flow-layer={Atom.to_string(layer.name)}
            d={layer.path}
            fill={layer_color(layer.name)}
            fill-opacity="0.8"
          />
        </svg>

        <span
          :for={tick <- @y_ticks}
          data-metrics-cumulative-flow-gridline={tick}
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
      </div>
    </section>
    """
  end

  # --- Geometry ------------------------------------------------------------

  defp build_geometry(snapshots, show_done) do
    layers = snapshots |> build_layers() |> visible_layers(show_done)
    peak = Enum.max([build_peak(layers), 0]) |> max(1)

    layers_with_paths =
      Enum.map(layers, fn layer ->
        Map.put(layer, :path, build_layer_path(layer, peak, length(snapshots)))
      end)

    {layers_with_paths, peak}
  end

  defp visible_layers(layers, true), do: layers
  defp visible_layers(layers, false), do: exclude_done_layer(layers)

  @doc """
  Drops the `:done` band and re-bases the remaining four onto the zero
  baseline. Exposed for unit testing.

  `:done` is the bottom-most layer, so its `:bottom` is all zeros and its
  `:top` IS the per-day done count. Subtracting that vector from every
  survivor's `:top` and `:bottom` slides the whole stack down, so `:review`
  starts at zero while every band's thickness is preserved.

  Returns the survivors bottom-to-top (`:review` first, `:backlog` last).

  Expects a list produced by `build_layers/1`, which always leads with `:done`.
  Anything else fails closed with a `FunctionClauseError` rather than silently
  returning an unfiltered stack.
  """
  @spec exclude_done_layer([%{name: atom(), top: [integer()], bottom: [integer()]}]) ::
          [%{name: atom(), top: [integer()], bottom: [integer()]}]
  def exclude_done_layer([]), do: []

  def exclude_done_layer([%{name: :done, top: baseline} | rest]),
    do: Enum.map(rest, &rebase_layer(&1, baseline))

  defp rebase_layer(layer, baseline) do
    %{layer | top: subtract(layer.top, baseline), bottom: subtract(layer.bottom, baseline)}
  end

  defp subtract(values, baseline) do
    values |> Enum.zip(baseline) |> Enum.map(fn {value, base} -> value - base end)
  end

  # --- Y-axis scale --------------------------------------------------------

  # Tick values for the y-axis: the peak stacked total plus two intermediate
  # thirds and the zero baseline. Derived from the SAME peak build_geometry/1
  # uses to project the layers, so the ticks match the rendered heights. peak is
  # guaranteed >= 1 by build_geometry/1, so duplicates only collapse for small
  # peaks (e.g. peak 1 -> [1, 0]).
  defp y_ticks(peak) do
    [peak, round(peak * 2 / 3), round(peak / 3), 0]
    |> Enum.uniq()
  end

  # Vertical position of a tick as a percentage of the plot, mirroring
  # project_point/4's y = @view_h - value / peak * plot_h. The plot occupies
  # (@view_h - @top_padding_px) of the container, anchored at the bottom.
  defp gridline_bottom_pct(value, peak) do
    Float.round(value / peak * (@view_h - @top_padding_px) / @view_h * 100, 2)
  end

  @doc """
  Computes the per-layer `top` and `bottom` stacks from a sequence of
  daily snapshots — the same algorithm as `CFDChart` in
  `extras.jsx:949-956`. Exposed for unit testing.

  Returns a list of `%{name: atom, top: [int], bottom: [int]}` ordered
  bottom-to-top per the established stack ordering (Done first,
  Backlog last).
  """
  @spec build_layers([map()]) :: [%{name: atom(), top: [integer()], bottom: [integer()]}]
  def build_layers([]), do: []

  def build_layers(snapshots) do
    initial_stack = List.duplicate(0, length(snapshots))

    @layer_order
    |> Enum.reduce({[], initial_stack}, &add_layer(&1, &2, snapshots))
    |> elem(0)
    |> Enum.reverse()
  end

  defp add_layer(name, {acc, stack}, snapshots) do
    values = Enum.map(snapshots, &Map.get(&1, name, 0))
    top = stack |> Enum.zip(values) |> Enum.map(fn {s, v} -> s + v end)

    {[%{name: name, top: top, bottom: stack} | acc], top}
  end

  defp build_peak([]), do: 0

  defp build_peak(layers) do
    layers
    |> List.last()
    |> Map.get(:top)
    |> Enum.max(fn -> 0 end)
  end

  defp build_layer_path(%{top: top, bottom: bottom}, peak, days) when days > 0 do
    step_x = @view_w / max(days - 1, 1)
    plot_h = @view_h - @top_padding_px
    top_points = project_points(top, step_x, peak, plot_h, :forward)
    bottom_points = project_points(bottom, step_x, peak, plot_h, :reverse)

    "M" <> Enum.join(top_points ++ bottom_points, " L") <> " Z"
  end

  defp build_layer_path(_, _, _), do: ""

  defp project_points(values, step_x, peak, plot_h, order) do
    indexed = Enum.with_index(values)
    indexed = if order == :reverse, do: Enum.reverse(indexed), else: indexed
    Enum.map(indexed, &project_point(&1, step_x, peak, plot_h))
  end

  defp project_point({value, index}, step_x, peak, plot_h) do
    x = index * step_x
    y = @view_h - value / peak * plot_h
    "#{Float.round(x * 1.0, 2)},#{Float.round(y, 2)}"
  end

  defp layer_color(:backlog), do: "var(--st-backlog)"
  defp layer_color(:ready), do: "var(--st-ready)"
  defp layer_color(:doing), do: "var(--st-doing)"
  defp layer_color(:review), do: "var(--st-review)"
  defp layer_color(:done), do: "var(--st-done)"
  defp layer_color(_), do: "var(--ink-3)"
end
