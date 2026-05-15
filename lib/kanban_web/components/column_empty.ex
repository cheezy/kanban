defmodule KanbanWeb.ColumnEmpty do
  @moduledoc """
  Empty-state hint rendered inside a kanban column when the column has
  zero tasks. Shows a dashed placeholder card with a "+" glyph above a
  short, status-specific hint paragraph.

  Mirrors the empty-column body block at lines 209-238 of
  `design_handoff_stride/design_source/screens/empty.jsx`.

  Rendered by the parent kanban template — only when the column has no
  tasks. The status-specific hint copy is gettext-wrapped so all
  supported locales can translate it.
  """
  use KanbanWeb, :html

  @doc """
  Renders the empty-column hint.

  ## Attrs

    * `status` — one of `:backlog | :ready | :doing | :review | :done`.
      Drives the hint copy. Unknown atoms fall back to a default hint.
      Default `:backlog`.
  """
  attr :status, :atom, default: :backlog

  def column_empty(assigns) do
    assigns = assign(assigns, :hint, hint_for(assigns.status))

    ~H"""
    <div
      data-column-empty
      style={[
        "flex: 1; min-height: 0;",
        "display: flex; flex-direction: column;",
        "align-items: center; justify-content: center;",
        "gap: 10px; padding: 20px 14px; text-align: center;"
      ]}
    >
      <div
        aria-hidden="true"
        style={[
          "width: 100%; height: 84px;",
          "border: 1.5px dashed var(--line-strong); border-radius: 8px;",
          "background: transparent;",
          "display: flex; align-items: center; justify-content: center;",
          "color: var(--ink-4);"
        ]}
      >
        <.icon name="hero-plus" class="w-4 h-4" />
      </div>
      <p style={[
        "margin: 0; font-size: 11.5px; line-height: 1.45;",
        "color: var(--ink-3); text-wrap: pretty; max-width: 200px;"
      ]}>
        {@hint}
      </p>
    </div>
    """
  end

  defp hint_for(:backlog),
    do:
      gettext(
        "Unrefined ideas land here. Triage to Ready when they have a why and acceptance criteria."
      )

  defp hint_for(:ready),
    do:
      gettext(
        "Agents pull from this column. A task here should be fully specified — give them what they need."
      )

  defp hint_for(:doing),
    do: gettext("In-flight work. Hooks run before and after; the activity rail lights up here.")

  defp hint_for(:review),
    do: gettext("Humans review here. Approve to Done, send back to Doing.")

  defp hint_for(:done),
    do: gettext("Shipped. Cycle time is recorded so the next estimate gets sharper.")

  defp hint_for(_), do: gettext("Drop a task here.")
end
