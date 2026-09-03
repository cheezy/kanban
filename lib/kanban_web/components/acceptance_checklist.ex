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

  # D304 / stride W2127. A reviewer may legitimately approve a task while one
  # acceptance criterion is still `not_met`, when the only thing outstanding is
  # a commit the workflow schedules for AFTER the review. The reviewer marks
  # that row by opening its `evidence` with this sentinel.
  #
  # Match byte-for-byte and only in the LEADING position: the stride contract
  # reserves the opening of the string and nothing else, so evidence may
  # legitimately contain this phrase later on. A `String.contains?/2` here would
  # let a genuine failure disguise itself as scheduled work.
  #
  # The dash is an EM DASH (U+2014), not an ASCII hyphen.
  @pending_commit_sentinel "PENDING COMMIT — "

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

  attr :structured, :list,
    default: [],
    doc: ~s"""
    Optional list of `%{"criterion", "status", "evidence"}` maps from
    `reviewer_result.acceptance_criteria`. When non-empty, drives rendering
    directly (icon + text + inline evidence under failed rows) and ignores
    the `acceptance_criteria` / `checked` / `failed` attrs.
    """

  def acceptance_checklist(assigns) do
    structured = normalize_structured(assigns[:structured] || [])

    if structured == [] do
      render_unstructured(assigns)
    else
      render_structured(assigns, structured)
    end
  end

  defp render_unstructured(assigns) do
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
          "margin: 0; font-size: 11px; font-weight: 600;",
          "letter-spacing: 0.04em; text-transform: uppercase;",
          "color: var(--ink-3);"
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

  defp render_structured(assigns, structured) do
    met_count = Enum.count(structured, &(&1.status == "met"))
    structured = Enum.map(structured, &annotate_pending_commit/1)
    pending_count = Enum.count(structured, & &1.pending_commit?)

    assigns =
      assigns
      |> assign(:structured, structured)
      |> assign(:total, length(structured))
      |> assign(:checked_count, met_count)
      |> assign(:pending_count, pending_count)

    ~H"""
    <section
      data-acceptance-checklist
      data-acceptance-checklist-mode="structured"
      class="stride-screen"
      style="display: flex; flex-direction: column; gap: 6px;"
    >
      <header style="display: flex; align-items: center; gap: 8px;">
        <h3 style={[
          "margin: 0; font-size: 11px; font-weight: 600;",
          "letter-spacing: 0.04em; text-transform: uppercase;",
          "color: var(--ink-3);"
        ]}>
          {gettext("Acceptance criteria")}
        </h3>
        <span class="ident" style="font-size: 11px; color: var(--ink-3);">
          {@checked_count}/{@total}
        </span>
        <span
          :if={@pending_count > 0}
          data-acceptance-checklist-pending-tally
          class="ident"
          style="font-size: 11px; color: var(--st-doing);"
        >
          {gettext("(%{count} pending)", count: @pending_count)}
        </span>
      </header>

      <ol style={[
        "margin: 0; padding: 0; list-style: none;",
        "display: flex; flex-direction: column; gap: 4px;"
      ]}>
        <li
          :for={item <- @structured}
          data-acceptance-checklist-row
          data-acceptance-checklist-status={item.status}
          data-acceptance-checklist-pending={item.pending_commit? && "true"}
          style={[
            "display: flex; flex-direction: column; gap: 4px;",
            "padding: 6px 8px; border-radius: 4px;",
            "background: var(--surface-sunken);",
            "font-size: 12px; color: var(--ink);"
          ]}
        >
          <div style="display: flex; align-items: flex-start; gap: 8px;">
            <.check_box
              checked?={item.status == "met"}
              failed?={item.status == "not_met" and not item.pending_commit?}
              pending?={item.pending_commit?}
            />
            <span style="flex: 1; min-width: 0; text-wrap: pretty;">{item.criterion}</span>
            <span
              :if={item.pending_commit?}
              data-acceptance-checklist-pending-label
              style={[
                "flex-shrink: 0; padding: 0 6px; border-radius: 999px;",
                "font-size: 10px; font-weight: 600; line-height: 16px;",
                "letter-spacing: 0.04em; text-transform: uppercase;",
                "background: var(--st-doing-soft); color: var(--st-doing);",
                "border: 1px solid var(--line);"
              ]}
            >
              {gettext("Pending")}
            </span>
          </div>
          <p
            :if={
              item.status == "not_met" and not item.pending_commit? and
                item.evidence not in [nil, ""]
            }
            data-acceptance-checklist-evidence
            style={[
              "margin: 0 0 0 22px;",
              "font-size: 11.5px; line-height: 1.45;",
              "color: var(--st-blocked, oklch(50% 0.18 25));",
              "text-wrap: pretty;"
            ]}
          >
            {item.evidence}
          </p>
          <p
            :if={
              (item.status == "met" or item.pending_commit?) and
                item.evidence not in [nil, ""]
            }
            data-acceptance-checklist-evidence
            style={[
              "margin: 0 0 0 22px;",
              "font-size: 11.5px; line-height: 1.45;",
              "color: var(--ink-3); text-wrap: pretty;"
            ]}
          >
            {item.evidence}
          </p>
        </li>
      </ol>
    </section>
    """
  end

  defp normalize_structured(items) when is_list(items) do
    Enum.flat_map(items, &normalize_structured_item/1)
  end

  defp normalize_structured(_), do: []

  defp normalize_structured_item(%{} = item) do
    criterion = fetch_either(item, "criterion", :criterion)

    if is_binary(criterion) and criterion != "" do
      [
        %{
          criterion: criterion,
          status: fetch_either(item, "status", :status) || "unknown",
          evidence: fetch_either(item, "evidence", :evidence)
        }
      ]
    else
      []
    end
  end

  defp normalize_structured_item(_), do: []

  defp fetch_either(map, string_key, atom_key),
    do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp annotate_pending_commit(item),
    do: Map.put(item, :pending_commit?, pending_commit?(item))

  # `is_binary/1` rather than a `not in [nil, ""]` guard: evidence is reachable
  # as nil (fetch_either returns nil when neither key is present), and
  # String.starts_with?/2 would raise on it.
  defp pending_commit?(%{status: "not_met", evidence: evidence}) when is_binary(evidence),
    do: String.starts_with?(evidence, @pending_commit_sentinel)

  defp pending_commit?(_), do: false

  attr :checked?, :boolean, required: true
  attr :failed?, :boolean, default: false
  attr :pending?, :boolean, default: false

  # ORDER IS LOAD-BEARING: `failed?: true` below matches first, and a pending
  # row is still `not_met`, so a clause added after it would never be reached.
  defp check_box(%{pending?: true} = assigns) do
    ~H"""
    <span
      aria-label={gettext("Pending")}
      style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 14px; height: 14px; border-radius: 3px; flex-shrink: 0;",
        "margin-top: 2px;",
        "border: 1.5px solid var(--st-doing);",
        "background: var(--st-doing-soft); color: var(--st-doing);"
      ]}
    >
      <.icon name="hero-clock" class="w-2.5 h-2.5" />
    </span>
    """
  end

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
        "color: var(--color-primary-content);"
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
        "color: var(--color-primary-content);"
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
    ></span>
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
