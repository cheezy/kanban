defmodule Kanban.Tasks.AgentWorkflow.Support do
  @moduledoc """
  Helpers shared by the claim, completion and review concerns of
  `Kanban.Tasks.AgentWorkflow`.

  Each function here is called from more than one lifecycle path — board-write
  authorization, column lookup by name, the post-completion side effects, and
  the after_goal grace-window scheduling — so it lives in one place rather than
  being copied into each concern as the facade is split up (W2355).

  This module is **not** a public entry point. Its functions are public only so
  the `AgentWorkflow` modules can call them, and are marked `@doc false`. Callers
  outside the agent workflow must go through `Kanban.Tasks.AgentWorkflow`, whose
  functions perform the authorization checks.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AfterGoal
  alias Kanban.Boards
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

  require Logger

  # Live board-write authorization: the user must currently be a member of the
  # board with at least :modify access (owners included). Read-only members and
  # non-members cannot claim, complete, or advance tasks. This is re-checked on
  # every claim/complete/review so a member who was downgraded to :read_only or
  # removed from the board cannot keep progressing work with a still-valid
  # board-bound API token (W1430).
  @doc false
  def board_write_access?(board_id, %{id: user_id}) do
    Boards.get_user_access(board_id, user_id) in [:owner, :modify]
  end

  @doc false
  def get_column_by_name(board_id, name) do
    from(c in Column, where: c.board_id == ^board_id and c.name == ^name)
    |> Repo.one()
  end

  @doc false
  def finalize_completion(task, user, board_id, _done_column, opts \\ []) do
    updated_task = Queries.get_task_for_view!(task.id)

    Goals.update_parent_goal_position_locked(updated_task)

    Logger.info("Task #{task.id} completed and moved to Done by user #{user.id}")

    TaskTelemetry.completed(updated_task, user.id)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {:task_completed, updated_task}
    )

    # Also notify the board-scoped "agents:#{board_id}" topic so AgentsLive
    # (/agents) refreshes live on completion for viewers of this board. The
    # board-topic broadcast above stays untouched so the board LiveView contract
    # is unchanged and the feed is not double-fired.
    Broadcaster.broadcast_agent_event(updated_task, :task_completed, board_id)
    Broadcaster.emit_webhook(updated_task, :task_completed, board_id, opts)

    Dependencies.unblock_dependent_tasks(updated_task.identifier, board_id)

    updated_task
  end

  # Schedules the back-compat Oban grace job whenever this completion
  # was the final child of its parent goal. The job's role is to
  # promote the goal to Done after a grace window if the agent never
  # reports after_goal (e.g., older plugin versions that don't speak
  # the protocol). A faster agent report (via PATCH
  # /api/tasks/:goal_id/after_goal) makes the grace job a no-op.
  @doc false
  def maybe_schedule_after_goal_grace(%Task{parent_id: nil}, _tag), do: :ok
  def maybe_schedule_after_goal_grace(_task, :not_last_child), do: :ok

  def maybe_schedule_after_goal_grace(%Task{parent_id: parent_id}, :last_child) do
    case Repo.get(Task, parent_id) do
      %Task{type: :goal} = goal ->
        # Best-effort — a scheduling failure should not break the
        # child completion response. The error_tracker integration will
        # surface persistent Oban failures.
        case AfterGoal.schedule_grace_window(goal) do
          {:ok, _job} -> :ok
          {:error, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end
end
