defmodule KanbanWeb.ReviewReportHelpers.Panels do
  @moduledoc """
  The panel-visibility surface for a task's review sections: the one
  definition of the review-or-done gate, and every "should this section
  render?" predicate that reads it.

  Split out of `KanbanWeb.ReviewReportHelpers` (W2005), which W1962 had
  pushed back past the module-size guidance in `AGENTS.md`. The whole
  surface moved rather than half of it, so a reader asking "what decides
  whether this panel shows?" has exactly one module to open: the reviewer
  panel (W1085) and the completion, changed-files and review-or-done
  predicates (W1962) all live here. The parent keeps what those panels
  render — the structured-field reads, the incomplete-section rules and the
  per-section value/passed accessors — and the explorer panel's own
  predicate stays in the `Explorer` sibling, which calls
  `review_or_done?/1` here.

  `fetch_field/2` and `present_list?/1` are deliberately duplicated from the
  parent. Both are private there and still needed by the section accessors
  that stayed behind, and Elixir has no way to share a private function
  across modules — so this small duplication is what keeps the two modules
  independent instead of pointing them at each other.

  Every function is pure: no DB access, no scope resolution. These are
  display predicates and must not become an authorization decision point.
  """

  # The completion fields worth rendering, and so the ones that make the
  # Completion section worth showing. The first four are exactly the set the
  # inline guard in `KanbanWeb.TaskLive.ViewComponent` requires today;
  # `completion_notes` widens it by one so a task carrying only notes still
  # renders (W1962). That call site was swapped onto this predicate in W1963,
  # so this list is now the only place the field set is written.
  @completion_fields [
    :completed_at,
    :completed_by,
    :completed_by_agent,
    :completion_summary,
    :completion_notes
  ]

  @doc """
  True when the task has anything the review panel can render — a non-empty
  structured `reviewer_result` or a non-empty `review_report` markdown
  string. Drives panel visibility in both the task edit form and the
  read-only task view (W1085). Pure; no DB access.
  """
  def review_panel_visible?(task) do
    has_reviewer_result?(task) or has_review_report?(task)
  end

  @doc """
  True when the task carries a non-empty `reviewer_result` map.
  """
  def has_reviewer_result?(%{reviewer_result: %{} = result}), do: map_size(result) > 0
  def has_reviewer_result?(_), do: false

  @doc """
  True when the task carries a non-empty `review_report` binary (whitespace
  counts as content, matching the original predicate).
  """
  def has_review_report?(%{review_report: report}) when is_binary(report) and report != "",
    do: true

  def has_review_report?(_), do: false

  @doc """
  True when the task has reached review or done — `review_status` is set, or
  `status` is `:completed`.

  This is the ONE definition of that gate (W1962). Every panel predicate that
  needs it — `completion_panel_visible?/1`, `changed_files_panel_visible?/1`
  and `KanbanWeb.ReviewReportHelpers.Explorer.explorer_panel_visible?/1` —
  calls this rather than restating the boolean, so refining the rule refines
  every panel at once instead of letting them drift apart.

  The gate is deliberately NOT keyed off the column name or `needs_review`.
  Note `status` and `review_status` are independent, so an `:in_progress`
  task IS review-or-done once `review_status` is set — which is the intended
  behaviour, not an oversight: `AgentWorkflow.move_to_doing/3` returns a
  `changes_requested` or `rejected` task to Doing without clearing
  `review_status`, and its review record stays relevant across that round
  trip.

  Tolerates both the atom-keyed task struct and a raw string-keyed task map,
  matching the key-tolerance convention this module's accessors follow. Pure;
  no DB access.
  """
  @spec review_or_done?(map()) :: boolean()
  def review_or_done?(task) when is_map(task) do
    not is_nil(fetch_field(task, :review_status)) or
      fetch_field(task, :status) in [:completed, "completed"]
  end

  def review_or_done?(_), do: false

  @doc """
  True when the Completion section should render: the task is review-or-done
  AND carries at least one completion field worth showing (W1962).

  The field set carries over every field the inline guard in
  `KanbanWeb.TaskLive.ViewComponent` requires today — `completed_at`,
  `completed_by`, `completed_by_agent`, `completion_summary` — and widens it
  by one, `completion_notes`, so a task carrying only notes still renders.
  That call site was swapped onto this predicate in W1963, which is also what
  makes the whole Completion section visible during Review and not only once
  the task is Done. An unloaded `completed_by` association reads as absent
  rather than as content, since a not-yet-preloaded assoc is no evidence the
  task was completed by anyone.

  Widening the gate never widens access: this decides section visibility
  inside an already-authorized view, never who may open the task. Pure; no
  DB access.
  """
  @spec completion_panel_visible?(map()) :: boolean()
  def completion_panel_visible?(task) do
    review_or_done?(task) and has_completion_content?(task)
  end

  @doc """
  True when the changed-files section should render: the task is
  review-or-done AND its `changed_files` list is non-empty (W1962).

  `changed_files` defaults to `[]` rather than `nil` in `Kanban.Tasks.Task`,
  so the empty-list check is the meaningful one; `nil` and non-list values
  are still tolerated and read as absent. Pure; no DB access.
  """
  @spec changed_files_panel_visible?(map()) :: boolean()
  def changed_files_panel_visible?(task) do
    review_or_done?(task) and has_changed_files?(task)
  end

  # Only ever reached through the panel predicates above, whose `and`
  # short-circuits on `review_or_done?/1` — so `task` is always a map here.
  defp has_completion_content?(task) do
    Enum.any?(@completion_fields, &completion_field_present?(task, &1))
  end

  defp completion_field_present?(task, field) do
    present_completion_value?(fetch_field(task, field))
  end

  defp present_completion_value?(%Ecto.Association.NotLoaded{}), do: false
  defp present_completion_value?(value), do: not is_nil(value)

  defp has_changed_files?(task), do: present_list?(fetch_field(task, :changed_files))

  # Duplicated from KanbanWeb.ReviewReportHelpers rather than shared: both are
  # private there and still used by the section accessors that stayed behind.
  # See this module's @moduledoc.
  defp fetch_field(task, key) do
    Map.get(task, key) || Map.get(task, Atom.to_string(key))
  end

  defp present_list?(value) when is_list(value), do: value != []
  defp present_list?(_), do: false
end
