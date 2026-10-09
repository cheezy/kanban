defmodule KanbanWeb.MyWorkLive do
  @moduledoc """
  Workspace-level My Work queue at `/my-work` (W2237).

  Lists every non-archived, not-completed task assigned to the current user on
  boards they are still a member of, grouped by board and ordered by priority
  within each board. Each row links to the task on its board.

  All data flows through `Kanban.Tasks.list_assigned_tasks/2` (board access is
  enforced there, via `Kanban.Queries.BoardScope`) and
  `Kanban.Tasks.group_tasks_by_board/1`. No Ecto queries live in this module.

  The route sits in the `:require_authenticated_user` live_session, so an
  anonymous visitor is redirected to log in before `mount/3` runs.
  """
  use KanbanWeb, :live_view

  alias Kanban.Tasks
  alias KanbanWeb.LabelChip

  @impl true
  def mount(_params, _session, socket) do
    tasks = Tasks.list_assigned_tasks(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("My Work"))
     |> assign(:task_count, length(tasks))
     |> assign(:groups, Tasks.group_tasks_by_board(tasks))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:my_work}>
      <:breadcrumbs>
        <span>{gettext("Workspace")}</span>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("My Work")}</span>
      </:breadcrumbs>

      <div class="stride-screen" data-my-work style="padding: 20px 24px;">
        <header style="margin-bottom: 16px;">
          <h1 style="margin: 0; font-size: 18px; font-weight: 600; letter-spacing: -0.01em; color: var(--ink);">
            {gettext("My Work")}
          </h1>
          <p data-my-work-count style="margin: 4px 0 0; font-size: 12.5px; color: var(--ink-2);">
            {ngettext(
              "%{count} task assigned to you",
              "%{count} tasks assigned to you",
              @task_count
            )}
          </p>
        </header>

        <.empty_state :if={@groups == []} />

        <section
          :for={{board, tasks} <- @groups}
          data-my-work-board={board.id}
          style="margin-bottom: 18px; border: 1px solid var(--line); border-radius: var(--r-md); background: var(--surface); overflow: hidden;"
        >
          <header style="display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px; border-bottom: 1px solid var(--line); background: var(--surface-2);">
            <.link
              navigate={~p"/boards/#{board.id}"}
              data-my-work-board-link
              style="color: var(--ink); font-weight: 600; font-size: 13px; text-decoration: none;"
            >
              {board.name}
            </.link>
            <span style="font-size: 11px; color: var(--ink-3);">
              {ngettext("%{count} task", "%{count} tasks", length(tasks))}
            </span>
          </header>

          <.task_row :for={task <- tasks} task={task} board={board} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :task, :map, required: true
  attr :board, :map, required: true

  defp task_row(assigns) do
    ~H"""
    <.link
      navigate={task_path(@board, @task)}
      data-my-work-task={@task.id}
      class="row-hover"
      style={[
        "display: grid; grid-template-columns: 80px minmax(0, 1fr) auto auto auto;",
        "align-items: center; gap: 10px; padding: 8px 14px;",
        "border-bottom: 1px solid var(--line); text-decoration: none; color: var(--ink);"
      ]}
    >
      <span style="font-family: var(--font-mono); font-size: 11px; color: var(--ink-3);">
        {@task.identifier}
      </span>
      <span style="font-size: 13px; color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {@task.title}
      </span>
      <LabelChip.label_chips labels={@task.labels} max={3} size={:sm} />
      <span data-my-work-priority style="font-size: 11px; color: var(--ink-2);">
        {priority_label(@task.priority)}
      </span>
      <span data-my-work-row-board style="font-size: 11px; color: var(--ink-3);">
        {@board.name}
      </span>
    </.link>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div data-my-work-empty class="text-center py-14">
      <div
        class="inline-flex items-center justify-center w-16 h-16 mb-[18px]"
        style={[
          "background: var(--surface-2);",
          "color: var(--ink-3);",
          "border: 1px solid var(--line);",
          "border-radius: 999px;"
        ]}
      >
        <.icon name="hero-inbox" class="h-8 w-8" />
      </div>
      <h2 class="m-0 mb-1.5 text-[16px] font-semibold" style="color: var(--ink);">
        {gettext("Nothing assigned to you")}
      </h2>
      <p class="m-0 text-[12.5px]" style="color: var(--ink-2);">
        {gettext("Tasks assigned to you on your boards will appear here.")}
      </p>
    </div>
    """
  end

  # Goals open on their own page, which any board member may view. The task
  # editor is gated on modify access (D110), so a read-only member is sent to
  # the board searched for the task's identifier instead (the W2235 `q` param),
  # where the card opens in view mode, rather than to a "no permission" redirect.
  # The search is a substring match on title or identifier, so a few other
  # cards (W120 for W12, say) can show alongside the task.
  @doc false
  def task_path(board, %{type: :goal} = task), do: ~p"/boards/#{board.id}/goals/#{task.id}"

  def task_path(%{user_access: :read_only} = board, task),
    do: ~p"/boards/#{board.id}?#{[q: task.identifier]}"

  def task_path(board, task), do: ~p"/boards/#{board.id}/tasks/#{task.id}/edit"

  @doc false
  def priority_label(:critical), do: gettext("Critical")
  def priority_label(:high), do: gettext("High")
  def priority_label(:medium), do: gettext("Medium")
  def priority_label(:low), do: gettext("Low")
  def priority_label(_), do: ""
end
