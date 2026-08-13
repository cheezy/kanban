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
            <span :if={duration_text(step)} class="text-xs opacity-70">
              {duration_text(step)}
            </span>
            <%= if is_binary(step["reason_code"]) && step["reason_code"] != "" do %>
              <span class="text-xs font-mono border border-current rounded px-1.5 py-0.5 opacity-80">
                {step["reason_code"]}
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

  # `after_doing` fires as PreToolUse of the completion request whose body
  # already carries `after_doing_result`, and `before_review` as that same
  # request's PostToolUse — so neither duration exists when the payload is
  # serialised, and both arrive as a permanent `0` (D242). A literal "0 ms" is
  # indistinguishable from a genuine near-instant run, so render an em dash for
  # a figure that is structurally unknowable rather than reporting a measurement
  # that was never taken.
  @unmeasurable_steps ~w(after_doing before_review)

  # Only the `0` placeholder is rewritten. A non-zero figure on these steps
  # still renders normally, so this stays correct if a later change ever gives
  # them a real destination.
  defp duration_text(%{"name" => name, "duration_ms" => 0}) when name in @unmeasurable_steps,
    do: "—"

  defp duration_text(%{"duration_ms" => ms}) when is_integer(ms),
    do: gettext("%{ms} ms", ms: ms)

  defp duration_text(_step), do: nil

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
