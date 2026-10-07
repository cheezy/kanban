defmodule KanbanWeb.TaskLive.Components.TextBlock do
  @moduledoc """
  A labelled block of task text (Why, What, Where, Telemetry, Metrics, Logging)
  in the task detail view, in the sans or, with `mono`, the mono font. The text
  keeps its own line breaks.

  Split out of `KanbanWeb.TaskLive.ViewComponent` to keep that module under the
  module-size guidance in `AGENTS.md`, following `TaskDetailAside` (W2006).
  """
  use KanbanWeb, :html

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  def block(assigns) do
    assigns =
      assign(assigns, :font, if(assigns.mono, do: "var(--font-mono)", else: "var(--font-sans)"))

    ~H"""
    <div>
      <span class="ucase" style="font-size: 10.5px; color: var(--ink-3);">{@label}</span>
      <p style={[
        "margin: 4px 0 0; font-size: 13px; line-height: 1.55;",
        "color: var(--ink); white-space: pre-wrap;",
        "font-family: #{@font};",
        "text-wrap: pretty;"
      ]}>
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
