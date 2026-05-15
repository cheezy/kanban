defmodule KanbanWeb.MetaItem do
  @moduledoc """
  Compact label-over-value block used in the task-detail pane's right
  rail. Mirrors the `MetaItem` JSX function at
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  330-342 — a tiny UCASE label above a flex-row value whose content is
  set by the caller.

  Pass `mono: true` to render the value in `var(--font-mono)` (used for
  things like telemetry event names).
  """
  use KanbanWeb, :html

  @doc """
  Renders one meta item.

  ## Attrs

    * `label` — UCASE label rendered above the value. Required.
    * `mono` — boolean, switches the value font to the monospace stack.

  The value is supplied via the `:inner_block` slot.
  """
  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  def meta_item(assigns) do
    assigns =
      assign(assigns, :font, if(assigns.mono, do: "var(--font-mono)", else: "var(--font-sans)"))

    ~H"""
    <div
      data-meta-item
      style="display: flex; flex-direction: column; gap: 4px;"
    >
      <span class="ucase" style="font-size: 9.5px; color: var(--ink-3);">
        {@label}
      </span>
      <div style={[
        "display: flex; align-items: center; gap: 6px;",
        "font-family: #{@font};",
        "font-size: 11.5px; color: var(--ink-2);",
        "flex-wrap: wrap;"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
