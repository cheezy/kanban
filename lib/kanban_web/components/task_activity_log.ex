defmodule KanbanWeb.TaskActivityLog do
  @moduledoc """
  Timeline view of a task's history. Renders one entry per
  `%Kanban.Tasks.TaskHistory{}` record (or plain map of the same shape)
  passed in by the LiveView.

  Mirrors the timeline block in the pane variant of
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  243-253, rewrapped for `.stride-screen` tokens (`--ink-*`, `--st-*`,
  `--line`, `--surface`). Sibling to
  `KanbanWeb.TaskLive.Components.HistorySection` — this is the new-design
  presentation; the existing module continues to back the legacy template
  until the ViewComponent migration in W545.

  This component is pure presentation: it does not load, sort, or filter
  history rows. The caller is expected to pass an ordered list (the
  `get_task_with_history!` query already orders `desc: inserted_at`).
  """
  use KanbanWeb, :html

  @doc """
  Renders the activity log.

  ## Attrs

    * `histories` — list of `%TaskHistory{}` structs or plain maps with
      atom keys (`:type`, `:from_column`, `:to_column`, `:from_priority`,
      `:to_priority`, `:from_user`, `:to_user`, `:from_user_id`,
      `:to_user_id`, `:inserted_at`). Required.
  """
  attr :histories, :list, required: true

  def activity_log(assigns) do
    ~H"""
    <section
      data-activity-log
      class="stride-screen"
      style="display: flex; flex-direction: column; gap: 6px;"
    >
      <h3 style={[
        "margin: 0; font-size: 12.5px; font-weight: 600;",
        "letter-spacing: -0.005em; color: var(--ink);"
      ]}>
        {gettext("History")}
      </h3>

      <p
        :if={@histories == []}
        style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
      >
        {gettext("No history available")}
      </p>

      <ul
        :if={@histories != []}
        style={[
          "margin: 0; padding: 0; list-style: none;",
          "display: flex; flex-direction: column; gap: 8px;"
        ]}
      >
        <li
          :for={entry <- @histories}
          style="display: flex; align-items: flex-start; gap: 8px; font-size: 12px;"
        >
          <span
            aria-hidden="true"
            style={[
              "display: inline-flex; align-items: center; justify-content: center;",
              "flex-shrink: 0; margin-top: 1px;",
              "color: #{entry_color(Map.get(entry, :type))};"
            ]}
          >
            <.icon name={entry_icon(Map.get(entry, :type))} class="w-3.5 h-3.5" />
          </span>
          <div style="flex: 1; min-width: 0;">
            <p style="margin: 0; color: var(--ink);">
              <.entry_message entry={entry} />
            </p>
            <p style="margin: 0; font-size: 11px; color: var(--ink-3); font-variant-numeric: tabular-nums;">
              {format_dt(Map.get(entry, :inserted_at))}
            </p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp entry_message(%{entry: %{type: :creation}} = assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Created")}</span>
    """
  end

  defp entry_message(%{entry: %{type: :move}} = assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Moved")}</span>
    {gettext("from")}
    <span style="font-weight: 600;">{Map.get(@entry, :from_column)}</span>
    {gettext("to")}
    <span style="font-weight: 600;">{Map.get(@entry, :to_column)}</span>
    """
  end

  defp entry_message(%{entry: %{type: :priority_change}} = assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Priority changed")}</span>
    {gettext("from")}
    <span style="font-weight: 600;">{Map.get(@entry, :from_priority)}</span>
    {gettext("to")}
    <span style="font-weight: 600;">{Map.get(@entry, :to_priority)}</span>
    """
  end

  defp entry_message(%{entry: %{type: :assignment} = entry} = assigns) do
    case assignment_kind(entry) do
      :assigned -> assigned_message(assigns)
      :unassigned -> unassigned_message(assigns)
      :reassigned -> reassigned_message(assigns)
    end
  end

  defp entry_message(assigns) do
    ~H"""
    <span style="color: var(--ink-3); font-style: italic;">
      {gettext("Unknown history entry")}
    </span>
    """
  end

  defp assigned_message(assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Assigned to")}</span>
    <span style="font-weight: 600; color: var(--stride-violet);">
      {user_name(Map.get(@entry, :to_user))}
    </span>
    """
  end

  defp unassigned_message(assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Unassigned from")}</span>
    <span style="font-weight: 600; color: var(--stride-violet);">
      {user_name(Map.get(@entry, :from_user))}
    </span>
    """
  end

  defp reassigned_message(assigns) do
    ~H"""
    <span style="font-weight: 600;">{gettext("Reassigned")}</span>
    {gettext("from")}
    <span style="font-weight: 600; color: var(--stride-violet);">
      {user_name(Map.get(@entry, :from_user))}
    </span>
    {gettext("to")}
    <span style="font-weight: 600; color: var(--stride-violet);">
      {user_name(Map.get(@entry, :to_user))}
    </span>
    """
  end

  # --- Helpers -----------------------------------------------------------

  defp assignment_kind(%{from_user_id: nil, to_user_id: to}) when not is_nil(to), do: :assigned

  defp assignment_kind(%{from_user_id: from, to_user_id: nil}) when not is_nil(from),
    do: :unassigned

  defp assignment_kind(_), do: :reassigned

  defp entry_icon(:creation), do: "hero-plus-circle"
  defp entry_icon(:move), do: "hero-arrow-right-circle"
  defp entry_icon(:priority_change), do: "hero-exclamation-circle"
  defp entry_icon(:assignment), do: "hero-user-circle"
  defp entry_icon(_), do: "hero-question-mark-circle"

  defp entry_color(:creation), do: "var(--st-done)"
  defp entry_color(:move), do: "var(--st-doing)"
  defp entry_color(:priority_change), do: "var(--stride-orange)"
  defp entry_color(:assignment), do: "var(--stride-violet)"
  defp entry_color(_), do: "var(--ink-3)"

  defp user_name(%{name: name}) when is_binary(name), do: name
  defp user_name(_), do: gettext("Unknown")

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  defp format_dt(_), do: ""
end
