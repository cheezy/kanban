defmodule KanbanWeb.MetricsComponents do
  @moduledoc """
  Shared chart primitives for the metrics chart components. Extracted from
  the byte-identical private copies in `KanbanWeb.MetricsCumulativeFlow`
  and `KanbanWeb.MetricsCycleTimeChart` (W1084).
  """
  use KanbanWeb, :html

  attr :label, :string, required: true
  attr :color, :string, required: true

  @doc """
  Renders a chart legend entry — an 8px color swatch followed by its label.
  """
  def legend_swatch(assigns) do
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
end
