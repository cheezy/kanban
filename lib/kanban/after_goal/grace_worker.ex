defmodule Kanban.AfterGoal.GraceWorker do
  @moduledoc """
  Oban worker for the after_goal grace-window back-compat fallback (W493).

  When the last child of a goal completes,
  `Kanban.Tasks.GoalCompletion.finalize_child_and_check_goal_complete/2`
  flips the parent goal's `after_goal_status` to `:pending` and
  `Kanban.AfterGoal` schedules this worker to fire after the configured
  grace window. If the agent reports `after_goal` (success or failure)
  before the window expires, the PATCH endpoint flips status to
  `:succeeded` and this worker's run becomes a no-op. If the agent
  never reports — the case the spec calls "plugin predates after_goal"
  — this worker fires after the window, treats the absence as success,
  appends a synthetic attempt to the audit log, and promotes the goal
  to its Done column.

  Idempotent: when status is already `:succeeded` (because the agent
  beat the worker to the punch), the worker returns `:ok` without
  touching the goal. When the goal cannot be found (deleted between
  scheduling and execution), the worker also returns `:ok` so Oban does
  not retry forever.
  """

  use Oban.Worker,
    queue: :after_goal_grace,
    max_attempts: 3

  alias Kanban.Repo
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Task

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"goal_id" => goal_id}}) do
    case Repo.get(Task, goal_id) do
      nil ->
        Logger.info("after_goal grace worker: goal #{goal_id} not found, skipping")
        :ok

      %Task{after_goal_status: :succeeded} ->
        # Agent beat the grace window — nothing to do.
        :ok

      %Task{after_goal_status: :pending} = goal ->
        promote_via_grace(goal)

      %Task{after_goal_status: nil} = goal ->
        # Should not happen — scheduling only enqueues this worker after
        # flipping :pending. Log and treat as no-op rather than crash.
        Logger.warning(
          "after_goal grace worker: goal #{goal.id} has nil after_goal_status; skipping"
        )

        :ok
    end
  end

  defp promote_via_grace(goal) do
    synthetic_attempt = %{
      "exit_code" => 0,
      "output" => "grace window expired (no agent report received)",
      "duration_ms" => 0,
      "source" => "after_goal_grace_worker"
    }

    case Goals.mark_after_goal_succeeded_and_promote(goal, synthetic_attempt) do
      {:ok, _updated_goal} ->
        Logger.info("after_goal grace window expired for goal #{goal.id}; promoted to Done")
        :ok

      {:error, reason} ->
        Logger.warning(
          "after_goal grace worker: promotion failed for goal #{goal.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
