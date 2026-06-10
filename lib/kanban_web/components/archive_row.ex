defmodule KanbanWeb.ArchiveRow do
  @moduledoc """
  One row of the 8-column Archive grid on `/boards/:id/archive`.

  Columns:

    1. Type icon (work / defect / goal)
    2. Identifier (`W123`) — strikethrough when reason is `:duplicate`
    3. Title — strikethrough when reason is `:duplicate` or `:wontdo`
    4. Sub-line: duplicate-of link, parent-goal link, archive_note preview
    5. Reason pill (via `KanbanWeb.TaskTokens.archive_reason_*` helpers)
    6. Outcome — cycle time for `:completed`, "died at `column.name`" otherwise
    7. Assignee — avatar + name (em-dash when nil)
    8. Archived-by — date on top, "<age> · by <name>" below
    9. Kebab — fires `:on_action_menu` with `phx-value-id`

  Mirrors `ArchiveRow` in
  `design_handoff_stride/design_source/screens/archive.jsx` lines
  346-460 (GRID constant at line 305). The component is purely
  presentational — the parent LiveView owns the action menu state and
  the data preloads (`:column`, `:assigned_to`, `:archived_by`,
  `:duplicate_of`, `:parent`).
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.Duration
  alias KanbanWeb.TaskTokens
  alias KanbanWeb.TimeAgo

  @doc """
  Renders one archive row.

  ## Attrs

    * `task` — required `%Kanban.Tasks.Task{}`. Expected preloads:
      `:column`, `:assigned_to`, `:archived_by`, `:duplicate_of`,
      `:parent`. The component degrades gracefully when an association
      is `%Ecto.Association.NotLoaded{}` (those cells render the
      em-dash / are simply omitted).
    * `on_action_menu` — required `phx-click` event name fired by the
      kebab button. Receives `phx-value-id={task.id}`.
  """
  attr :task, :map, required: true
  attr :on_action_menu, :string, required: true

  def archive_row(assigns) do
    assigns = assign(assigns, :reason, normalized_reason(assigns.task))

    ~H"""
    <div
      data-archive-row
      data-archive-row-reason={Atom.to_string(@reason)}
      data-archive-row-id={@task.id}
      style={[
        "display: grid; grid-template-columns: 20px 78px minmax(0, 1.6fr) 130px 150px 140px 150px 28px;",
        "align-items: center; gap: 12px;",
        "padding: 8px 14px; border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <.type_icon type={@task.type} />

      <span
        data-archive-row-ident
        style={[
          "font-family: var(--font-mono); font-size: 11px; color: var(--ink-3);",
          if(@reason == :duplicate, do: "text-decoration: line-through;", else: "")
        ]}
      >
        {@task.identifier}
      </span>

      <div style="min-width: 0; display: flex; flex-direction: column; gap: 2px;">
        <span
          data-archive-row-title
          style={[
            "font-size: 12.5px; line-height: 1.35; color: var(--ink);",
            "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;",
            if(@reason in [:duplicate, :wontdo],
              do: "text-decoration: line-through; text-decoration-color: var(--ink-4);",
              else: ""
            )
          ]}
        >
          {@task.title}
        </span>
        <.sub_line task={@task} reason={@reason} />
      </div>

      <.reason_pill reason={@reason} />

      <.outcome_cell task={@task} reason={@reason} />

      <.assignee_cell user={loaded(@task, :assigned_to)} />

      <.archived_by_cell task={@task} />

      <button
        type="button"
        data-archive-row-kebab
        aria-label={gettext("Open archive actions")}
        phx-click={@on_action_menu}
        phx-value-id={@task.id}
        style={[
          "width: 22px; height: 22px;",
          "display: inline-flex; align-items: center; justify-content: center;",
          "padding: 0; border: 0; border-radius: 4px;",
          "background: transparent; color: var(--ink-3);",
          "cursor: pointer;"
        ]}
      >
        <.icon name="hero-ellipsis-horizontal" class="w-3 h-3" />
      </button>
    </div>
    """
  end

  # --- Sub-cells -----------------------------------------------------------

  attr :type, :atom, required: true

  defp type_icon(%{type: :defect} = assigns) do
    type_icon_span(assigns, "hero-bug-ant", "var(--st-blocked)")
  end

  defp type_icon(%{type: :goal} = assigns) do
    type_icon_span(assigns, "hero-flag", "var(--stride-violet)")
  end

  defp type_icon(assigns) do
    type_icon_span(assigns, "hero-document-text", "var(--st-ready)")
  end

  defp type_icon_span(assigns, icon_name, color) do
    assigns = assign(assigns, icon_name: icon_name, color: color)

    ~H"""
    <span
      data-archive-row-type-icon
      aria-hidden="true"
      style={"display: inline-flex; color: #{@color};"}
    >
      <.icon name={@icon_name} class="w-3 h-3" />
    </span>
    """
  end

  attr :reason, :atom, required: true
  attr :task, :map, required: true

  defp sub_line(assigns) do
    assigns = assign(assigns, sub_line_assigns(assigns.task, assigns.reason))

    ~H"""
    <div
      :if={@any?}
      data-archive-row-sub-line
      style={[
        "display: inline-flex; flex-wrap: wrap; gap: 8px;",
        "font-size: 11.5px; color: var(--ink-3);"
      ]}
    >
      <span :if={@show_dup?} data-archive-row-duplicate-of>
        <.icon name="hero-link" class="w-2.5 h-2.5" />
        <span style="font-family: var(--font-mono); margin-left: 4px;">
          → {@duplicate_of.identifier}
        </span>
      </span>

      <span :if={@show_parent?} data-archive-row-parent-goal>
        <.icon name="hero-flag" class="w-2.5 h-2.5" />
        <span style="font-family: var(--font-mono); margin-left: 4px;">
          {gettext("goal:")} {@parent.identifier}
        </span>
      </span>

      <span
        :if={@show_note?}
        data-archive-row-note
        style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 280px;"
      >
        {@note}
      </span>
    </div>
    """
  end

  attr :reason, :atom, required: true

  defp reason_pill(assigns) do
    ~H"""
    <span
      data-archive-row-reason-pill
      style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "padding: 2px 8px; border-radius: 999px;",
        "font-size: 10.5px; font-weight: 500;",
        "background: #{TaskTokens.archive_reason_soft(@reason)};",
        "color: #{TaskTokens.archive_reason_ink(@reason)};"
      ]}
    >
      {TaskTokens.archive_reason_label(@reason)}
    </span>
    """
  end

  attr :task, :map, required: true
  attr :reason, :atom, required: true

  defp outcome_cell(%{reason: :completed} = assigns) do
    cycle = Duration.format_minutes(assigns.task.time_spent_minutes)
    assigns = assign(assigns, :cycle, cycle)

    ~H"""
    <div
      data-archive-row-outcome="completed"
      style="display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px;"
    >
      <span style={"color: #{TaskTokens.archive_reason_ink(:completed)}; display: inline-flex;"}>
        <.icon name="hero-check" class="w-2.5 h-2.5" />
      </span>
      <span style="color: var(--ink-2); font-variant-numeric: tabular-nums;">{@cycle}</span>
    </div>
    """
  end

  defp outcome_cell(assigns) do
    column_name =
      case loaded(assigns.task, :column) do
        %{name: name} when is_binary(name) -> name
        _ -> gettext("unknown")
      end

    assigns = assign(assigns, :column_name, column_name)

    ~H"""
    <div
      data-archive-row-outcome="died"
      style="font-size: 11.5px; color: var(--ink-2);"
    >
      {gettext("died at")}
      <span style="font-weight: 500;">{@column_name}</span>
    </div>
    """
  end

  attr :user, :any, required: true

  defp assignee_cell(%{user: %{} = _user} = assigns) do
    ~H"""
    <div
      data-archive-row-assignee
      style="display: inline-flex; align-items: center; gap: 6px; min-width: 0;"
    >
      <Avatar.avatar
        kind={:human}
        name={user_name(@user)}
        palette={AvatarPalette.for_human(@user.id)}
        size={18}
      />
      <span style="font-size: 11.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {user_name(@user)}
      </span>
    </div>
    """
  end

  defp assignee_cell(assigns) do
    ~H"""
    <span
      data-archive-row-assignee-empty
      style="font-size: 11.5px; color: var(--ink-4);"
    >
      —
    </span>
    """
  end

  attr :task, :map, required: true

  defp archived_by_cell(assigns) do
    user = loaded(assigns.task, :archived_by)
    assigns = assign(assigns, :user, user)

    ~H"""
    <div data-archive-row-archived-by style="display: flex; flex-direction: column; gap: 2px;">
      <span style="font-size: 11.5px; color: var(--ink-2);">
        {format_date(@task.archived_at)}
      </span>
      <span
        :if={@user}
        style="font-size: 10.5px; color: var(--ink-3); font-family: var(--font-mono);"
      >
        {TimeAgo.format_age(@task.archived_at, :coarse)} · {gettext("by")} {user_name(@user)}
      </span>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp sub_line_assigns(task, reason) do
    duplicate_of = loaded(task, :duplicate_of)
    parent = loaded(task, :parent)
    note = task.archive_note

    show_dup? = reason == :duplicate and not is_nil(duplicate_of)
    show_parent? = not is_nil(parent)
    show_note? = note_visible?(reason, note)

    %{
      duplicate_of: duplicate_of,
      parent: parent,
      note: note,
      show_dup?: show_dup?,
      show_parent?: show_parent?,
      show_note?: show_note?,
      any?: show_dup? or show_parent? or show_note?
    }
  end

  defp note_visible?(reason, note) when reason in [:wontdo, :deferred, :cancelled] do
    is_binary(note) and String.trim(note) != ""
  end

  defp note_visible?(_reason, _note), do: false

  defp normalized_reason(%{archive_reason: nil}), do: :completed
  defp normalized_reason(%{archive_reason: reason}), do: reason

  defp loaded(map, key) do
    case Map.get(map, key) do
      %Ecto.Association.NotLoaded{} -> nil
      value -> value
    end
  end

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%{email: email}) when is_binary(email), do: email
  defp user_name(_), do: "?"

  defp format_date(nil), do: ""

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d")
  end
end
