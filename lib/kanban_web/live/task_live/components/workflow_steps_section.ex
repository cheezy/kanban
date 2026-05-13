defmodule KanbanWeb.TaskLive.Components.WorkflowStepsSection do
  @moduledoc """
  Renders the workflow_steps telemetry rows recorded at task completion.
  Caller is responsible for the outer presence/empty guard.
  """
  use KanbanWeb, :html

  attr :steps, :list, required: true

  def workflow_steps_section(assigns) do
    ~H"""
    <div class="bg-indigo-50 border border-indigo-200 rounded-lg p-4 dark:bg-indigo-900/20 dark:border-indigo-700/50">
      <h4 class="text-sm font-semibold text-indigo-900 dark:text-indigo-200 mb-2">
        {gettext("Workflow Steps")}
      </h4>
      <div class="text-indigo-900 dark:text-indigo-100 text-sm space-y-2 max-h-96 overflow-y-auto">
        <%= for step <- @steps do %>
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <span class="font-semibold break-words">
              {step["name"] || gettext("(unnamed step)")}
            </span>
            <span class="text-xs">
              {workflow_step_status_label(step)}
            </span>
            <%= if is_integer(step["duration_ms"]) do %>
              <span class="text-xs opacity-70">
                {gettext("%{ms} ms", ms: step["duration_ms"])}
              </span>
            <% end %>
            <%= if is_binary(step["reason"]) && step["reason"] != "" do %>
              <p class="w-full text-xs opacity-80 whitespace-pre-wrap break-words">
                <span class="font-semibold">{gettext("Reason")}:</span> {step["reason"]}
              </p>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp workflow_step_status_label(%{} = step) do
    cond do
      step["skipped"] == true -> gettext("Skipped")
      step["dispatched"] == false -> gettext("Not dispatched")
      is_binary(step["status"]) and step["status"] != "" -> step["status"]
      is_integer(step["exit_code"]) -> gettext("exit %{code}", code: step["exit_code"])
      true -> gettext("Dispatched")
    end
  end
end
