defmodule Kanban.AfterGoal do
  @moduledoc """
  Coordination surface for the after_goal hook protocol (W493 / G113).

  The protocol gates a goal's transition to Done on an agent-reported
  `after_goal` exit code. When the last child of a goal completes the
  parent goal is flipped to `:pending` (in the same transaction as the
  child completion — see `Kanban.Tasks.GoalCompletion`) and a one-shot
  Oban job is scheduled to act as the back-compat fallback for plugins
  that don't speak after_goal: if no agent report arrives within the
  configured grace window, the worker promotes the goal to Done with a
  synthetic success result.

  The actual promotion logic lives in `Kanban.Tasks.Goals`
  (`mark_after_goal_succeeded_and_promote/2` and
  `record_after_goal_failure/2`). This module owns the scheduling
  policy (which queue, what window, how to read the configured window
  at runtime).
  """

  alias Kanban.AfterGoal.GraceWorker
  alias Kanban.Tasks.Task

  @doc """
  Schedule the back-compat grace-window job for `goal`. Inserts an
  Oban job that fires `grace_window_ms/0` milliseconds from now. The
  insert participates in the surrounding `Ecto.Repo.transaction/1` (if
  any), so if the caller's transaction rolls back the job is never
  enqueued.

  Sub-second precision is required because the production window is
  currently 500ms while the agent-side `after_goal` wiring is in
  flight; Oban's integer `schedule_in:` would round down to zero, so
  we pass an explicit `scheduled_at:` instead.

  Returns `{:ok, %Oban.Job{}}` on success, `{:error, changeset}` on
  insert failure. Callers should not block on this — the protocol
  treats a failed schedule as best-effort.
  """
  @spec schedule_grace_window(Task.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_grace_window(%Task{id: goal_id, type: :goal}) do
    scheduled_at = DateTime.utc_now() |> DateTime.add(grace_window_ms(), :millisecond)

    %{goal_id: goal_id}
    |> GraceWorker.new(scheduled_at: scheduled_at)
    |> Oban.insert()
  end

  @doc """
  Configured grace window in milliseconds. Defaults to 500ms while
  the agent-side after_goal client wiring is being built — every
  last-child completion will be promoted by the grace worker rather
  than by an agent PATCH. The default will be raised back toward the
  pre-G113 5-minute window once stride-hook.sh, hook-bridge, and the
  workflow skill all know how to call `PATCH /api/tasks/:id/after_goal`.

  Tests override to 1ms so `Oban.drain_queue(with_scheduled: true)`
  picks the job up on the first pass.
  """
  @spec grace_window_ms() :: pos_integer()
  def grace_window_ms do
    Application.get_env(:kanban, :after_goal_grace_window_ms, 500)
  end
end
