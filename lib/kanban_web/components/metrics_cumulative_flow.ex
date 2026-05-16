defmodule KanbanWeb.MetricsCumulativeFlow do
  @moduledoc """
  Stacked-area Cumulative Flow Diagram (CFD) over the trailing 14 days.

  Consumes the list shape returned by
  `Kanban.Metrics.cumulative_flow/1`:

      [%{date: Date.t(),
         backlog: integer(), ready: integer(),
         doing: integer(), review: integer(), done: integer()}, ...]

  Renders an 800x200 responsive SVG (preserveAspectRatio='none') with
  five stacked layers — bottom-to-top: Done, Review, Doing, Ready,
  Backlog. Each layer is a closed path tinted by its status token
  (var(--st-done) / --st-review / --st-doing / --st-ready /
  --st-backlog) at 0.8 opacity. A header carries the title, subtitle,
  and a five-swatch legend.

  Mirrors `design_handoff_stride/design_source/screens/extras.jsx`
  lines 934-973 (CFDChart). The layer-stacking math is extracted to a
  public `build_layers/1` helper for unit-testability.
  """
  use KanbanWeb, :html

  @view_w 800
  @view_h 200
  @top_padding_px 20
  # Order matters — bottom layer first, top layer last. Mirrors the
  # design source's stacking order.
  @layer_order [:done, :review, :doing, :ready, :backlog]

  @doc """
  Renders the CFD.

  ## Attrs

    * `snapshots` — required. List of daily snapshot maps. The chart
      adapts to any length, though `Kanban.Metrics.cumulative_flow/1`
      always returns 14.
  """
  attr :snapshots, :list, required: true

  def cumulative_flow(assigns) do
    {layers, peak} = build_geometry(assigns.snapshots)

    assigns =
      assigns
      |> assign(:layers, layers)
      |> assign(:peak, peak)
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
        <.legend_swatch label={gettext("Done")} color="var(--st-done)" />
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
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :color, :string, required: true

  defp legend_swatch(assigns) do
    ~H"""
    <span style="display: inline-flex; align-items: center; gap: 5px; font-size: 11px; color: var(--ink-2);">
      <span
        aria-hidden="true"
        style={"width: 8px; height: 8px; border-radius: 2px; background: #{@color};"}
      />
      {@label}
    </span>
    """
  end

  # --- Geometry ------------------------------------------------------------

  defp build_geometry(snapshots) do
    layers = build_layers(snapshots)
    peak = Enum.max([build_peak(layers), 0]) |> max(1)

    layers_with_paths =
      Enum.map(layers, fn layer ->
        Map.put(layer, :path, build_layer_path(layer, peak, length(snapshots)))
      end)

    {layers_with_paths, peak}
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
