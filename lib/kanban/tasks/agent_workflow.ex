defmodule Kanban.Tasks.AgentWorkflow do
  @moduledoc """
  Agent task lifecycle operations: claim, complete, review, unclaim, and mark done.

  Handles the workflow for AI agents interacting with tasks, including
  moving tasks between columns and integrating with the hook system.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Hooks
  alias Kanban.Repo
  alias Kanban.Tasks.AgentQueries
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task

  require Logger

  @doc """
  Atomically claims the next available task for an AI agent, or a specific task by identifier.

  Updates the task status to "in_progress", sets claimed_at, claim_expires_at,
  assigned_to, and moves it to the "Doing" column.

  Executes the before_doing hook before moving the task.

  Returns {:ok, task, hook_info} if successful, {:error, reason} if unsuccessful.
  """
  def claim_next_task(
        agent_capabilities \\ [],
        user,
        board_id,
        task_identifier \\ nil,
        agent_name \\ "Unknown"
      ) do
    task =
      if task_identifier do
        AgentQueries.get_specific_task_for_claim(task_identifier, agent_capabilities, board_id)
      else
        AgentQueries.get_next_task(agent_capabilities, board_id)
      end

    case task do
      nil ->
        {:error, :no_tasks_available}

      task ->
        perform_claim(task, user, board_id, agent_name)
    end
  end

  @doc """
  Releases a claimed task back to the "open" status and "Ready" column.

  Clears claimed_at, claim_expires_at, and assigned_to fields.
  Optionally accepts a reason for analytics.

  Returns {:ok, task} if successful, {:error, reason} otherwise.
  """
  def unclaim_task(task, user, reason \\ nil) do
    task = Repo.preload(task, [:column, :assigned_to])

    cond do
      task.status != :in_progress ->
        {:error, :not_claimed}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        ready_column =
          from(c in Column,
            where: c.board_id == ^task.column.board_id and c.name == "Ready"
          )
          |> Repo.one()

        next_position = Positioning.get_next_position(ready_column)

        changeset =
          task
          |> Ecto.Changeset.change(%{
            status: :open,
            claimed_at: nil,
            claim_expires_at: nil,
            assigned_to_id: nil,
            column_id: ready_column.id,
            position: next_position
          })

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])

            if reason do
              Logger.info("Task #{task.id} unclaimed by user #{user.id}. Reason: #{reason}")
            end

            Phoenix.PubSub.broadcast(
              Kanban.PubSub,
              "board:#{task.column.board_id}",
              {:task_updated, updated_task}
            )

            {:ok, updated_task}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Completes a task by moving it to the Review column with completion summary.

  Stores completion details (summary, actual complexity, files changed, time spent)
  and moves the task from Doing to Review. Status remains "in_progress" - final
  completion (moving to Done with status="completed") is handled by mark_done.
  """
  # credo:disable-for-lines:128
  def complete_task(task, user, params, agent_name \\ "Unknown") do
    task = Repo.preload(task, [:column, :assigned_to])
    board_id = task.column.board_id
    board = Repo.get!(Kanban.Boards.Board, board_id)

    cond do
      task.status not in [:in_progress, :blocked] ->
        {:error, :invalid_status}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        review_column =
          from(c in Column,
            where: c.board_id == ^board_id and c.name == "Review"
          )
          |> Repo.one()

        next_position = Positioning.get_next_position(review_column)

        changeset =
          task
          |> Ecto.Changeset.cast(params, [
            :completion_summary,
            :actual_complexity,
            :actual_files_changed,
            :time_spent_minutes,
            :completed_by_agent
          ])
          |> Ecto.Changeset.put_change(:column_id, review_column.id)
          |> Ecto.Changeset.put_change(:position, next_position)
          |> Ecto.Changeset.put_change(:completed_by_id, user.id)
          |> Ecto.Changeset.validate_required([
            :completion_summary,
            :actual_complexity,
            :actual_files_changed,
            :time_spent_minutes
          ])
          |> Ecto.Changeset.validate_inclusion(:actual_complexity, [:small, :medium, :large])
          |> Ecto.Changeset.validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            handle_successful_completion(
              task,
              updated_task,
              user,
              board,
              review_column,
              params,
              agent_name
            )

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Processes a reviewed task based on its review status.

  If review_status is "approved", moves the task from Review to Done column,
  sets status to :completed, and sets completed_at timestamp.

  If review_status is "changes_requested" or "rejected", moves the task from
  Review back to Doing column and keeps status as :in_progress.

  Only tasks in the Review column can be marked as reviewed.
  """
  def mark_reviewed(task, user) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    cond do
      task.column.name != "Review" ->
        {:error, :invalid_column}

      is_nil(task.review_status) ->
        {:error, :review_not_performed}

      task.review_status == :approved ->
        move_to_done(task, user, board_id)

      task.review_status in [:changes_requested, :rejected] ->
        move_to_doing(task, user, board_id)

      true ->
        {:error, :invalid_review_status}
    end
  end

  @doc """
  Marks a task as done by moving it from Review to Done column.

  DEPRECATED: Use mark_reviewed/2 instead.

  Sets status to :completed, sets completed_at timestamp,
  and moves the task to the Done column. This is the final step in the task workflow.

  Only tasks in the Review column can be marked as done.
  """
  def mark_done(task, user) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    if task.column.name != "Review" do
      {:error, :invalid_column}
    else
      done_column =
        from(c in Column,
          where: c.board_id == ^board_id and c.name == "Done"
        )
        |> Repo.one()

      next_position = Positioning.get_next_position(done_column)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        task
        |> Ecto.Changeset.change(%{
          status: :completed,
          completed_at: now,
          column_id: done_column.id,
          position: next_position
        })

      case Repo.update(changeset) do
        {:ok, _updated_task} ->
          updated_task = Queries.get_task_for_view!(task.id)

          Logger.info("Task #{task.id} marked as done by user #{user.id}")

          :telemetry.execute(
            [:kanban, :task, :completed],
            %{task_id: updated_task.id},
            %{completed_by: user.id}
          )

          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{board_id}",
            {:task_completed, updated_task}
          )

          Dependencies.unblock_dependent_tasks(updated_task.identifier, board_id)

          {:ok, updated_task}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Private functions

  defp perform_claim(task, user, board_id, agent_name) do
    board = Repo.get!(Kanban.Boards.Board, board_id)

    doing_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Doing"
      )
      |> Repo.one()

    now = DateTime.utc_now()
    expires_at = now |> DateTime.add(60 * 60, :second)
    next_position = Positioning.get_next_position(doing_column)

    update_query =
      from(t in Task,
        where: t.id == ^task.id,
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now)
      )

    case Repo.update_all(
           update_query,
           set: [
             status: :in_progress,
             claimed_at: now,
             claim_expires_at: expires_at,
             assigned_to_id: user.id,
             column_id: doing_column.id,
             position: next_position,
             updated_at: now
           ]
         ) do
      {1, _} ->
        updated_task = Queries.get_task_for_view!(task.id)

        Goals.update_parent_goal_position(updated_task, task.column_id, doing_column.id)

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_updated, updated_task}
        )

        {:ok, hook_info} = Hooks.get_hook_info(updated_task, board, "before_doing", agent_name)
        {:ok, updated_task, hook_info}

      {0, _} ->
        {:error, :no_tasks_available}
    end
  end

  defp handle_successful_completion(
         task,
         updated_task,
         user,
         board,
         review_column,
         params,
         agent_name
       ) do
    board_id = board.id
    updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])
    old_column_id = task.column_id

    Goals.update_parent_goal_position(updated_task, old_column_id, review_column.id)

    Logger.info(
      "Task #{task.id} completed and moved to Review by user #{user.id}. Time spent: #{params["time_spent_minutes"]} minutes"
    )

    :telemetry.execute(
      [:kanban, :task, :moved_to_review],
      %{task_id: updated_task.id, time_spent_minutes: params["time_spent_minutes"]},
      %{completed_by_id: user.id}
    )

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {:task_moved_to_review, updated_task}
    )

    {:ok, after_doing_hook} =
      Hooks.get_hook_info(updated_task, board, "after_doing", agent_name)

    {:ok, before_review_hook} =
      Hooks.get_hook_info(updated_task, board, "before_review", agent_name)

    if updated_task.needs_review do
      hooks = [after_doing_hook, before_review_hook]
      {:ok, updated_task, hooks}
    else
      auto_move_to_done(
        updated_task,
        user,
        board,
        review_column,
        after_doing_hook,
        before_review_hook,
        agent_name
      )
    end
  end

  defp auto_move_to_done(
         updated_task,
         user,
         board,
         review_column,
         after_doing_hook,
         before_review_hook,
         agent_name
       ) do
    board_id = board.id

    done_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Done"
      )
      |> Repo.one()

    next_position = Positioning.get_next_position(done_column)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    done_changeset =
      updated_task
      |> Ecto.Changeset.change(%{
        status: :completed,
        completed_at: now,
        column_id: done_column.id,
        position: next_position
      })

    case Repo.update(done_changeset) do
      {:ok, _final_task} ->
        final_task = Queries.get_task_for_view!(updated_task.id)

        Goals.update_parent_goal_position(final_task, review_column.id, done_column.id)

        Logger.info("Task #{updated_task.id} auto-moved to Done (needs_review=false)")

        :telemetry.execute(
          [:kanban, :task, :completed],
          %{task_id: final_task.id},
          %{completed_by: user.id}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_completed, final_task}
        )

        Dependencies.unblock_dependent_tasks(final_task.identifier, board_id)

        {:ok, after_review_hook} =
          Hooks.get_hook_info(final_task, board, "after_review", agent_name)

        hooks = [after_doing_hook, before_review_hook, after_review_hook]

        {:ok, final_task, hooks}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp move_to_done(task, user, board_id) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    agent_name = task.completed_by_agent || "Unknown"

    done_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Done"
      )
      |> Repo.one()

    next_position = Positioning.get_next_position(done_column)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      task
      |> Ecto.Changeset.change(%{
        status: :completed,
        completed_at: now,
        reviewed_by_id: user.id,
        column_id: done_column.id,
        position: next_position
      })

    case Repo.update(changeset) do
      {:ok, _updated_task} ->
        updated_task = Queries.get_task_for_view!(task.id)
        old_column_id = task.column_id

        Goals.update_parent_goal_position(updated_task, old_column_id, done_column.id)

        Logger.info("Task #{task.id} approved and moved to Done by user #{user.id}")

        :telemetry.execute(
          [:kanban, :task, :completed],
          %{task_id: updated_task.id},
          %{completed_by: user.id}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_completed, updated_task}
        )

        Dependencies.unblock_dependent_tasks(updated_task.identifier, board_id)

        {:ok, after_review_hook} =
          Hooks.get_hook_info(updated_task, board, "after_review", agent_name)

        {:ok, updated_task, after_review_hook}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp move_to_doing(task, user, board_id) do
    doing_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Doing"
      )
      |> Repo.one()

    next_position = Positioning.get_next_position(doing_column)

    changeset =
      task
      |> Ecto.Changeset.change(%{
        status: :in_progress,
        reviewed_by_id: user.id,
        column_id: doing_column.id,
        position: next_position
      })

    case Repo.update(changeset) do
      {:ok, _updated_task} ->
        updated_task = Queries.get_task_for_view!(task.id)
        old_column_id = task.column_id

        Goals.update_parent_goal_position(updated_task, old_column_id, doing_column.id)

        Logger.info(
          "Task #{task.id} needs changes (review status: #{task.review_status}) and moved back to Doing by user #{user.id}"
        )

        :telemetry.execute(
          [:kanban, :task, :returned_to_doing],
          %{task_id: updated_task.id},
          %{reviewed_by: user.id, review_status: task.review_status}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_returned_to_doing, updated_task}
        )

        {:ok, updated_task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
