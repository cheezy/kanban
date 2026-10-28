defmodule Kanban.Tasks.AgentWorkflow do
  @moduledoc """
  Agent task lifecycle operations: claim, complete, review, unclaim, and mark done.

  Handles the workflow for AI agents interacting with tasks, including
  moving tasks between columns and integrating with the hook system.

  ## Module organization (W2355)

  This module is the single public entry point for the agent task lifecycle.
  The work lives in four focused siblings under `Kanban.Tasks.AgentWorkflow.*`,
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
    * `Kanban.Tasks.AgentWorkflow.Review` — the review and done transitions:
      `mark_reviewed/3` (the approved branch to Done, scheduling the after_goal
      grace window, then `Support.finalize_completion/5`, then the goal
      telemetry; the changes-requested and rejected branch back to Doing),
      `mark_done/2` (the deprecated straight-to-Done path) and
      `authorized_reviewer?/2` (the board-write check both run first, and
      `Kanban.Reviews` reuses on the request-changes path, D138), with all
      their private helpers. `GoalCompletion.finalize_child/2` stays the only
      last-child check on the approved branch (W490/W491).
    * `Kanban.Tasks.AgentWorkflow.Completion` — the completion transition:
      `complete_task/4` (the status, board-write and assignee refusals, the
      detect-only credential audits, and the move to Review in one
      transaction; then either the needs_review stop at Review or the separate
      auto-Done transaction through `GoalCompletion.finalize_child/2`, then
      `Support.finalize_completion/5` after it commits) and
      `completion_changeset/5` (the cast
      completion fields, the W398 payload validators and the D239
      `workflow_steps` shape check), with all their private helpers.

  What stays here is only the public API — claim, complete, review, unclaim,
  mark done and `authorized_reviewer?/2`, with the defaults and documentation
  of each. `claim_next_task` and `unclaim_task` pass every argument through to
  `Claiming`, `complete_task` to `Completion`, and `mark_reviewed`, `mark_done`
  and `authorized_reviewer?` to `Review`.
  """

  alias Kanban.Tasks.AgentWorkflow.Claiming
  alias Kanban.Tasks.AgentWorkflow.Completion
  alias Kanban.Tasks.AgentWorkflow.Review

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
  def complete_task(task, user, params, agent_name \\ "Unknown"),
    do: Completion.complete_task(task, user, params, agent_name)

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
  defdelegate mark_reviewed(task, user, opts \\ []), to: Review

  @doc """
  Marks a task as done by moving it from Review to Done column.

  DEPRECATED: Use mark_reviewed/2 instead.

  Sets status to :completed, sets completed_at timestamp,
  and moves the task to the Done column. This is the final step in the task workflow.

  Only tasks in the Review column can be marked as done.
  """
  defdelegate mark_done(task, user), to: Review

  @doc """
  Returns `true` when `user` currently holds board-write access (`:owner` or
  `:modify`) on `board_id` — the authorization required to record or advance a
  review decision.

  Exposed so the `Kanban.Reviews` context can enforce the same check on the
  request-changes path, which does not route through `mark_reviewed/2` and
  would otherwise let a read-only member write review fields (D138).
  """
  defdelegate authorized_reviewer?(board_id, user), to: Review
end
