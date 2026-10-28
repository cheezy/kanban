defmodule Kanban.Tasks.AgentWorkflow.Review do
  @moduledoc """
  The review and done transitions of the agent workflow: advancing a reviewed
  task (approved to Done, changes requested or rejected back to Doing), the
  deprecated straight-to-Done path, and the board-write check that authorizes
  either.

  This is the path `Kanban.Reviews` drives inside its own transaction, with its
  telemetry held by `Kanban.Telemetry.AfterCommit` until commit (D371), so
  everything here runs in the caller's process and transaction.

  Not a public entry point. `Kanban.Tasks.AgentWorkflow` owns the public API,
  its defaults and its documentation, and delegates `mark_reviewed/3`,
  `mark_done/2` and `authorized_reviewer?/2` here with every argument; callers
  outside the agent workflow call the facade, never this module.
  """

  alias Kanban.Hooks.Metadata
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow.Support
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.GoalCompletion
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.TaskTelemetry

  require Logger

  @doc false
  def mark_reviewed(task, user, opts) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    cond do
      not authorized_reviewer?(board_id, user) ->
        {:error, :not_authorized}

      task.column.name != "Review" ->
        {:error, :invalid_column}

      is_nil(task.review_status) ->
        {:error, :review_not_performed}

      task.review_status == :approved ->
        move_to_done(task, user, board_id, opts)

      task.review_status in [:changes_requested, :rejected] ->
        move_to_doing(task, user, board_id, opts)

      true ->
        {:error, :invalid_review_status}
    end
  end

  @doc false
  def mark_done(task, user) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    cond do
      not authorized_reviewer?(board_id, user) ->
        {:error, :not_authorized}

      task.column.name != "Review" ->
        {:error, :invalid_column}

      true ->
        do_mark_done(task, user, board_id)
    end
  end

  @doc false
  def authorized_reviewer?(board_id, user), do: Support.board_write_access?(board_id, user)

  defp do_mark_done(task, user, board_id) do
    done_column = Support.get_column_by_name(board_id, "Done")

    result =
      Repo.transaction(fn ->
        next_position = Positioning.get_next_position_locked(done_column)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        changeset =
          task
          |> Ecto.Changeset.change(%{
            status: :completed,
            completed_at: task.completed_at || now,
            column_id: done_column.id,
            position: next_position
          })

        case Repo.update(changeset) do
          {:ok, _updated_task} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, :ok} ->
        {:ok, Support.finalize_completion(task, user, board_id, done_column)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp move_to_done(task, user, board_id, opts) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    agent_name = task.completed_by_agent || "Unknown"
    done_column = Support.get_column_by_name(board_id, "Done")

    case run_move_to_done_transaction(task, user, done_column) do
      {:ok, {last_child_tag, completed_goal_id}} ->
        Support.maybe_schedule_after_goal_grace(task, last_child_tag)
        updated_task = Support.finalize_completion(task, user, board_id, done_column, opts)
        # Held back until commit when Kanban.Reviews runs this in its transaction.
        GoalTelemetry.completed(completed_goal_id, board_id)

        hooks =
          Metadata.build_mark_reviewed_hooks(updated_task, board, agent_name,
            last_child?: last_child_tag == :last_child
          )

        {:ok, updated_task, hooks}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Approved-review transition. Uses `GoalCompletion.finalize_child/2`
  # (W490) — the same context primitive the auto-done /complete path uses
  # — so the after_goal-on-mark_reviewed wiring is not a fork (W491 pitfall
  # repeated here: do not duplicate the after_goal logic). Returns
  # `{:ok, {tag, completed_goal_id}}`, as `run_auto_done_transaction/2` does.
  defp run_move_to_done_transaction(task, user, done_column) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(done_column)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      done_attrs = %{
        status: :completed,
        completed_at: task.completed_at || now,
        reviewed_by_id: user.id,
        column_id: done_column.id,
        position: next_position
      }

      case GoalCompletion.finalize_child(task, done_attrs) do
        {:ok, tag, completed_goal_id} -> {tag, completed_goal_id}
        {:error, _step, changeset, _changes} -> Repo.rollback(changeset)
      end
    end)
  end

  defp move_to_doing(task, user, board_id, opts) do
    doing_column = Support.get_column_by_name(board_id, "Doing")

    result =
      Repo.transaction(fn ->
        next_position = Positioning.get_next_position_locked(doing_column)

        changeset =
          task
          |> Ecto.Changeset.change(%{
            status: :in_progress,
            reviewed_by_id: user.id,
            column_id: doing_column.id,
            position: next_position
          })

        case Repo.update(changeset) do
          {:ok, _updated_task} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, :ok} ->
        updated_task = Queries.get_task_for_view!(task.id)

        Goals.update_parent_goal_position_locked(updated_task)

        Logger.info(
          "Task #{task.id} needs changes (review status: #{task.review_status}) and moved back to Doing by user #{user.id}"
        )

        TaskTelemetry.returned_to_doing(updated_task, user.id, task.review_status)

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_returned_to_doing, updated_task}
        )

        Broadcaster.emit_webhook(updated_task, :task_returned_to_doing, board_id, opts)

        {:ok, updated_task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
