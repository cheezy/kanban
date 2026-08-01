defmodule KanbanWeb.TaskLive.Components.CompletionSection do
  @moduledoc """
  Renders the completion details panel (timestamp, completer, agent, summary,
  notes). Caller is responsible for the outer status/presence guard — see
  `KanbanWeb.ReviewReportHelpers.Panels.completion_panel_visible?/1`, which is what
  gates this section in the task view.

  `completion_notes` is agent-authored free text and is interpolated through
  HEEx, which auto-escapes it — never render it through a raw-HTML helper, and
  do not parse it: agents are instructed to record refusals there, so it can
  quote task content that must stay literal.

  ## Audience: deliberately not gated on board membership (D209)

  This section is NOT membership-scoped, and that is a decision rather than an
  oversight. `KanbanWeb.BoardLive.Show` loads through
  `Kanban.Boards.get_board/2`, which admits a non-member whenever the board is
  `read_only`, so on such a board every authenticated user sees the completion
  narrative — `completion_summary` and `completion_notes` alike. The Review
  queue, the other render site, IS membership-scoped; these two audiences
  differ on purpose.

  `read_only` boards are a share-outward feature and the completion narrative
  is part of what is shared, so the exposure was accepted rather than gated.
  Note what that does and does not rest on: `Kanban.Tasks.CompletionNotesScan`
  is a **detective** control over this field, not a preventive one — it never
  blocks a completion and never redacts, so it does not stop a leaked
  credential from being persisted and rendered here. If that trade stops
  holding, gate on the `user_access` assign `BoardLive.Show` already computes
  (it is `nil` for exactly the read_only non-member case) — do not reach for
  `completion_panel_visible?/1`, which is a status/content predicate and must
  not become an authorization decision point.
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
        <%!-- Deliberately not gated on board membership (D209): on a read_only
        board a non-member reaches this, and that is the intended share-outward
        behaviour. See the moduledoc before adding a check here. --%>
        <%= if @task.completion_notes do %>
          <div>
            <p class="font-semibold text-[var(--st-done)] mb-1">{gettext("Completion notes")}:</p>
            <p class="text-[var(--st-done)] whitespace-pre-wrap break-words">
              {@task.completion_notes}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
