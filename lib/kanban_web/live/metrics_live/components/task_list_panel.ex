defmodule KanbanWeb.MetricsLive.Components.TaskListPanel do
  @moduledoc """
  The date-grouped task list panel for the board metrics pages, with
  per-task metadata and badge slots and an empty state.

  Split from `KanbanWeb.MetricsLive.Components` to keep that module under the
  module-size guidance in `AGENTS.md`. Callers import or alias this module
  directly, so HEEx checks each call's attributes at compile time.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.MetricsLive.Components.Icon

  @doc """
  Renders a panel containing a date-grouped list of tasks with per-task slots.

  The `:task_metadata` slot is rendered as the small metadata row beneath the
  task title; the `:task_badge` slot renders the right-aligned summary badge
  (e.g., the cycle-time pill). Both slots receive the current task as `task`.

  `date_accent` selects the color used for date group headers. Supported
  values are `:purple`, `:blue`, `:amber`, and `:indigo` — under the
  restyle every accent collapses to the same neutral var(--ink-3) tone
  since the new aesthetic uses uniform header chrome; the attribute is
  preserved for downstream-caller API compatibility.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon_name, :string, required: true
  attr :icon_gradient, :string, required: true
  attr :grouped_tasks, :list, required: true
  attr :date_accent, :atom, default: :purple
  attr :empty_icon, :string, default: "hero-clock"
  attr :empty_message, :string, required: true
  attr :show_day_count, :boolean, default: false

  slot :task_metadata, required: true do
    attr :task, :map
  end

  slot :task_badge, required: true do
    attr :task, :map
  end

  def task_list_panel(assigns) do
    ~H"""
    <section
      data-metric-task-list
      style={[
        "margin-top: 18px; padding: 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <header style={[
        "display: flex; align-items: center; gap: 8px;",
        "margin-bottom: 14px; padding-bottom: 10px;",
        "border-bottom: 1px solid var(--line);"
      ]}>
        <span style="display: inline-flex; color: var(--stride-orange);">
          <.icon name={@icon_name} class="h-4 w-4" />
        </span>
        <h3 style="margin: 0; font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {@title}
        </h3>
        <span
          :if={@subtitle}
          style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
        >
          {@subtitle}
        </span>
      </header>

      <div :if={length(@grouped_tasks) > 0} style="display: flex; flex-direction: column; gap: 16px;">
        <div
          :for={{date, day_tasks} <- @grouped_tasks}
          style="display: flex; flex-direction: column; gap: 6px;"
        >
          <div style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 6px 10px; border-radius: 6px;",
            "background: var(--surface-sunken);",
            "border-left: 2px solid var(--ink-3);"
          ]}>
            <span style="display: inline-flex; color: var(--ink-3);">
              <.icon name="hero-calendar" class="h-3 w-3" />
            </span>
            <div style="flex: 1; display: flex; align-items: center; justify-content: space-between;">
              <h4 style="margin: 0; font-size: 12.5px; font-weight: 600; color: var(--ink);">
                {KanbanWeb.MetricsLive.Helpers.format_date(date)}
              </h4>
              <span
                :if={@show_day_count}
                style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
              >
                {length(day_tasks)} {if length(day_tasks) == 1,
                  do: gettext("task"),
                  else: gettext("tasks")}
              </span>
            </div>
          </div>

          <div style="margin-left: 12px; display: flex; flex-direction: column; gap: 6px;">
            <div
              :for={task <- day_tasks}
              style={[
                "padding: 10px 12px; border-radius: 6px;",
                "background: var(--surface-sunken);",
                "border: 1px solid var(--line);"
              ]}
            >
              <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 14px;">
                <div style="flex: 1; min-width: 0;">
                  <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
                    <span style={[
                      "display: inline-flex; padding: 1px 7px; border-radius: 4px;",
                      "background: var(--st-done-soft); color: var(--st-done);",
                      "font-size: 10.5px; font-weight: 500; font-family: var(--font-mono);"
                    ]}>
                      {task.identifier}
                    </span>
                    <span style={[
                      "font-size: 12.5px; font-weight: 500; color: var(--ink);",
                      "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                    ]}>
                      {task.title}
                    </span>
                  </div>
                  <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 14px; font-size: 11px; color: var(--ink-3);">
                    {render_slot(@task_metadata, task)}
                  </div>
                </div>
                <div style="flex-shrink: 0;">
                  {render_slot(@task_badge, task)}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={length(@grouped_tasks) == 0} style="text-align: center; padding: 48px 0;">
        <span style="display: inline-flex; color: var(--ink-4);">
          <.icon name={@empty_icon} class="h-12 w-12" />
        </span>
        <p style="margin: 12px 0 0; font-size: 13px; font-weight: 500; color: var(--ink-3); font-style: italic;">
          {@empty_message}
        </p>
      </div>
    </section>
    """
  end
end
