defmodule KanbanWeb.TaskLive.Components.TaskDetailAside do
  @moduledoc """
  The task detail view's right-rail metadata aside: status, author, parent
  goal, type, priority, complexity, column, board, review requirement,
  capabilities, the human-task and estimated-files flags, the created/claimed/
  completed dates, and the Edit link.

  Split out of `KanbanWeb.TaskLive.ViewComponent` (W2005/W2006), which W1965
  had pushed past the module-size guidance in `AGENTS.md`. This block was
  chosen as the seam because it was the largest stretch of markup in that
  module never extracted to a component, and because it is entirely
  presentational: it reads `@task` and renders, with no events, no selection
  state and no `@myself`. The interactive surface — `handle_event/3`, the
  `selected_changed_file` state and its reset logic, and the changed-files
  panel that carries `phx-target={@myself}` — all stay on the live_component,
  which is the only thing that can receive an event.

  Every helper here is private and used only by this aside; the caller keeps
  the ones its own remaining sections still need. Pure: the task is already
  loaded, so this component performs no DB access.
  """
  use KanbanWeb, :html

  import KanbanWeb.TaskVisuals

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.MetaItem
  alias KanbanWeb.TaskTokens

  attr :task, :map, required: true
  attr :can_modify, :boolean, required: true
  attr :board_id, :any, required: true

  def task_detail_aside(assigns) do
    ~H"""
    <aside
      data-task-detail-aside
      class="task-detail-aside"
      style={[
        "width: 280px; flex-shrink: 0;",
        "border-left: 1px solid var(--line);",
        "background: var(--surface-2);",
        "padding: 20px 18px;",
        "display: flex; flex-direction: column; gap: 16px;"
      ]}
    >
      <MetaItem.meta_item label={gettext("Status")}>
        <.status_pill status={@task.status} variant={:base} />
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.assigned_to || @task.created_by} label={gettext("Author")}>
        <.author_avatar user={@task.assigned_to || @task.created_by} />
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={parent_goal_loaded?(@task)} label={gettext("Goal")}>
        <span style="color: var(--stride-violet); display: inline-flex;">
          <.icon name="hero-flag" class="w-3 h-3" />
        </span>
        <span class="ident">{@task.parent.identifier}</span>
        <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
          {@task.parent.title}
        </span>
      </MetaItem.meta_item>

      <MetaItem.meta_item label={gettext("Type")}>
        <span>{TaskTokens.type_label(@task.type)}</span>
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.priority} label={gettext("Priority")}>
        <span
          aria-hidden="true"
          style={[
            "width: 6px; height: 6px; border-radius: 50%;",
            "background: #{TaskTokens.priority_color(@task.priority)};"
          ]}
        ></span>
        <span>{TaskTokens.priority_word(@task.priority)}</span>
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.complexity} label={gettext("Complexity")}>
        {TaskTokens.complexity_word(@task.complexity)}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.column} label={gettext("Column")}>
        {@task.column.name}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={board_name_for(@task)} label={gettext("Board")}>
        {board_name_for(@task)}
      </MetaItem.meta_item>

      <MetaItem.meta_item label={gettext("Needs review")}>
        <span :if={@task.needs_review} style={needs_review_pill_style()}>
          {gettext("Required")}
        </span>
        <span :if={!@task.needs_review} style="color: var(--ink-3); font-style: italic;">
          {gettext("Auto")}
        </span>
      </MetaItem.meta_item>

      <MetaItem.meta_item
        :if={@task.required_capabilities && @task.required_capabilities != []}
        label={gettext("Capabilities")}
      >
        <span
          :for={capability <- @task.required_capabilities}
          style={[
            "display: inline-flex; align-items: center;",
            "padding: 1px 6px; border-radius: 999px;",
            "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
            "font-size: 10.5px; font-weight: 600;"
          ]}
        >
          {capability}
        </span>
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.human_task} label={gettext("Human task")}>
        {gettext("Yes")}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.estimated_files} label={gettext("Estimated files")}>
        {@task.estimated_files}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.inserted_at} label={gettext("Created")} mono>
        {Calendar.strftime(@task.inserted_at, "%b %d, %Y")}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.claimed_at} label={gettext("Claimed")} mono>
        {Calendar.strftime(@task.claimed_at, "%b %d, %Y %H:%M")}
      </MetaItem.meta_item>

      <MetaItem.meta_item :if={@task.completed_at} label={gettext("Completed")} mono>
        {Calendar.strftime(@task.completed_at, "%b %d, %Y")}
      </MetaItem.meta_item>

      <div
        :if={@can_modify && @board_id}
        style="margin-top: 4px; padding-top: 14px; border-top: 1px solid var(--line);"
      >
        <.link
          patch={~p"/boards/#{@board_id}/tasks/#{@task}/edit"}
          style={[
            "display: inline-flex; align-items: center; gap: 6px;",
            "padding: 6px 10px; border-radius: 5px;",
            "background: var(--surface); border: 1px solid var(--line);",
            "color: var(--ink-2); text-decoration: none;",
            "font-size: 11.5px; font-weight: 500;"
          ]}
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
          <span>{gettext("Edit task")}</span>
        </.link>
      </div>
    </aside>
    """
  end

  attr :user, :map, required: true

  defp author_avatar(assigns) do
    user = assigns.user
    name = user_display_name(user)
    palette = palette_for_user(user)

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:palette, palette)

    ~H"""
    <Avatar.avatar kind={:human} name={@name} palette={@palette} size={16} />
    <span style="font-size: 11.5px; color: var(--ink-2);">{@name}</span>
    """
  end

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"

  defp palette_for_user(%{id: id}) when is_integer(id), do: AvatarPalette.for_human(id)
  defp palette_for_user(_), do: "human-blue"

  defp parent_goal_loaded?(%{parent: %Ecto.Association.NotLoaded{}}), do: false
  defp parent_goal_loaded?(%{parent: nil}), do: false
  defp parent_goal_loaded?(%{parent: _}), do: true
  defp parent_goal_loaded?(_), do: false

  defp board_name_for(%{column: %{board: %{name: name}}}) when is_binary(name), do: name
  defp board_name_for(_), do: nil

  defp needs_review_pill_style do
    [
      "display: inline-flex; align-items: center;",
      "padding: 1px 6px; border-radius: 999px;",
      "background: var(--st-review-soft); color: var(--st-review);",
      "font-size: 10.5px; font-weight: 600;"
    ]
  end
end
