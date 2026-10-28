defmodule Kanban.Tasks.AgentWorkflow.Completion do
  @moduledoc """
  The completion transition of the agent workflow: completing a claimed task,
  moving it to Review, and either stopping there (`needs_review` true) or
  auto-moving it to Done; plus `completion_changeset/5`, which casts the
  completion fields and runs the W398 payload validators and the D239
  `workflow_steps` shape check.

  The refusal checks run before any state change and in a fixed order: status,
  then the live board-write check (W1430), then the assignee. The detect-only
  credential audits run next, then the move to Review in one transaction. The
  auto-Done move is a second, separate transaction; its `task.completed` and
  goal telemetry go through `Kanban.Telemetry.AfterCommit.defer/2` after that
  transaction returns (D371), which emits straight away because no caller wraps
  this path in `after_commit/1` today. `AfterCommit` queues deferred emits in
  the calling process's dictionary, so everything here stays in the caller's
  process.

  Not a public entry point. `Kanban.Tasks.AgentWorkflow` owns the public API,
  its defaults and its documentation, and delegates `complete_task/4` here with
  every argument; callers outside the agent workflow call the facade, never
  this module.
  """

  alias Kanban.ChangesetText
  alias Kanban.Hooks.Metadata
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow.Support
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.ChangedFilesAudit
  alias Kanban.Tasks.CompletionNotesScan
  alias Kanban.Tasks.CompletionValidation
  alias Kanban.Tasks.GoalCompletion
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.SecurityConsiderationsScan
  alias Kanban.Tasks.TaskTelemetry
  alias Kanban.Tasks.WorkflowSteps

  require Logger

  @doc false
  def complete_task(task, user, params, agent_name) do
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
end
