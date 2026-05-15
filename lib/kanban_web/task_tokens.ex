defmodule KanbanWeb.TaskTokens do
  @moduledoc """
  Shared design-token resolvers for the task surface.

  Status, priority, and complexity token mapping was previously duplicated
  across `KanbanWeb.TaskCard`, `KanbanWeb.TaskDetailHeader`, and
  `KanbanWeb.TaskMetadataGrid`. Centralizing it here makes adding a new
  status, priority level, or complexity tier a single-file change instead
  of a three-file rename hunt.

  Every function is pure and side-effect free, so call it from any
  Phoenix component or LiveView without ceremony.
  """
  use Gettext, backend: KanbanWeb.Gettext

  # --- Status tokens -----------------------------------------------------

  @doc "Human label for a task status atom, gettext-wrapped."
  def status_label(:open), do: gettext("Open")
  def status_label(:ready), do: gettext("Ready")
  def status_label(:in_progress), do: gettext("Doing")
  def status_label(:review), do: gettext("Review")
  def status_label(:completed), do: gettext("Done")
  def status_label(:blocked), do: gettext("Blocked")
  def status_label(_), do: gettext("Open")

  @doc "Soft background CSS var for the status pill."
  def status_soft(:open), do: "var(--st-backlog-soft)"
  def status_soft(:ready), do: "var(--st-ready-soft)"
  def status_soft(:in_progress), do: "var(--st-doing-soft)"
  def status_soft(:review), do: "var(--st-review-soft)"
  def status_soft(:completed), do: "var(--st-done-soft)"
  def status_soft(:blocked), do: "var(--st-blocked-soft)"
  def status_soft(_), do: "var(--st-backlog-soft)"

  @doc "Foreground/ink CSS var for the status pill."
  def status_ink(:open), do: "var(--st-backlog)"
  def status_ink(:ready), do: "var(--st-ready)"
  def status_ink(:in_progress), do: "var(--st-doing)"
  def status_ink(:review), do: "var(--st-review)"
  def status_ink(:completed), do: "var(--st-done)"
  def status_ink(:blocked), do: "var(--st-blocked)"
  def status_ink(_), do: "var(--st-backlog)"

  # --- Priority ----------------------------------------------------------

  @doc "CSS var for the priority dot/pill color."
  def priority_color(:critical), do: "var(--pri-critical)"
  def priority_color(:high), do: "var(--pri-high)"
  def priority_color(:medium), do: "var(--pri-medium)"
  def priority_color(:low), do: "var(--pri-low)"
  def priority_color(_), do: "var(--ink-4)"

  @doc "Gettext word for a priority atom (returns empty string for unknowns)."
  def priority_word(:critical), do: gettext("Critical")
  def priority_word(:high), do: gettext("High")
  def priority_word(:medium), do: gettext("Medium")
  def priority_word(:low), do: gettext("Low")
  def priority_word(_), do: ""

  # --- Complexity --------------------------------------------------------

  @doc "Gettext word for a complexity atom (returns empty string for unknowns)."
  def complexity_word(:small), do: gettext("Small")
  def complexity_word(:medium), do: gettext("Medium")
  def complexity_word(:large), do: gettext("Large")
  def complexity_word(_), do: ""
end
