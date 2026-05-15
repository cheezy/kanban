defmodule KanbanWeb.PulseSparkline do
  @moduledoc """
  Inline-SVG sparkline used by the Boards index card to visualize the
  14-day completion pulse. No JS chart library; the points are computed
  in Elixir and emitted as a `<polyline>` plus per-point `<circle>`
  markers — mirroring the design's `PulseSpark` function in
  `design_handoff_stride/design_source/screens/boards-index.jsx`
  (lines 4-17).
  """
  use KanbanWeb, :html

  @doc """
  Renders a sparkline SVG.

  ## Attrs

    * `data` — list of non-negative numbers. Required. Values are scaled
      so the maximum reaches the top of the chart; zero sits at the
      bottom. An all-zeros list renders as a flat horizontal line at
      the bottom (no division by zero).
    * `color` — CSS color applied to both the polyline stroke and the
      data-point circle fill. Default `"var(--ink-3)"`.
    * `width` — SVG width in pixels. Default 88.
    * `height` — SVG height in pixels. Default 22.
  """
  attr :data, :list, required: true
  attr :color, :string, default: "var(--ink-3)"
  attr :width, :integer, default: 88
  attr :height, :integer, default: 22

  def pulse_sparkline(assigns) do
    pairs = compute_pairs(assigns.data, assigns.width, assigns.height)
    points = Enum.map_join(pairs, " ", fn {x, y} -> "#{fmt(x)},#{fmt(y)}" end)

    assigns =
      assigns
      |> assign(:pairs, pairs)
      |> assign(:points, points)

    ~H"""
    <svg width={@width} height={@height} style="display: block;">
      <polyline
        points={@points}
        fill="none"
        stroke={@color}
        stroke-width="1.25"
        stroke-linecap="round"
        stroke-linejoin="round"
        opacity="0.85"
      />
      <circle
        :for={{x, y} <- @pairs}
        cx={fmt(x)}
        cy={fmt(y)}
        r="0.8"
        fill={@color}
        opacity="0.5"
      />
    </svg>
    """
  end

  defp compute_pairs([], _width, _height), do: []

  defp compute_pairs(data, width, height) do
    max_val = max(Enum.max(data), 1)
    step = if length(data) > 1, do: width / (length(data) - 1), else: 0

    data
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      {i * step, height - v / max_val * (height - 2) - 1}
    end)
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt(n) when is_float(n) do
    rounded = Float.round(n, 2)

    truncated = trunc(rounded)

    if rounded == truncated do
      Integer.to_string(truncated)
    else
      :erlang.float_to_binary(rounded, [{:decimals, 2}, :compact])
    end
  end
end
