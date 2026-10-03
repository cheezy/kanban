defmodule KanbanWeb.NotificationLabels do
  @moduledoc """
  Human-readable, translated wording for notifications, shared by the email,
  the inbox, the unsubscribe page and the preferences page.

  `category/1` names a whole category of notifications and `description/1`
  says when it is sent (the preferences page shows both); `detail/1` words the
  event-specific metadata stored on one notification, so it is translated at
  render time rather than stored as text.

  Each clause calls `gettext/1` with a literal so the strings are extracted;
  every type in `Kanban.Notifications.event_types/0` must have a `category/1`
  clause.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Notifications.Notification

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

  @doc """
  Returns a short translated sentence saying when an event type is sent,
  shown under its category on the preferences page.
  """
  @spec description(atom()) :: String.t()
  def description(:review_requested),
    do: gettext("A task you can review is waiting in the review queue.")

  def description(:task_reviewed),
    do: gettext("A reviewer approved or requested changes on your task.")

  def description(:task_assigned), do: gettext("Someone assigns a task to you.")

  def description(:task_unclaimed),
    do: gettext("An agent releases a task it had claimed for you.")

  def description(:claim_expired),
    do: gettext("An agent's claim on your task expires before it is finished.")

  def description(:goal_completed), do: gettext("A goal you created or own reaches Done.")

  def description(:after_goal_failed),
    do: gettext("A goal's after_goal hook fails on the agent's machine.")

  def description(:target_status_changed),
    do: gettext("A delivery target you follow changes status.")

  def description(:board_access_changed),
    do: gettext("You are added to or removed from a board, or your access changes.")

  def description(:comment_added), do: gettext("Someone comments on your task.")
  def description(:mentioned), do: gettext("Someone mentions you in a comment.")

  def description(:weekly_digest),
    do: gettext("A weekly summary of activity on your boards.")

  @doc """
  Returns the translated detail line for a notification's metadata, or `nil`
  when its event type stores none. Today only `:after_goal_failed` does: its
  exit code and, when known, the duration in milliseconds.
  """
  @spec detail(Notification.t()) :: String.t() | nil
  def detail(%Notification{
        event_type: :after_goal_failed,
        metadata: %{"exit_code" => code, "duration_ms" => ms}
      })
      when is_integer(code) and is_integer(ms),
      do: gettext("Exit code %{code} after %{ms} ms", code: code, ms: ms)

  def detail(%Notification{event_type: :after_goal_failed, metadata: %{"exit_code" => code}})
      when is_integer(code),
      do: gettext("Exit code %{code}", code: code)

  def detail(_notification), do: nil
end
