defmodule Kanban.Tasks.AgentWorkflow do
  @moduledoc """
  Agent task lifecycle operations: claim, complete, review, unclaim, and mark done.

  Handles the workflow for AI agents interacting with tasks, including
  moving tasks between columns and integrating with the hook system.

  ## Module organization (W2355)

  This module is the single public entry point for the agent task lifecycle.
  It is being split into focused siblings under `Kanban.Tasks.AgentWorkflow.*`,
  which it calls internally; callers outside the agent workflow keep calling
  this module, never a sibling.

    * `Kanban.Tasks.AgentWorkflow.Support` — the helpers shared by more than one
      lifecycle path: `board_write_access?/2` (the live board-write check on
      claim, unclaim, complete and review), `get_column_by_name/2` (every column
      move), `finalize_completion/5` (the post-Done side effects shared by the
      auto-done and approved-review paths) and `maybe_schedule_after_goal_grace/2`
      (the after_goal grace-window scheduling on a goal's last child). One copy
      of each, so the after_goal logic is never forked between paths (W491).
    * `Kanban.Tasks.AgentWorkflow.Claiming` — the claim lifecycle:
      `claim_next_task/5` (the board-write check, next-or-specific task
      lookup, the atomic claim transaction and its zero-row disambiguation,
      and the `task.claimed` telemetry piped from the claim's result) and
      `unclaim_task/3` (the refusal checks, the release transaction back to
      Ready, and the unclaim notification, webhook and telemetry), with all
      their private helpers.

  What stays here is the public API — claim, complete, review, unclaim, mark
  done and `authorized_reviewer?/2`, with the defaults and documentation of
  each; `claim_next_task` and `unclaim_task` pass every argument through to
  `Claiming` — and the concerns not yet extracted.
  """

  alias Kanban.ChangesetText
  alias Kanban.Hooks.Metadata
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow.Claiming
  alias Kanban.Tasks.AgentWorkflow.Support
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.ChangedFilesAudit
  alias Kanban.Tasks.CompletionNotesScan
  alias Kanban.Tasks.CompletionValidation
  alias Kanban.Tasks.GoalCompletion
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.SecurityConsiderationsScan
  alias Kanban.Tasks.TaskTelemetry
  alias Kanban.Tasks.WorkflowSteps

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
      ),
      do:
        Claiming.claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name)

  @doc """
  Releases a claimed task back to the "open" status and "Ready" column.

  Clears claimed_at, claim_expires_at, and assigned_to fields.
  Optionally accepts a reason for analytics.

  Returns {:ok, task} if successful, {:error, reason} otherwise. A `reason`
  holding a NUL byte or invalid UTF-8, which the unclaim notification's body
  could not store, is refused with `{:error, changeset}` carrying an error on
  `:reason`, and the task stays claimed (D383); it is never stripped.
  """
  def unclaim_task(task, user, reason \\ nil), do: Claiming.unclaim_task(task, user, reason)

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

      not Support.board_write_access?(board_id, user) ->
        # Catches the stale-permission case: the user is still the assignee but
        # has since been downgraded to :read_only or removed from the board.
        {:error, :not_authorized}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        audit_credential_shapes(params, task.id, agent_name)
        do_complete_task(task, user, params, board, board_id, agent_name)
    end
  end

  # Detect-only scans: each emits a security audit event when agent-authored
  # text looks credential-bearing, and the completion proceeds either way.
  #
  # `completion_notes` is free text that D188 made durable and human-rendered;
  # the redaction rule that governs it is prompt text in external plugin repos.
  # `reviewer_result` carries the reviewer's verbatim echo of the task's
  # security considerations, which covers tasks written before W2382's
  # write-time rejection existed.
  defp audit_credential_shapes(params, task_id, agent_name) do
    CompletionNotesScan.audit(
      params["completion_notes"] || params[:completion_notes],
      task_id,
      agent_name
    )

    SecurityConsiderationsScan.audit(
      params["reviewer_result"] || params[:reviewer_result],
      task_id,
      agent_name
    )
  end

  defp do_complete_task(task, user, params, board, board_id, agent_name) do
    review_column = Support.get_column_by_name(board_id, "Review")

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

  `webhook: false` skips the task's webhook event; `Kanban.Reviews` passes it
  because it calls this inside its own transaction and emits after commit.
  """
  def mark_reviewed(task, user, opts \\ []) do
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

  @doc """
  Returns `true` when `user` currently holds board-write access (`:owner` or
  `:modify`) on `board_id` — the authorization required to record or advance a
  review decision.

  Exposed so the `Kanban.Reviews` context can enforce the same check on the
  request-changes path, which does not route through `mark_reviewed/2` and
  would otherwise let a read-only member write review fields (D138).
  """
  def authorized_reviewer?(board_id, user), do: Support.board_write_access?(board_id, user)

  # Private functions

  defp handle_successful_completion(task, updated_task, user, columns, params, agent_name) do
    %{board: board} = columns
    board_id = board.id
    updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])

    Goals.update_parent_goal_position_locked(updated_task)

    Logger.info(
      "Task #{task.id} completed and moved to Review by user #{user.id}. Time spent: #{params["time_spent_minutes"]} minutes"
    )

    TaskTelemetry.moved_to_review(updated_task, user.id)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {:task_moved_to_review, updated_task}
    )

    Broadcaster.emit_webhook(updated_task, :task_moved_to_review, board_id)

    if updated_task.needs_review do
      # Moving to Review is the terminal step for needs_review tasks (no
      # finalize_completion call follows), so emit the agents-topic event here
      # to keep /agents live. The auto-Done path emits it via finalize_completion.
      Broadcaster.broadcast_agent_event(updated_task, :task_completed, board_id)

      # (D128) Non-blocking safety net: flag a review-bound task that reached
      # Review with no changed_files diff despite having changed files, so the
      # gap is telemetry-visible instead of a silently blind review queue.
      ChangedFilesAudit.audit_review_bound_task(updated_task, board_id)
      Events.review_requested(updated_task)

      hooks =
        Metadata.build_completion_hooks(updated_task, board, agent_name, needs_review?: true)

      {:ok, updated_task, hooks}
    else
      auto_move_to_done(updated_task, user, board, agent_name)
    end
  end

  defp auto_move_to_done(updated_task, user, board, agent_name) do
    board_id = board.id
    done_column = Support.get_column_by_name(board_id, "Done")

    case run_auto_done_transaction(updated_task, done_column) do
      {:ok, {last_child_tag, completed_goal_id}} ->
        Support.maybe_schedule_after_goal_grace(updated_task, last_child_tag)
        final_task = Support.finalize_completion(updated_task, user, board_id, done_column)
        GoalTelemetry.completed(completed_goal_id, board_id)

        hooks =
          Metadata.build_completion_hooks(final_task, board, agent_name,
            last_child?: last_child_tag == :last_child
          )

        {:ok, final_task, hooks}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Auto-done transaction. Uses `GoalCompletion.finalize_child/2`
  # so the child Done write and the parent-goal "is-this-the-last-child"
  # check live in one transactionally-locked unit (W490) — the controller
  # never duplicates that check. Returns `{:ok, {tag, completed_goal_id}}`:
  # the tag decides whether to append the after_goal hook to the response
  # payload (W491), and the goal id (set only when this completion first
  # completed the goal) is emitted as goal.completed after the commit.
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

      case GoalCompletion.finalize_child(updated_task, done_attrs) do
        {:ok, tag, completed_goal_id} -> {tag, completed_goal_id}
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
  #
  # `:completion_notes` IS cast here (D188). It is the documented long-form
  # findings channel alongside the required one-line `:completion_summary`, and
  # was previously dropped silently because `cast/3` ignores unknown keys. It
  # stays out of `validate_required/2` below: omitting it must leave the stored
  # value untouched rather than fail or blank the field.
  defp completion_changeset(task, user, params, review_column, next_position) do
    task
    |> Ecto.Changeset.cast(params, [
      :completion_summary,
      :completion_notes,
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes,
      :completed_by_agent,
      :review_report,
      :workflow_steps,
      :explorer_result,
      :reviewer_result
    ])
    |> ChangesetText.validate_storable([
      :completion_summary,
      :completion_notes,
      :actual_files_changed,
      :completed_by_agent,
      :review_report,
      :workflow_steps,
      :explorer_result,
      :reviewer_result
    ])
    |> Ecto.Changeset.put_change(:column_id, review_column.id)
    |> Ecto.Changeset.put_change(:position, next_position)
    |> Ecto.Changeset.put_change(:completed_by_id, user.id)
    |> Ecto.Changeset.put_change(:review_requested_at, DateTime.utc_now(:second))
    |> reset_review_round()
    |> Ecto.Changeset.validate_required([
      :completion_summary,
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes
    ])
    |> Ecto.Changeset.validate_inclusion(:actual_complexity, [:small, :medium, :large])
    # Generous bound: long-form findings are the point of the field, but an
    # unbounded value is persisted AND re-rendered into the Review queue (D188).
    |> Ecto.Changeset.validate_length(:completion_notes, max: 65_535)
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
  #
  # D239 moved the shape check and the reason_code vocabulary into
  # `Kanban.Tasks.WorkflowSteps`: the read side (Compliance) and the API schema
  # documentation both need to name the vocabulary, and this module was already
  # over the 500-line guideline in AGENTS.md.
  defp validate_workflow_steps_shape(changeset, params) do
    WorkflowSteps.validate_shape(changeset, params)
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
