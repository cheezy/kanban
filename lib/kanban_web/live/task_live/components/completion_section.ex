defmodule KanbanWeb.TaskLive.Components.CompletionSection do
  @moduledoc """
  Renders the completion details panel (timestamp, completer, agent, summary).
  Caller is responsible for the outer status/presence guard.
  """
  use KanbanWeb, :html

  attr :task, :map, required: true

  def completion_section(assigns) do
    ~H"""
    <div class="bg-[var(--st-done-soft)] border border-[var(--st-done)] rounded-lg p-4">
      <h4 class="text-sm font-semibold text-[var(--st-done)] mb-2">{gettext("Completion")}</h4>
      <div class="space-y-2">
        <%= if @task.completed_at do %>
          <p class="text-[var(--st-done)]">
            <span class="font-semibold">{gettext("Completed at")}:</span>
            {Calendar.strftime(@task.completed_at, "%B %d, %Y at %I:%M %p")}
          </p>
        <% end %>
        <%= if @task.completed_by do %>
          <p class="text-[var(--st-done)]">
            <span class="font-semibold">{gettext("Completed by")}:</span>
            {@task.completed_by.name || @task.completed_by.email}
          </p>
        <% end %>
        <%= if @task.completed_by_agent do %>
          <p class="text-[var(--st-done)]">
            <span class="font-semibold">{gettext("Agent")}:</span>
            {@task.completed_by_agent}
          </p>
        <% end %>
        <%= if @task.completion_summary do %>
          <div>
            <p class="font-semibold text-[var(--st-done)] mb-1">{gettext("Summary")}:</p>
            <p class="text-[var(--st-done)] whitespace-pre-wrap">{@task.completion_summary}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
