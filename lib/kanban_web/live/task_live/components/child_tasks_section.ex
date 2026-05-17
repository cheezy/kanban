defmodule KanbanWeb.TaskLive.Components.ChildTasksSection do
  @moduledoc """
  Renders the table of child tasks for a goal-type task. Caller is responsible
  for the outer presence/empty guard.
  """
  use KanbanWeb, :html

  attr :children, :list, required: true

  def child_tasks_section(assigns) do
    ~H"""
    <div>
      <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
        {gettext("Child Tasks")}
      </h4>
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-base-300">
          <thead class="bg-base-200">
            <tr>
              <th
                scope="col"
                class="px-4 py-2 text-left text-xs font-semibold text-base-content uppercase tracking-wider"
              >
                {gettext("ID")}
              </th>
              <th
                scope="col"
                class="px-4 py-2 text-left text-xs font-semibold text-base-content uppercase tracking-wider"
              >
                {gettext("Title")}
              </th>
              <th
                scope="col"
                class="px-4 py-2 text-left text-xs font-semibold text-base-content uppercase tracking-wider"
              >
                {gettext("Type")}
              </th>
              <th
                scope="col"
                class="px-4 py-2 text-left text-xs font-semibold text-base-content uppercase tracking-wider"
              >
                {gettext("Column")}
              </th>
            </tr>
          </thead>
          <tbody class="bg-base-100 divide-y divide-base-300">
            <%= for child <- @children do %>
              <tr class="hover:bg-base-200">
                <td class="px-4 py-2 whitespace-nowrap text-sm font-mono font-bold text-base-content">
                  {child.identifier}
                </td>
                <td class="px-4 py-2 text-sm text-base-content">
                  {child.title}
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <span class={[
                    "px-2 py-1 text-xs font-semibold rounded-full",
                    case child.type do
                      :work ->
                        "bg-[var(--st-ready-soft)] text-[var(--st-ready)]"

                      :defect ->
                        "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-200"

                      :goal ->
                        "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-200"
                    end
                  ]}>
                    {case child.type do
                      :work -> gettext("Work")
                      :defect -> gettext("Defect")
                      :goal -> gettext("Goal")
                    end}
                  </span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm text-base-content">
                  {child.column.name}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
