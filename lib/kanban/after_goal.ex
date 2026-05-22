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
  Oban job that fires `grace_window_seconds/0` seconds from now. The
  insert participates in the surrounding `Ecto.Repo.transaction/1` (if
  any), so if the caller's transaction rolls back the job is never
  enqueued.

  Returns `{:ok, %Oban.Job{}}` on success, `{:error, changeset}` on
  insert failure. Callers should not block on this — the protocol
  treats a failed schedule as best-effort.
  """
  @spec schedule_grace_window(Task.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_grace_window(%Task{id: goal_id, type: :goal}) do
    %{goal_id: goal_id}
    |> GraceWorker.new(schedule_in: grace_window_seconds())
    |> Oban.insert()
  end

  @doc """
  Configured grace window in seconds. Defaults to 5 minutes in
  production; tests override to 1 second so timing assertions can run
  inline via Oban.drain_queue/2.
  """
  @spec grace_window_seconds() :: pos_integer()
  def grace_window_seconds do
    Application.get_env(:kanban, :after_goal_grace_window_seconds, 300)
  end
end
