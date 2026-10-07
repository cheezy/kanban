defmodule KanbanWeb.TaskLive.Components.TaskDetailBand do
  @moduledoc """
  The task detail view's top band: type icon, identifier, status pill, and a
  priority dot with the "priority · complexity" words.

  Split out of `KanbanWeb.TaskLive.ViewComponent` to keep that module under the
  module-size guidance in `AGENTS.md`, following `TaskDetailAside` (W2006). It
  is purely presentational: it reads the task and renders, with no events.
  """
  use KanbanWeb, :html

  import KanbanWeb.TaskVisuals

  alias KanbanWeb.TaskTokens

  attr :task, :map, required: true
  attr :can_modify, :boolean, required: true
  attr :board_id, :any, required: true

  def detail_band(assigns) do
    ~H"""
    <div
      data-task-detail-band
      style={[
        "padding: 14px 22px 12px;",
        "border-bottom: 1px solid var(--line);",
        "display: flex; align-items: center; gap: 8px; flex-wrap: wrap;",
        "background: var(--surface);"
      ]}
    >
      <.type_icon type={@task.type} />
      <span class="ident" style="font-size: 11.5px; color: var(--ink-2);">
        {@task.identifier}
      </span>
      <.status_pill status={@task.status} variant={:base} />
      <span
        :if={@task.priority}
        aria-hidden="true"
        style={[
          "width: 6px; height: 6px; border-radius: 50%;",
          "background: #{TaskTokens.priority_color(@task.priority)};"
        ]}
      ></span>
      <span :if={@task.priority || @task.complexity} style="font-size: 11px; color: var(--ink-3);">
        {pretty_meta(@task.priority, @task.complexity)}
      </span>
      <span style="flex: 1;"></span>
    </div>
    """
  end

  defp pretty_meta(nil, nil), do: ""
  defp pretty_meta(priority, nil), do: TaskTokens.priority_word(priority)
  defp pretty_meta(nil, complexity), do: TaskTokens.complexity_word(complexity)

  defp pretty_meta(priority, complexity) do
    "#{TaskTokens.priority_word(priority)} · #{TaskTokens.complexity_word(complexity)}"
  end
end
