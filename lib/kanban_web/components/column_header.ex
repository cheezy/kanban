defmodule KanbanWeb.ColumnHeader do
  @moduledoc """
  Header strip for one kanban column. Renders a status-colored dot, the
  column name, a count (or count/wip) badge with an over-WIP highlight,
  and an optional `+ task` icon button that patches to the new-task
  modal.

  Mirrors the `ColumnHeader` JSX in
  `design_handoff_stride/design_source/screens/board-kanban.jsx`
  (lines 8-33). Status color is derived from the column name —
  Backlog/Ready/Doing/Review/Done map directly to `--st-*` tokens;
  custom column names on non-AI-optimized boards fall back to
  `var(--ink-4)` so the dot still renders but stays neutral.
  """
  use KanbanWeb, :html

  @doc """
  Renders the column header.

  ## Attrs

    * `column` — a map (or `%Kanban.Columns.Column{}`) with `:name` and
      `:wip_limit`. Required.
    * `count` — the number of tasks currently in the column. Required.
    * `new_task_path` — patch target for the `+ task` icon button. When
      `nil` (read-only viewers, locked boards), the button is omitted.
  """
  attr :column, :map, required: true
  attr :count, :integer, required: true
  attr :new_task_path, :string, default: nil

  def column_header(assigns) do
    wip = wip_limit(assigns.column)
    over_wip = wip > 0 and assigns.count > wip

    assigns =
      assigns
      |> assign(:wip, wip)
      |> assign(:over_wip, over_wip)
      |> assign(:status_color, status_color_for(assigns.column.name))
      |> assign(:wip_label, wip_label(assigns.count, wip))

    ~H"""
    <div style={[
      "padding: 8px 10px 8px 8px;",
      "display: flex; align-items: center; gap: 8px;",
      "border-bottom: 1px solid var(--line);"
    ]}>
      <span
        aria-hidden="true"
        style={[
          "width: 8px; height: 8px; border-radius: 50%;",
          "background: #{@status_color}; flex-shrink: 0;",
          "box-shadow: 0 0 0 3px #{ring_color(@over_wip)};"
        ]}
      >
      </span>
      <span style="font-size: 12.5px; font-weight: 600; letter-spacing: -0.005em;">
        {@column.name}
      </span>
      <span style={[
        "font-size: 11px; font-family: var(--font-mono);",
        "color: #{badge_color(@over_wip)};",
        "background: #{badge_bg(@over_wip)};",
        "padding: 0 5px; border-radius: 3px; font-weight: 500;"
      ]}>
        {@wip_label}
      </span>
      <span style="flex: 1;"></span>
      <.link
        :if={@new_task_path}
        patch={@new_task_path}
        aria-label={gettext("Add task")}
        style={[
          "width: 22px; height: 22px; border-radius: 4px;",
          "background: transparent; border: none;",
          "color: var(--ink-3); display: inline-flex;",
          "align-items: center; justify-content: center;",
          "text-decoration: none;"
        ]}
      >
        <.icon name="hero-plus" class="w-3 h-3" />
      </.link>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp wip_limit(%{wip_limit: w}) when is_integer(w), do: w
  defp wip_limit(_), do: 0

  defp wip_label(count, 0), do: Integer.to_string(count)
  defp wip_label(count, wip), do: "#{count}/#{wip}"

  defp ring_color(true), do: "var(--st-blocked-soft)"
  defp ring_color(false), do: "transparent"

  defp badge_color(true), do: "var(--st-blocked)"
  defp badge_color(false), do: "var(--ink-3)"

  defp badge_bg(true), do: "var(--st-blocked-soft)"
  defp badge_bg(false), do: "var(--surface-sunken)"

  defp status_color_for(name) when is_binary(name) do
    case String.downcase(name) do
      "backlog" -> "var(--st-backlog)"
      "ready" -> "var(--st-ready)"
      "doing" -> "var(--st-doing)"
      "review" -> "var(--st-review)"
      "done" -> "var(--st-done)"
      _ -> "var(--ink-4)"
    end
  end

  defp status_color_for(_), do: "var(--ink-4)"
end
