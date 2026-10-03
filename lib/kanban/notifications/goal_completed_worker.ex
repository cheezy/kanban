defmodule Kanban.Notifications.GoalCompletedWorker do
  @moduledoc """
  Sends the goal_completed notification after a goal moves into Done through
  the board's own task moves.

  That move happens inside the caller's transaction (dragging the last child
  into Done), where notifying directly would let a notification failure roll
  back the user's move. `Kanban.Notifications.Events.goal_completed_after_commit/1`
  enqueues this job in the same transaction instead, so it only runs once the
  move has committed. The worker re-reads the goal and does nothing if it is
  gone or no longer complete; the dedupe key makes reruns harmless.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"goal_id" => goal_id}}) do
    case Repo.get(Task, goal_id) do
      nil -> :ok
      goal -> Events.goal_completed(goal)
    end
  end
end
