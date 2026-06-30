defmodule Kanban.Tasks.AgentWorkflow do
  @moduledoc """
  Agent task lifecycle operations: claim, complete, review, unclaim, and mark done.

  Handles the workflow for AI agents interacting with tasks, including
  moving tasks between columns and integrating with the hook system.
  """

  import Ecto.Query, warn: false

  alias Kanban.AfterGoal
  alias Kanban.Boards
  alias Kanban.Columns.Column
  alias Kanban.Hooks
  alias Kanban.Hooks.Metadata
  alias Kanban.Repo
  alias Kanban.Tasks.AgentQueries
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.CompletionValidation
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.GoalCompletion
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
    if board_write_access?(board_id, user) do
      do_claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name)
    else
      {:error, :not_authorized}
    end
  end

  defp do_claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name) do
    task =
      if task_identifier do
        AgentQueries.get_specific_task_for_claim(
          task_identifier,
          agent_capabilities,
          board_id,
          user.id
        )
      else
        AgentQueries.get_next_task(agent_capabilities, board_id, user.id)
      end

    case task do
      nil ->
        if task_identifier do
          claim_failure_for_specific_task(task_identifier, board_id, user.id)
        else
          {:error, :no_tasks_available}
        end

      task ->
        perform_claim(task, user, board_id, agent_name)
    end
  end

  # When a specific identifier is requested but the assignment-aware query
  # returns nil, distinguish "this task is assigned to a different user" from
  # "this task does not exist / is not eligible for any agent". The unfiltered
  # lookup tells us if the row exists and who owns it.
  #
  # Capabilities are intentionally passed as `[]` here so this disambiguation
  # step never hides an assignment conflict behind a capability filter — we
  # are answering "is this row assigned to someone else?", not "is the caller
  # capable of claiming it?".
  defp claim_failure_for_specific_task(task_identifier, board_id, user_id) do
    case AgentQueries.get_specific_task_for_claim(task_identifier, [], board_id) do
      %{assigned_to_id: assigned_id} when not is_nil(assigned_id) and assigned_id != user_id ->
        {:error, :assigned_to_other_user}

      _ ->
        {:error, :no_tasks_available}
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
        ready_column = get_column_by_name(task.column.board_id, "Ready")
        result = perform_unclaim_transaction(task, ready_column)
        handle_unclaim_result(result, task, user, reason)
    end
  end

  defp perform_unclaim_transaction(task, ready_column) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(ready_column)

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
        {:ok, updated_task} -> updated_task
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp handle_unclaim_result({:ok, updated_task}, task, user, reason) do
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
  end

  defp handle_unclaim_result({:error, changeset}, _task, _user, _reason) do
    {:error, changeset}
  end

  @doc """
  Completes a task by moving it to the Review column with completion summary.

  Stores completion details (summary, actual complexity, files changed, time spent)
  and moves the task from Doing to Review. Status remains "in_progress" - final
  completion (moving to Done with status="completed") is handled by mark_done.
  """
  def complete_task(task, user, params, agent_name \\ "Unknown") do
    task = Repo.preload(task, [:column, :assigned_to])
    board_id = task.column.board_id
    board = Repo.get!(Kanban.Boards.Board, board_id)

    cond do
      task.status not in [:in_progress, :blocked] ->
        {:error, :invalid_status}

      not board_write_access?(board_id, user) ->
        # Catches the stale-permission case: the user is still the assignee but
        # has since been downgraded to :read_only or removed from the board.
        {:error, :not_authorized}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        do_complete_task(task, user, params, board, board_id, agent_name)
    end
  end

  defp do_complete_task(task, user, params, board, board_id, agent_name) do
    review_column = get_column_by_name(board_id, "Review")

    case move_to_review(task, user, params, review_column) do
      {:ok, updated_task} ->
        handle_successful_completion(
          task,
          updated_task,
          user,
          %{board: board, review: review_column},
          params,
          agent_name
        )

      {:error, changeset} ->
        {:error, changeset}
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
      not authorized_reviewer?(board_id, user) ->
        {:error, :not_authorized}

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

    cond do
      not authorized_reviewer?(board_id, user) ->
        {:error, :not_authorized}

      task.column.name != "Review" ->
        {:error, :invalid_column}

      true ->
        do_mark_done(task, user, board_id)
    end
  end

  defp do_mark_done(task, user, board_id) do
    done_column = get_column_by_name(board_id, "Done")

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
        {:ok, finalize_completion(task, user, board_id, done_column)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp authorized_reviewer?(board_id, user), do: board_write_access?(board_id, user)

  # Live board-write authorization: the user must currently be a member of the
  # board with at least :modify access (owners included). Read-only members and
  # non-members cannot claim, complete, or advance tasks. This is re-checked on
  # every claim/complete/review so a member who was downgraded to :read_only or
  # removed from the board cannot keep progressing work with a still-valid
  # board-bound API token (W1430).
  defp board_write_access?(board_id, %{id: user_id}) do
    Boards.get_user_access(board_id, user_id) in [:owner, :modify]
  end

  # Private functions

  defp get_column_by_name(board_id, name) do
    from(c in Column, where: c.board_id == ^board_id and c.name == ^name)
    |> Repo.one()
  end

  defp finalize_completion(task, user, board_id, done_column) do
    updated_task = Queries.get_task_for_view!(task.id)
    old_column_id = task.column_id

    Goals.update_parent_goal_position(updated_task, old_column_id, done_column.id)

    Logger.info("Task #{task.id} completed and moved to Done by user #{user.id}")

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

    # Also notify the shared "agents" topic so AgentsLive (/agents) refreshes
    # live on completion. The board-topic broadcast above stays untouched so the
    # board LiveView contract is unchanged and the feed is not double-fired.
    Broadcaster.broadcast_agent_event(updated_task, :task_completed)

    Dependencies.unblock_dependent_tasks(updated_task.identifier, board_id)

    updated_task
  end

  defp perform_claim(task, user, board_id, agent_name) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    doing_column = get_column_by_name(board_id, "Doing")
    now = DateTime.utc_now()
    expires_at = now |> DateTime.add(60 * 60, :second)

    result = run_claim_transaction(task, user, doing_column, now, expires_at)
    handle_claim_result(result, task, board, board_id, doing_column, agent_name)
  end

  defp run_claim_transaction(task, user, doing_column, now, expires_at) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(doing_column)

      # The atomic update_query carries the assignment predicate so that a
      # concurrent claim attempt by a different user cannot race past an
      # Elixir-level guard while the row is still :open. If 0 rows update,
      # disambiguate the failure by inspecting the row inside the same
      # transaction.
      update_query =
        from(t in Task,
          where: t.id == ^task.id,
          where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
          where: is_nil(t.assigned_to_id) or t.assigned_to_id == ^user.id
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
          :claimed

        {0, _} ->
          Repo.rollback(claim_zero_row_reason(task.id, user.id))
      end
    end)
  end

  defp handle_claim_result({:ok, :claimed}, task, board, board_id, doing_column, agent_name) do
    updated_task = Queries.get_task_for_view!(task.id)

    Goals.update_parent_goal_position(updated_task, task.column_id, doing_column.id)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {:task_updated, updated_task}
    )

    # The board-topic broadcast above only reaches board LiveViews. The agents
    # surface subscribes to the shared "agents" topic, so notify it directly —
    # mirroring the completion path — otherwise a claim never reaches the agent
    # activity feed live and only appears after some later event triggers a
    # refresh (or a manual reload).
    Broadcaster.broadcast_agent_event(updated_task, :task_claimed)

    {:ok, hook_info} = Hooks.get_hook_info(updated_task, board, "before_doing", agent_name)
    {:ok, updated_task, hook_info}
  end

  defp handle_claim_result({:error, :no_tasks_available}, _task, _board, _board_id, _col, _agent),
    do: {:error, :no_tasks_available}

  defp handle_claim_result(
         {:error, :assigned_to_other_user},
         _task,
         _board,
         _board_id,
         _col,
         _agent
       ),
       do: {:error, :assigned_to_other_user}

  # After the atomic update_all returns 0 rows, inspect the live row to decide
  # whether the failure was caused by a competing claim/state change
  # (:no_tasks_available) or by a non-matching assignment
  # (:assigned_to_other_user).
  defp claim_zero_row_reason(task_id, user_id) do
    case Repo.get(Task, task_id) do
      %Task{assigned_to_id: assigned_id}
      when not is_nil(assigned_id) and assigned_id != user_id ->
        :assigned_to_other_user

      _ ->
        :no_tasks_available
    end
  end

  defp handle_successful_completion(task, updated_task, user, columns, params, agent_name) do
    %{board: board, review: review_column} = columns
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

    if updated_task.needs_review do
      # Moving to Review is the terminal step for needs_review tasks (no
      # finalize_completion call follows), so emit the agents-topic event here
      # to keep /agents live. The auto-Done path emits it via finalize_completion.
      Broadcaster.broadcast_agent_event(updated_task, :task_completed)

      hooks =
        Metadata.build_completion_hooks(updated_task, board, agent_name, needs_review?: true)

      {:ok, updated_task, hooks}
    else
      auto_move_to_done(updated_task, user, board, agent_name)
    end
  end

  defp auto_move_to_done(updated_task, user, board, agent_name) do
    board_id = board.id
    done_column = get_column_by_name(board_id, "Done")

    case run_auto_done_transaction(updated_task, done_column) do
      {:ok, last_child_tag} when last_child_tag in [:last_child, :not_last_child] ->
        maybe_schedule_after_goal_grace(updated_task, last_child_tag)
        final_task = finalize_completion(updated_task, user, board_id, done_column)

        hooks =
          Metadata.build_completion_hooks(final_task, board, agent_name,
            last_child?: last_child_tag == :last_child
          )

        {:ok, final_task, hooks}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Auto-done transaction. Uses `GoalCompletion.finalize_child_and_check_goal_complete/2`
  # so the child Done write and the parent-goal "is-this-the-last-child"
  # check live in one transactionally-locked unit (W490) — the controller
  # never duplicates that check. Returns `{:ok, :last_child}` or
  # `{:ok, :not_last_child}` so callers can decide whether to append the
  # after_goal hook to the response payload (W491).
  defp run_auto_done_transaction(updated_task, done_column) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(done_column)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      done_attrs = %{
        status: :completed,
        completed_at: updated_task.completed_at || now,
        column_id: done_column.id,
        position: next_position
      }

      case GoalCompletion.finalize_child_and_check_goal_complete(updated_task, done_attrs) do
        {:ok, tag} when tag in [:last_child, :not_last_child] -> tag
        {:error, _step, changeset, _changes} -> Repo.rollback(changeset)
      end
    end)
  end

  # A re-completion after a changes-requested/rejected round must re-enter
  # the review queue, which only lists tasks without a review verdict — clear
  # the previous round's verdict and reviewer metadata.
  defp reset_review_round(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:review_status, nil)
    |> Ecto.Changeset.put_change(:reviewed_at, nil)
    |> Ecto.Changeset.put_change(:reviewed_by_id, nil)
  end

  defp move_to_review(task, user, params, review_column) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(review_column)
      changeset = completion_changeset(task, user, params, review_column, next_position)

      case Repo.update(changeset) do
        {:ok, updated_task} -> updated_task
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # `:changed_files` is owned by `PUT /api/tasks/:id/changed_files`
  # (hook-uploaded); do not cast here, even if the legacy completion body
  # includes it. The PUT endpoint is the only writer.
  defp completion_changeset(task, user, params, review_column, next_position) do
    task
    |> Ecto.Changeset.cast(params, [
      :completion_summary,
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes,
      :completed_by_agent,
      :review_report,
      :workflow_steps,
      :explorer_result,
      :reviewer_result
    ])
    |> Ecto.Changeset.put_change(:column_id, review_column.id)
    |> Ecto.Changeset.put_change(:position, next_position)
    |> Ecto.Changeset.put_change(:completed_by_id, user.id)
    |> reset_review_round()
    |> Ecto.Changeset.validate_required([
      :completion_summary,
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes
    ])
    |> Ecto.Changeset.validate_inclusion(:actual_complexity, [:small, :medium, :large])
    |> Ecto.Changeset.validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)
    |> validate_explorer_result_payload(params)
    |> validate_reviewer_result_payload(params)
    |> validate_workflow_steps_shape(params)
  end

  # Belt-and-suspenders schema-layer validation for the JSON blobs that the API
  # accepts. CompletionResultGate already enforces these at the HTTP boundary
  # when :strict_completion_validation is on, but here we enforce them
  # unconditionally so internal callers and non-strict deployments cannot
  # persist malformed blobs (W398).
  defp validate_explorer_result_payload(changeset, params) do
    case Map.get(params, "explorer_result") do
      nil ->
        changeset

      value ->
        case CompletionValidation.validate_explorer_result(value) do
          {:ok, _} ->
            changeset

          {:error, errors} ->
            Enum.reduce(errors, changeset, fn {_field, message}, acc ->
              Ecto.Changeset.add_error(acc, :explorer_result, message)
            end)
        end
    end
  end

  defp validate_reviewer_result_payload(changeset, params) do
    case Map.get(params, "reviewer_result") do
      nil ->
        changeset

      value ->
        case CompletionValidation.validate_reviewer_result(value) do
          {:ok, _} ->
            changeset

          {:error, errors} ->
            Enum.reduce(errors, changeset, fn {_field, message}, acc ->
              Ecto.Changeset.add_error(acc, :reviewer_result, message)
            end)
        end
    end
  end

  # workflow_steps is {:array, :map} in the schema — Ecto's cast handles the
  # type, but we add an explicit shape check so non-list input or list elements
  # missing the canonical step fields are rejected before persistence.
  defp validate_workflow_steps_shape(changeset, params) do
    case Map.get(params, "workflow_steps") do
      nil ->
        changeset

      value when is_list(value) ->
        if Enum.all?(value, &valid_workflow_step?/1) do
          changeset
        else
          Ecto.Changeset.add_error(
            changeset,
            :workflow_steps,
            "each entry must be a map with a 'name' key and either duration_ms (when dispatched) or reason (when skipped)"
          )
        end

      _ ->
        Ecto.Changeset.add_error(changeset, :workflow_steps, "must be a list of step maps")
    end
  end

  defp valid_workflow_step?(%{} = step) do
    name = fetch_step_field(step, "name")
    dispatched = fetch_step_field(step, "dispatched")

    cond do
      not is_binary(name) -> false
      dispatched == true -> is_integer(fetch_step_field(step, "duration_ms"))
      dispatched == false -> is_binary(fetch_step_field(step, "reason"))
      true -> false
    end
  end

  defp valid_workflow_step?(_), do: false

  defp fetch_step_field(step, key) do
    case Map.fetch(step, key) do
      {:ok, value} -> value
      :error -> Map.get(step, safe_existing_atom(key))
    end
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp move_to_done(task, user, board_id) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    agent_name = task.completed_by_agent || "Unknown"
    done_column = get_column_by_name(board_id, "Done")

    case run_move_to_done_transaction(task, user, done_column) do
      {:ok, last_child_tag} when last_child_tag in [:last_child, :not_last_child] ->
        maybe_schedule_after_goal_grace(task, last_child_tag)
        updated_task = finalize_completion(task, user, board_id, done_column)

        hooks =
          Metadata.build_mark_reviewed_hooks(updated_task, board, agent_name,
            last_child?: last_child_tag == :last_child
          )

        {:ok, updated_task, hooks}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Schedules the back-compat Oban grace job whenever this completion
  # was the final child of its parent goal. The job's role is to
  # promote the goal to Done after a grace window if the agent never
  # reports after_goal (e.g., older plugin versions that don't speak
  # the protocol). A faster agent report (via PATCH
  # /api/tasks/:goal_id/after_goal) makes the grace job a no-op.
  defp maybe_schedule_after_goal_grace(%Task{parent_id: nil}, _tag), do: :ok
  defp maybe_schedule_after_goal_grace(_task, :not_last_child), do: :ok

  defp maybe_schedule_after_goal_grace(%Task{parent_id: parent_id}, :last_child) do
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

  # Approved-review transition. Uses `GoalCompletion.finalize_child_and_check_goal_complete/2`
  # (W490) — the same context primitive the auto-done /complete path uses
  # — so the after_goal-on-mark_reviewed wiring is not a fork (W491 pitfall
  # repeated here: do not duplicate the after_goal logic). Returns
  # `{:ok, :last_child}` or `{:ok, :not_last_child}` so the caller can
  # decide whether to append after_goal to the response payload.
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

      case GoalCompletion.finalize_child_and_check_goal_complete(task, done_attrs) do
        {:ok, tag} when tag in [:last_child, :not_last_child] -> tag
        {:error, _step, changeset, _changes} -> Repo.rollback(changeset)
      end
    end)
  end

  defp move_to_doing(task, user, board_id) do
    doing_column = get_column_by_name(board_id, "Doing")

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
