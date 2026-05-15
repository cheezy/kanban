defmodule KanbanWeb.SectionHead do
  @moduledoc """
  Inline section header used inside the task-detail pane body. Mirrors
  the `SectionHead` JSX function at
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  320-328 — a small bold title with an optional mono-font count chip,
  separated from the previous content by ~22 px of top margin.

  Unlike `KanbanWeb.SectionCard`, this component does **not** wrap its
  body in a bordered surface — the design's pane variant runs sections
  inline with no per-section chrome, just a typographic break.
  """
  use KanbanWeb, :html

  @doc """
  Renders the section header.

  ## Attrs

    * `title` — string label. Required.
    * `count_label` — optional small ident-style annotation rendered
      after the title (e.g., `"0/6"` or `"6 · locked while claimed"`).
  """
  attr :title, :string, required: true
  attr :count_label, :string, default: nil

  def section_head(assigns) do
    ~H"""
    <div
      data-section-head
      style={[
        "display: flex; align-items: center; gap: 8px;",
        "margin: 22px 0 8px;",
        "font-size: 12px; font-weight: 600;",
        "letter-spacing: -0.005em; color: var(--ink);"
      ]}
    >
      <span>{@title}</span>
      <span
        :if={@count_label}
        class="ident"
        style="font-family: var(--font-mono); font-size: 11px; color: var(--ink-3); font-weight: 500;"
      >
        {@count_label}
      </span>
    </div>
    """
  end
end
