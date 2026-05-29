defmodule KanbanWeb.TaskLive.Components.WorkflowStepsSection do
  @moduledoc """
  Renders the workflow_steps telemetry rows recorded at task completion.
  Caller is responsible for the outer presence/empty guard.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskTokens

  attr :steps, :list, required: true

  def workflow_steps_section(assigns) do
    ~H"""
    <div class="bg-[var(--stride-violet-soft)] border border-[var(--stride-violet)] rounded-lg p-4">
      <h4 class="text-sm font-semibold text-[var(--stride-violet-ink)] mb-2">
        {gettext("Workflow Steps")}
      </h4>
      <div class="text-[var(--stride-violet-ink)] text-sm space-y-2 max-h-96 overflow-y-auto">
        <%= for step <- @steps do %>
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <span class="font-semibold break-words">
              {(step["name"] && TaskTokens.hook_stage_label(step["name"])) ||
                gettext("(unnamed step)")}
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
    skipped = step["skipped"]
    dispatched = step["dispatched"]
    status = step["status"]
    exit_code = step["exit_code"]
    workflow_step_status_label_from(skipped, dispatched, status, exit_code)
  end

  defp workflow_step_status_label_from(true, _dispatched, _status, _exit_code),
    do: gettext("Skipped")

  defp workflow_step_status_label_from(_skipped, false, _status, _exit_code),
    do: gettext("Not dispatched")

  defp workflow_step_status_label_from(_skipped, _dispatched, status, _exit_code)
       when is_binary(status) and status != "",
       do: status

  defp workflow_step_status_label_from(_skipped, _dispatched, _status, exit_code)
       when is_integer(exit_code),
       do: gettext("exit %{code}", code: exit_code)

  defp workflow_step_status_label_from(_skipped, _dispatched, _status, _exit_code),
    do: gettext("Dispatched")
end
