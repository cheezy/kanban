defmodule KanbanWeb.SectionCard do
  @moduledoc """
  Card-style content section used inside the task-detail surface (and
  any other place that needs a titled, padded, bordered block). Mirrors
  the `SectionCard` JSX function at
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  527-545.

  Three tones are recognised:

    * `:default` — neutral ink, white surface.
    * `:warn` — title and body shift to `--st-blocked` so callouts like
      "Pitfalls" pop without changing background.
    * `:muted` — title and body shift to `--ink-3` for "Out of scope" /
      "deferred" content.

  Pass `mono: true` to render the body in `var(--font-mono)`.
  """
  use KanbanWeb, :html

  @doc """
  Renders a section card.

  ## Attrs

    * `title` — string label, rendered in `ucase` 10px ink-3 above the
      body. Required.
    * `tone` — `:default | :warn | :muted`. Defaults to `:default`.
    * `mono` — boolean, switches the body font to the monospace stack.
    * `count_label` — optional small ident-style annotation rendered
      after the title (e.g., `"0/6"` for an acceptance checklist count).

  Body content goes inside the `:inner_block` slot.
  """
  attr :title, :string, required: true
  attr :tone, :atom, default: :default, values: [:default, :warn, :muted]
  attr :mono, :boolean, default: false
  attr :count_label, :string, default: nil
  slot :inner_block, required: true

  def section_card(assigns) do
    tone_color = tone_color_for(assigns.tone)

    assigns =
      assigns
      |> assign(:title_color, tone_color || "var(--ink-3)")
      |> assign(:body_color, tone_color || "var(--ink)")
      |> assign(:body_font, if(assigns.mono, do: "var(--font-mono)", else: "var(--font-sans)"))

    ~H"""
    <section
      data-section-card
      style={[
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 8px; padding: 12px 14px;",
        "box-shadow: var(--shadow-sm);"
      ]}
    >
      <div
        class="ucase"
        style={[
          "font-size: 10px; margin-bottom: 6px;",
          "color: #{@title_color};",
          "display: flex; align-items: baseline; gap: 6px;"
        ]}
      >
        <span>{@title}</span>
        <span :if={@count_label} class="ident" style="font-size: 11px; color: var(--ink-3);">
          {@count_label}
        </span>
      </div>
      <div style={[
        "font-size: 12.5px; line-height: 1.5;",
        "color: #{@body_color};",
        "font-family: #{@body_font};",
        "text-wrap: pretty;"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp tone_color_for(:warn), do: "var(--st-blocked)"
  defp tone_color_for(:muted), do: "var(--ink-3)"
  defp tone_color_for(_), do: nil
end
