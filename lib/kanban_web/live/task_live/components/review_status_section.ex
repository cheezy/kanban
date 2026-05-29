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

  # W593/D38: the class helper returns only structural padding/rounding for
  # every status; all colors are theme-aware tokens applied through
  # `review_status_badge_fallback_style/1` on the element's inline `style=`
  # attribute, so light/dark are driven from one source (no hardcoded
  # Tailwind palette classes, no `dark:` variants).
  defp review_status_badge_class(_), do: "px-2 py-1 text-xs rounded"

  # D38: status colors as solid-on-soft token pairs (the soft token is the
  # background, the matching solid/ink token is the foreground — the
  # WCAG-AA-tuned pairing). Each status keeps a distinct hue: pending=amber
  # (doing), changes_requested=orange (brand), approved=green (done),
  # rejected=red (blocked). All four tokens carry dark-mode overrides in
  # app.css, so the badge flips automatically.
  defp review_status_badge_fallback_style(:pending),
    do: "background: var(--st-doing-soft); color: var(--st-doing);"

  defp review_status_badge_fallback_style(:approved),
    do: "background: var(--st-done-soft); color: var(--st-done);"

  defp review_status_badge_fallback_style(:changes_requested),
    do: "background: var(--stride-orange-soft); color: var(--stride-orange-ink);"

  defp review_status_badge_fallback_style(:rejected),
    do: "background: var(--st-blocked-soft); color: var(--st-blocked);"

  defp review_status_badge_fallback_style(_),
    do: "background: var(--surface-sunken); color: var(--ink-3);"

  defp review_status_label(:pending), do: gettext("Pending")
  defp review_status_label(:approved), do: gettext("Approved")
  defp review_status_label(:changes_requested), do: gettext("Changes Requested")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(_), do: gettext("Unknown")

  defp review_section_class(:pending),
    do: "bg-[var(--st-doing-soft)] border border-[var(--st-doing)] rounded-lg p-4"

  defp review_section_class(:approved),
    do: "bg-[var(--st-done-soft)] border border-[var(--st-done)] rounded-lg p-4"

  defp review_section_class(:changes_requested),
    do: "bg-[var(--stride-orange-soft)] border border-[var(--stride-orange)] rounded-lg p-4"

  defp review_section_class(:rejected),
    do: "bg-[var(--st-blocked-soft)] border border-[var(--st-blocked)] rounded-lg p-4"

  defp review_section_class(_),
    do: "bg-[var(--surface-sunken)] border border-[var(--line)] rounded-lg p-4"
end
