defmodule KanbanWeb.TaskLive.Components.ActualVsEstimatedSection do
  @moduledoc """
  Renders the actual-vs-estimated panel shown on completed tasks. Caller is
  responsible for the outer status/presence guard.
  """
  use KanbanWeb, :html

  attr :task, :map, required: true

  def actual_vs_estimated_section(assigns) do
    ~H"""
    <div class="bg-[var(--st-ready-soft)] border border-[var(--st-ready)] rounded-lg p-4">
      <h4 class="text-sm font-semibold text-[var(--st-ready)] mb-2">
        {gettext("Actual vs Estimated")}
      </h4>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <%= if @task.actual_complexity do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70">
              {gettext("Actual Complexity")}
            </p>
            <p class="text-[var(--st-ready)]">
              {case @task.actual_complexity do
                :small -> gettext("Small")
                :medium -> gettext("Medium")
                :large -> gettext("Large")
              end}
              <%= if @task.complexity do %>
                <span class="text-xs opacity-60">
                  ({gettext("Est")}: {case @task.complexity do
                    :small -> gettext("Small")
                    :medium -> gettext("Medium")
                    :large -> gettext("Large")
                  end})
                </span>
              <% end %>
            </p>
          </div>
        <% end %>
        <%= if @task.actual_files_changed do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70">
              {gettext("Actual Files Changed")}
            </p>
            <p class="text-[var(--st-ready)]">
              {@task.actual_files_changed}
              <%= if @task.estimated_files do %>
                <span class="text-xs opacity-60">
                  ({gettext("Est")}: {@task.estimated_files})
                </span>
              <% end %>
            </p>
          </div>
        <% end %>
        <%= if @task.time_spent_minutes do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70">
              {gettext("Time Spent")}
            </p>
            <p class="text-[var(--st-ready)]">{@task.time_spent_minutes} {gettext("minutes")}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
