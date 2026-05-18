defmodule KanbanWeb.AcceptanceChecklist do
  @moduledoc """
  Renders newline-separated acceptance criteria as a styled checklist —
  one row per non-empty line. Mirrors the `AcceptanceList` JSX block at
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  87-107.

  Parsing is intentionally simple (`String.split("\\n", trim: true)`) —
  acceptance criteria are stored as plain text in `Kanban.Tasks.Task` and
  the design does not surface markdown formatting. The optional `checked`
  map (`%{index => true}` or `%{line => true}`) drives the check mark
  styling.
  """
  use KanbanWeb, :html

  @doc """
  Renders the acceptance-criteria checklist.

  ## Attrs

    * `acceptance_criteria` — newline-separated string. Each non-empty
      line becomes a row. `nil` and empty strings render an empty-state
      message.
    * `checked` — optional map `%{integer_index => true}` indicating
      which rows are checked. Defaults to `%{}`.
  """
  attr :acceptance_criteria, :string, default: nil
  attr :checked, :map, default: %{}
  attr :failed, :map, default: %{}

  def acceptance_checklist(assigns) do
    items = parse_items(assigns.acceptance_criteria)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:checked_count, count_checked(items, assigns.checked))
      |> assign(:total, length(items))

    ~H"""
    <section
      data-acceptance-checklist
      class="stride-screen"
      style="display: flex; flex-direction: column; gap: 6px;"
    >
      <header style="display: flex; align-items: center; gap: 8px;">
        <h3 style={[
          "margin: 0; font-size: 12.5px; font-weight: 600;",
          "letter-spacing: -0.005em; color: var(--ink);"
        ]}>
          {gettext("Acceptance criteria")}
        </h3>
        <span
          :if={@total > 0}
          class="ident"
          style="font-size: 11px; color: var(--ink-3);"
        >
          {@checked_count}/{@total}
        </span>
      </header>

      <p
        :if={@total == 0}
        style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
      >
        {gettext("No acceptance criteria recorded.")}
      </p>

      <ol
        :if={@total > 0}
        style={[
          "margin: 0; padding: 0; list-style: none;",
          "display: flex; flex-direction: column; gap: 4px;"
        ]}
      >
        <li
          :for={{line, idx} <- Enum.with_index(@items)}
          style={[
            "display: flex; align-items: flex-start; gap: 8px;",
            "padding: 4px 8px; border-radius: 4px;",
            "background: var(--surface-sunken);",
            "font-size: 12px; color: var(--ink);"
          ]}
        >
          <.check_box
            checked?={item_checked?(@checked, idx, line)}
            failed?={item_failed?(@failed, idx, line)}
          />
          <span style="flex: 1; min-width: 0; text-wrap: pretty;">{line}</span>
        </li>
      </ol>
    </section>
    """
  end

  attr :checked?, :boolean, required: true
  attr :failed?, :boolean, default: false

  defp check_box(%{failed?: true} = assigns) do
    ~H"""
    <span
      aria-label={gettext("Not met")}
      style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 14px; height: 14px; border-radius: 3px; flex-shrink: 0;",
        "margin-top: 2px;",
        "border: 1.5px solid var(--st-blocked, oklch(60% 0.18 25));",
        "background: var(--st-blocked, oklch(60% 0.18 25));",
        "color: white;"
      ]}
    >
      <.icon name="hero-x-mark" class="w-2.5 h-2.5" />
    </span>
    """
  end

  defp check_box(%{checked?: true} = assigns) do
    ~H"""
    <span
      aria-label={gettext("Checked")}
      style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 14px; height: 14px; border-radius: 3px; flex-shrink: 0;",
        "margin-top: 2px;",
        "border: 1.5px solid var(--st-done); background: var(--st-done);",
        "color: white;"
      ]}
    >
      <.icon name="hero-check" class="w-2.5 h-2.5" />
    </span>
    """
  end

  defp check_box(assigns) do
    ~H"""
    <span
      aria-label={gettext("Unchecked")}
      style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 14px; height: 14px; border-radius: 3px; flex-shrink: 0;",
        "margin-top: 2px;",
        "border: 1.5px solid var(--line-strong); background: transparent;"
      ]}
    >
    </span>
    """
  end

  # --- Helpers -----------------------------------------------------------

  defp parse_items(nil), do: []

  defp parse_items(criteria) when is_binary(criteria) do
    criteria
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_items(_), do: []

  defp count_checked(items, checked) do
    items
    |> Enum.with_index()
    |> Enum.count(fn {line, idx} -> item_checked?(checked, idx, line) end)
  end

  defp item_checked?(checked, idx, line) do
    Map.get(checked, idx) == true or Map.get(checked, line) == true
  end

  defp item_failed?(failed, idx, line) do
    Map.get(failed, idx) == true or Map.get(failed, line) == true
  end
end
