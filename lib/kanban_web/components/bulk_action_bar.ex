defmodule KanbanWeb.BulkActionBar do
  @moduledoc """
  Controls for the board's bulk selection mode (W2238): the toggle that
  enters and leaves it, the per-card selection checkbox, a per-column
  "Select all" button, and the sticky action bar that moves, assigns,
  labels or archives the selected cards.

  Every control only emits a `bulk_*` event; `KanbanWeb.BoardLive.BulkSelection`
  holds the selection and `Kanban.Tasks.BulkActions` authorizes and applies
  the change. The board renders these only for viewers who can modify it, but
  the server refuses the events from anyone else regardless.

  Styled with theme tokens only, matching the compact controls of
  `KanbanWeb.BoardFilterBar`.
  """
  use KanbanWeb, :html

  alias KanbanWeb.BoardLive.ColumnActions

  @doc "The header button that enters or leaves selection mode."
  attr :active, :boolean, required: true

  def selection_toggle(assigns) do
    ~H"""
    <button
      type="button"
      id="bulk-select-toggle"
      phx-click="bulk_toggle_mode"
      aria-pressed={to_string(@active)}
      class="min-h-[44px] md:min-h-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style={[
        outline_button_style(),
        if(@active, do: " border-color: var(--ink); color: var(--ink);", else: "")
      ]}
    >
      <.icon name={if @active, do: "hero-x-mark", else: "hero-check-circle"} class="h-3.5 w-3.5" />
      {if @active, do: gettext("Done selecting"), else: gettext("Select")}
    </button>
    """
  end

  @doc """
  The selection checkbox drawn over a card. A button with `role="checkbox"`
  rather than a native input, so its checked state always matches the
  server's selection.
  """
  attr :task_id, :integer, required: true
  attr :title, :string, default: ""
  attr :selected, :boolean, default: false

  def select_checkbox(assigns) do
    ~H"""
    <button
      type="button"
      id={"bulk-select-#{@task_id}"}
      role="checkbox"
      aria-checked={to_string(@selected)}
      aria-label={gettext("Select %{title}", title: @title)}
      phx-click="bulk_toggle"
      phx-value-id={@task_id}
      class="bulk-select absolute top-1.5 left-1.5 z-10 inline-flex items-center justify-center min-h-11 min-w-11 md:min-h-0 md:min-w-0 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style="cursor: pointer; background: transparent; border: 0; padding: 2px;"
    >
      <span
        aria-hidden="true"
        style={[
          "display: inline-flex; align-items: center; justify-content: center;",
          "width: 16px; height: 16px; border-radius: 4px;",
          "border: 1.5px solid var(--ink-2);",
          if(@selected,
            do: "background: var(--ink); color: var(--surface); border-color: var(--ink);",
            else: "background: var(--surface); color: transparent;"
          )
        ]}
      >
        <.icon name="hero-check-mini" class="h-3 w-3" />
      </span>
    </button>
    """
  end

  @doc "Selects (or clears) every visible card in a column."
  attr :column_id, :integer, required: true
  attr :all_selected, :boolean, default: false

  def select_column_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"bulk-select-column-#{@column_id}"}
      phx-click="bulk_select_column"
      phx-value-id={@column_id}
      class="mt-1 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style="background: transparent; border: 0; padding: 2px 0; cursor: pointer; font-size: 11.5px; font-weight: 600; color: var(--ink-2); text-decoration: underline;"
    >
      {if @all_selected, do: gettext("Clear all"), else: gettext("Select all")}
    </button>
    """
  end

  @doc """
  The sticky bar shown in selection mode.

  ## Attrs

    * `count` — the number of selected cards. Required.
    * `columns` — the board's columns, for the move target. Default `[]`.
    * `members` — the board's members, maps with `:user_id` and `:name`.
    * `labels` — the board's labels; the label actions are omitted when
      empty.
  """
  attr :count, :integer, required: true
  attr :columns, :list, default: []
  attr :members, :list, default: []
  attr :labels, :list, default: []

  def bulk_action_bar(assigns) do
    assigns = assign(assigns, :none?, assigns.count == 0)

    ~H"""
    <div
      id="bulk-action-bar"
      role="toolbar"
      aria-label={gettext("Bulk actions")}
      class="[&_.fieldset]:mb-0"
      style={[
        "position: sticky; top: 0; z-index: 30; margin: 0 0 10px;",
        "display: flex; flex-wrap: wrap; align-items: center; gap: 8px;",
        "padding: 8px 10px; border-radius: 8px;",
        "background: var(--surface); border: 1px solid var(--line);",
        "box-shadow: var(--shadow-sm); color: var(--ink);"
      ]}
    >
      <span id="bulk-selected-count" role="status" style="font-size: 12px; font-weight: 600;">
        {ngettext("%{count} selected", "%{count} selected", @count)}
      </span>

      <form id="bulk-move-form" phx-submit="bulk_move" style={form_style()}>
        <.input
          type="select"
          id="bulk-move-column"
          name="column_id"
          value=""
          prompt={gettext("Move to…")}
          options={Enum.map(@columns, &{ColumnActions.translate_column_name(&1.name), &1.id})}
          aria-label={gettext("Move to column")}
          class=""
          style={select_style()}
        />
        <button type="submit" disabled={@none?} style={solid_button_style()}>
          {gettext("Move")}
        </button>
      </form>

      <form id="bulk-assign-form" phx-submit="bulk_assign" style={form_style()}>
        <.input
          type="select"
          id="bulk-assign-member"
          name="assignee"
          value=""
          prompt={gettext("Assign to…")}
          options={[
            {gettext("Unassigned"), "unassigned"} | Enum.map(@members, &{&1.name, &1.user_id})
          ]}
          aria-label={gettext("Assign to member")}
          class=""
          style={select_style()}
        />
        <button type="submit" disabled={@none?} style={solid_button_style()}>
          {gettext("Assign")}
        </button>
      </form>

      <form
        :if={@labels != []}
        id="bulk-add-label-form"
        phx-submit="bulk_add_label"
        style={form_style()}
      >
        <.input
          type="select"
          id="bulk-add-label"
          name="label_id"
          value=""
          prompt={gettext("Add label…")}
          options={Enum.map(@labels, &{&1.name, &1.id})}
          aria-label={gettext("Label to add")}
          class=""
          style={select_style()}
        />
        <button type="submit" disabled={@none?} style={solid_button_style()}>
          {gettext("Add")}
        </button>
      </form>

      <form
        :if={@labels != []}
        id="bulk-remove-label-form"
        phx-submit="bulk_remove_label"
        style={form_style()}
      >
        <.input
          type="select"
          id="bulk-remove-label"
          name="label_id"
          value=""
          prompt={gettext("Remove label…")}
          options={Enum.map(@labels, &{&1.name, &1.id})}
          aria-label={gettext("Label to remove")}
          class=""
          style={select_style()}
        />
        <button type="submit" disabled={@none?} style={solid_button_style()}>
          {gettext("Remove")}
        </button>
      </form>

      <button
        type="button"
        id="bulk-archive"
        phx-click="bulk_archive"
        disabled={@none?}
        data-confirm={
          dngettext(
            "tasks",
            "Archive %{count} selected task? Goals are skipped.",
            "Archive %{count} selected tasks? Goals are skipped.",
            @count
          )
        }
        class="focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        style={[outline_button_style(), " color: var(--st-blocked);"]}
      >
        <.icon name="hero-archive-box" class="h-3.5 w-3.5" />
        {gettext("Archive")}
      </button>

      <button
        type="button"
        id="bulk-clear"
        phx-click="bulk_clear"
        disabled={@none?}
        class="focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        style={outline_button_style()}
      >
        {gettext("Clear selection")}
      </button>
    </div>
    """
  end

  defp form_style, do: "display: inline-flex; align-items: center; gap: 4px; margin: 0;"

  # A bare button, not <.button>: the core component renders the filled,
  # 2.5rem-tall .btn-primary, which would dwarf these compact controls (the
  # same choice as BoardFilterBar's Clear button).
  defp outline_button_style do
    [
      "display: inline-flex; align-items: center; gap: 4px;",
      "padding: 4px 10px; border-radius: 5px; cursor: pointer;",
      "background: transparent; border: 1px solid var(--line);",
      "color: var(--ink-2); font-size: 12px; font-weight: 600;"
    ]
    |> Enum.join(" ")
  end

  defp solid_button_style do
    [
      "display: inline-flex; align-items: center;",
      "padding: 4px 10px; border-radius: 5px; cursor: pointer;",
      "background: var(--ink); color: var(--surface); border: 1px solid var(--ink);",
      "font-size: 12px; font-weight: 600;"
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
