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

  # --- Archive reason ----------------------------------------------------

  @doc """
  Gettext word for a `Kanban.Tasks.Task` archive_reason atom.

  Returns the localized "Completed" label for `nil` so legacy archived
  rows (which pre-date the W570 metadata fields and have a nil reason)
  render the same pill copy as explicitly :completed rows.
  """
  def archive_reason_label(:completed), do: gettext("Completed")
  def archive_reason_label(:cancelled), do: gettext("Cancelled")
  def archive_reason_label(:wontdo), do: gettext("Won't do")
  def archive_reason_label(:duplicate), do: gettext("Duplicate")
  def archive_reason_label(:deferred), do: gettext("Deferred")
  def archive_reason_label(_), do: gettext("Completed")

  @doc """
  Soft background CSS var for the archive reason pill.

  Mapping per design:

    * `:completed`               → `var(--st-done-soft)`
    * `:cancelled`               → `var(--st-blocked-soft)`
    * `:wontdo` / `:duplicate`   → `var(--surface-sunken)` (neutral)
    * `:deferred`                → `var(--st-review-soft)`

  Unknown / nil reasons fall back to the completed token so legacy rows
  stay visually consistent with the explicit :completed bucket.
  """
  def archive_reason_soft(:completed), do: "var(--st-done-soft)"
  def archive_reason_soft(:cancelled), do: "var(--st-blocked-soft)"
  def archive_reason_soft(:wontdo), do: "var(--surface-sunken)"
  def archive_reason_soft(:duplicate), do: "var(--surface-sunken)"
  def archive_reason_soft(:deferred), do: "var(--st-review-soft)"
  def archive_reason_soft(_), do: "var(--st-done-soft)"

  @doc "Foreground/ink CSS var for the archive reason pill — see `archive_reason_soft/1`."
  def archive_reason_ink(:completed), do: "var(--st-done)"
  def archive_reason_ink(:cancelled), do: "var(--st-blocked)"
  def archive_reason_ink(:wontdo), do: "var(--ink-3)"
  def archive_reason_ink(:duplicate), do: "var(--ink-3)"
  def archive_reason_ink(:deferred), do: "var(--st-review)"
  def archive_reason_ink(_), do: "var(--st-done)"

  # --- Agent activity event kinds ----------------------------------------

  @doc "Hero icon name for an `Kanban.Agents.Event` kind atom."
  def kind_icon(:claim), do: "hero-arrow-right"
  def kind_icon(:complete), do: "hero-check"
  def kind_icon(:review), do: "hero-check"
  def kind_icon(:create), do: "hero-plus"
  def kind_icon(:unclaim), do: "hero-arrow-uturn-left"
  def kind_icon(_), do: "hero-bolt"

  @doc """
  Foreground/ink CSS var for the icon and label of an event kind.

  Delegates to `status_ink/1` so the kind palette stays in sync with the
  task-status palette: a claim shares the doing tone, a complete shares
  the review tone, a review shares the done tone. Unmapped kinds fall
  back to a neutral ink.
  """
  def kind_tone(:claim), do: status_ink(:in_progress)
  def kind_tone(:complete), do: status_ink(:review)
  def kind_tone(:review), do: status_ink(:completed)
  def kind_tone(_), do: "var(--ink-3)"

  @doc "Gettext label for an event kind."
  def kind_label(:claim), do: gettext("claimed")
  def kind_label(:complete), do: gettext("completed")
  def kind_label(:review), do: gettext("reviewed")
  def kind_label(:create), do: gettext("created")
  def kind_label(:unclaim), do: gettext("unclaimed")
  def kind_label(_), do: ""

  # --- Task type ---------------------------------------------------------

  @doc "Gettext word for a task type atom (returns empty string for unknowns)."
  def type_label(:work), do: gettext("Work")
  def type_label(:defect), do: gettext("Defect")
  def type_label(:goal), do: gettext("Goal")
  def type_label(_), do: ""

  # --- Hook stage labels -------------------------------------------------

  @doc """
  User-visible label for a workflow hook stage name string.

  Stage NAMES like `"before_doing"` are also API config keys. This helper
  returns the user-facing label form; raw config-key strings should not
  pass through this helper when emitted in API responses.
  """
  def hook_stage_label("before_doing"), do: gettext("Before Doing")
  def hook_stage_label("after_doing"), do: gettext("After Doing")
  def hook_stage_label("before_review"), do: gettext("Before Review")
  def hook_stage_label("after_review"), do: gettext("After Review")
  def hook_stage_label(other) when is_binary(other), do: other
  def hook_stage_label(_), do: ""
end
