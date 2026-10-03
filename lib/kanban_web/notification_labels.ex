defmodule KanbanWeb.NotificationLabels do
  @moduledoc """
  Human-readable, translated names for notification event types, for pages
  that talk about a whole category of notifications (the unsubscribe page,
  the preferences page).

  Each clause calls `gettext/1` with a literal so the strings are extracted;
  every type in `Kanban.Notifications.event_types/0` must have a clause.
  """

  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  Returns the translated category name for an event type, e.g.
  `"Review requests"` for `:review_requested`.
  """
  @spec category(atom()) :: String.t()
  def category(:review_requested), do: gettext("Review requests")
  def category(:task_assigned), do: gettext("Task assignments")
  def category(:claim_expired), do: gettext("Expired claims")
  def category(:goal_completed), do: gettext("Completed goals")
  def category(:weekly_digest), do: gettext("Weekly digest")
  def category(:comment_added), do: gettext("Comments")
  def category(:mentioned), do: gettext("Mentions")
  def category(:task_reviewed), do: gettext("Review results")
  def category(:task_unclaimed), do: gettext("Unclaimed tasks")
  def category(:board_access_changed), do: gettext("Board access changes")
  def category(:after_goal_failed), do: gettext("After-goal hook failures")
  def category(:target_status_changed), do: gettext("Delivery target status")
end
