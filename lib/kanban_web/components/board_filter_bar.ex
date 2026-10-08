defmodule KanbanWeb.BoardFilterBar do
  @moduledoc """
  Search and filter bar above the board's columns (W2235).

  Renders one form — a text search (`#board-search`) plus type, priority,
  assignee and label selectors — whose `phx-change` and `phx-submit` both
  emit `"filter_change"` with the raw `q`, `type`, `priority`, `assignee` and
  `label` values. `KanbanWeb.BoardLive.FilterActions` turns those into URL
  params; nothing here interprets them. A Clear button (`"clear_filters"`)
  appears while any filter is active, and a hint explains that drag
  reordering is off while filtering.

  Rendered for every viewer, including read-only members and public
  read-only visitors: filtering changes only what this viewer sees.
  """
  use KanbanWeb, :html

  alias KanbanWeb.BoardLive.FilterParams

  @doc """
  Renders the filter bar.

  ## Attrs

    * `filters` — the current `%Kanban.Tasks.BoardFilters{}`. Required.
    * `labels` — the board's labels (`%Kanban.Labels.Label{}`); the label
      selector is omitted when empty. Default `[]`.
    * `members` — the board's members, maps with `:user_id` and `:name`.
      Default `[]`.
    * `active` — whether any filter is set; shows the Clear button.
    * `drag_hint` — whether to show the "reordering is off" hint (only
      meaningful to viewers who could otherwise drag).
  """
  attr :filters, :map, required: true
  attr :labels, :list, default: []
  attr :members, :list, default: []
  attr :active, :boolean, default: false
  attr :drag_hint, :boolean, default: false

  def board_filter_bar(assigns) do
    assigns = assign(assigns, :values, FilterParams.form_values(assigns.filters))

    ~H"""
    <div
      id="board-filter-bar"
      style="display: flex; flex-direction: column; gap: 6px; padding: 0 0 10px;"
    >
      <form
        id="board-filter-form"
        role="search"
        phx-change="filter_change"
        phx-submit="filter_change"
        class="[&_.fieldset]:mb-0"
        style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0;"
      >
        <div style="flex: 1 1 220px; max-width: 320px;">
          <.input
            type="search"
            id="board-search"
            name="q"
            value={@values["q"]}
            placeholder={gettext("Search title or ID")}
            aria-label={gettext("Search tasks")}
            autocomplete="off"
            maxlength={FilterParams.max_search_length()}
            phx-debounce="300"
            class="w-full"
            style={control_style()}
          />
        </div>
        <.input
          type="select"
          id="board-filter-type"
          name="type"
          value={@values["type"]}
          prompt={gettext("All types")}
          options={type_options()}
          aria-label={gettext("Type")}
          class=""
          style={select_style()}
        />
        <.input
          type="select"
          id="board-filter-priority"
          name="priority"
          value={@values["priority"]}
          prompt={gettext("All priorities")}
          options={priority_options()}
          aria-label={gettext("Priority")}
          class=""
          style={select_style()}
        />
        <.input
          type="select"
          id="board-filter-assignee"
          name="assignee"
          value={@values["assignee"]}
          prompt={gettext("All assignees")}
          options={assignee_options(@members)}
          aria-label={gettext("Assignee")}
          class=""
          style={select_style()}
        />
        <.input
          :if={@labels != []}
          type="select"
          id="board-filter-label"
          name="label"
          value={@values["label"]}
          prompt={gettext("All labels")}
          options={Enum.map(@labels, &{&1.name, &1.id})}
          aria-label={gettext("Label")}
          class=""
          style={select_style()}
        />
        <%!-- A bare button, not <.button>: the core component renders the
             filled, 2.5rem-tall .btn-primary (assets/css/app.css), which would
             dwarf the compact 12px filter controls in this row. This matches
             the outlined chip style of the board header's "New column" action
             (show.html.heex) and uses only theme tokens. --%>
        <button
          :if={@active}
          type="button"
          id="board-filter-clear"
          phx-click="clear_filters"
          class="focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style={[
            "display: inline-flex; align-items: center; gap: 4px;",
            "padding: 4px 10px; border-radius: 5px; cursor: pointer;",
            "background: transparent; border: 1px solid var(--line);",
            "color: var(--ink-2); font-size: 12px; font-weight: 600;"
          ]}
        >
          <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
          {gettext("Clear filters")}
        </button>
      </form>
      <p
        :if={@drag_hint}
        id="board-filter-drag-hint"
        role="status"
        style="margin: 0; display: flex; align-items: center; gap: 6px; font-size: 11.5px; color: var(--ink-2);"
      >
        <.icon name="hero-information-circle" class="h-3.5 w-3.5" />
        {gettext("Drag reordering is off while filters are active.")}
      </p>
    </div>
    """
  end

  defp type_options do
    [{gettext("Work"), "work"}, {gettext("Defect"), "defect"}, {gettext("Goal"), "goal"}]
  end

  defp priority_options do
    [
      {gettext("Critical"), "critical"},
      {gettext("High"), "high"},
      {gettext("Medium"), "medium"},
      {gettext("Low"), "low"}
    ]
  end

  defp assignee_options(members) do
    [{gettext("Unassigned"), "unassigned"} | Enum.map(members, &{&1.name, &1.user_id})]
  end

  # Theme-aware tokens only, matching the compact workspace filter selects
  # (`KanbanWeb.AgentsHeader` scope filters).
  defp control_style do
    [
      "padding: 4px 10px; border-radius: 5px; width: 100%;",
      "font: inherit; font-size: 12px;",
      "color: var(--ink); background: var(--surface);",
      "border: 1px solid var(--line);"
    ]
    |> Enum.join(" ")
  end

  defp select_style do
    [
      "appearance: none; -webkit-appearance: none;",
      "padding: 4px 26px 4px 10px; border-radius: 5px;",
      "font: inherit; font-size: 12px; font-weight: 500;",
      "color: var(--ink-2);",
      "background: var(--surface); border: 1px solid var(--line);",
      "background-image: linear-gradient(45deg, transparent 50%, var(--ink-3) 50%), linear-gradient(135deg, var(--ink-3) 50%, transparent 50%);",
      "background-position: calc(100% - 14px) center, calc(100% - 9px) center;",
      "background-size: 5px 5px, 5px 5px; background-repeat: no-repeat;",
      "cursor: pointer;"
    ]
    |> Enum.join(" ")
  end
end
