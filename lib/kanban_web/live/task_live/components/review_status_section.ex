defmodule KanbanWeb.TaskLive.Components.ReviewStatusSection do
  @moduledoc """
  Renders the review-status panel including reviewer, timestamps, and notes.
  Caller is responsible for the outer review-flag guard.
  """
  use KanbanWeb, :html

  attr :task, :map, required: true

  def review_status_section(assigns) do
    ~H"""
    <div class={review_section_class(@task.review_status)}>
      <h4 class="text-sm font-semibold mb-2">{gettext("Review Status")}</h4>
      <div class="space-y-2">
        <p>
          <span class="font-semibold">{gettext("Status")}:</span>
          <span
            class={review_status_badge_class(@task.review_status)}
            style={review_status_badge_fallback_style(@task.review_status)}
          >
            {review_status_label(@task.review_status)}
          </span>
        </p>
        <%= if @task.reviewed_by do %>
          <p>
            <span class="font-semibold">{gettext("Reviewed by")}:</span>
            {@task.reviewed_by.name || @task.reviewed_by.email}
          </p>
        <% end %>
        <%= if @task.reviewed_at do %>
          <p>
            <span class="font-semibold">{gettext("Reviewed at")}:</span>
            {Calendar.strftime(@task.reviewed_at, "%B %d, %Y at %I:%M %p")}
          </p>
        <% end %>
        <%= if @task.review_notes do %>
          <div>
            <p class="font-semibold mb-1">{gettext("Review Notes")}:</p>
            <p class="whitespace-pre-wrap">{@task.review_notes}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp review_status_badge_class(:pending),
    do:
      "px-2 py-1 text-xs rounded bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-200"

  defp review_status_badge_class(:approved),
    do: "px-2 py-1 text-xs rounded bg-green-100 text-green-800"

  defp review_status_badge_class(:changes_requested),
    do: "px-2 py-1 text-xs rounded bg-orange-100 text-orange-800"

  defp review_status_badge_class(:rejected),
    do: "px-2 py-1 text-xs rounded bg-red-100 text-red-800"

  # W593: replaced the daisyUI gray fallback with stride-screen tokens applied
  # via `review_status_badge_fallback_style/1` on the element's inline `style=`
  # attribute. The class helper now returns only structural padding/rounding.
  defp review_status_badge_class(_), do: "px-2 py-1 text-xs rounded"

  defp review_status_badge_fallback_style(:pending), do: nil
  defp review_status_badge_fallback_style(:approved), do: nil
  defp review_status_badge_fallback_style(:changes_requested), do: nil
  defp review_status_badge_fallback_style(:rejected), do: nil

  defp review_status_badge_fallback_style(_),
    do: "background: var(--surface-sunken); color: var(--ink-3);"

  defp review_status_label(:pending), do: gettext("Pending")
  defp review_status_label(:approved), do: gettext("Approved")
  defp review_status_label(:changes_requested), do: gettext("Changes Requested")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(_), do: gettext("Unknown")

  defp review_section_class(:pending),
    do:
      "bg-yellow-50 border border-yellow-200 rounded-lg p-4 dark:bg-yellow-900/20 dark:border-yellow-700/50"

  defp review_section_class(:approved), do: "bg-green-50 border border-green-200 rounded-lg p-4"

  defp review_section_class(:changes_requested),
    do: "bg-orange-50 border border-orange-200 rounded-lg p-4"

  defp review_section_class(:rejected), do: "bg-red-50 border border-red-200 rounded-lg p-4"
  defp review_section_class(_), do: "bg-gray-50 border border-gray-200 rounded-lg p-4"
end
