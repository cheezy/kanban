defmodule Kanban.Reviews.ReviewCommit do
  @moduledoc """
  The write path behind `Kanban.Reviews.approve_review/3` and
  `Kanban.Reviews.request_changes_review/3`, kept apart so `Kanban.Reviews`
  stays the queue's read API plus those two entry points.

  `perform/4` runs one review in a transaction: it locks the task row, reads
  the task again as a pending review (`Kanban.Reviews.get_pending_review/2`,
  so a task decided, moved out of Review or archived since the caller loaded
  it is refused with `:not_found`), checks board-write access, writes the
  review fields, moves the task when the review approves it
  (`Kanban.Tasks.AgentWorkflow.mark_reviewed/3`) and writes the audit row as
  its last write (`Kanban.Reviews.Audit.record/4`).

  Everything the review causes outside the database waits for the commit:
  the completion and goal telemetry the move emits, the audit event's
  telemetry and log line (`Kanban.AuditLog.event/2` defers them), the
  completer's notification, the webhooks and the review telemetry all go
  through `Kanban.Telemetry.AfterCommit`. A caller that runs the review inside
  its own transaction, as the app's approval and request for changes do
  (`Kanban.Reviews.Approval`, `Kanban.Reviews.RequestChanges`), wraps that
  transaction in `AfterCommit.after_commit/1`, so all of it waits for the
  outer commit and a rollback there emits and sends nothing.
  """

  import Ecto.Query, warn: false

  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.Audit
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry
  alias Kanban.Telemetry.AfterCommit

  @doc """
  Runs one review of `task` by `user` (the scope's user), as described in the
  moduledoc. `base_attrs` holds the `review_status` (and, for a request for
  changes, the `review_notes`); `opts` holds `:move_after_review?` and the
  `Kanban.Reviews.Audit.context/2` options.

  Returns `{:ok, task}` or `{:error, reason}`.
  """
  @spec perform(term(), Task.t(), %{id: integer()}, map(), keyword()) ::
          {:ok, Task.t()} | {:error, term()}
  def perform(scope, %Task{} = task, user, base_attrs, opts) do
    context = Audit.context(opts, user)
    moved? = Keyword.get(opts, :move_after_review?, true)

    scope
    |> run_transaction(task, user, base_attrs, opts, context)
    |> after_commit(fn task ->
      Events.task_reviewed(task, user)
      emit_reviewed_webhooks(task, moved?)

      TaskTelemetry.reviewed(
        {:ok, task},
        base_attrs.review_status,
        user,
        Audit.telemetry_metadata(context)
      )
    end)
  end

  @doc """
  Whether `user` may decide reviews on `board_id`: the board-write check an
  approval or a request for changes runs
  (`Kanban.Tasks.AgentWorkflow.authorized_reviewer?/2`).
  """
  @spec authorized?(integer(), %{id: integer()} | nil) :: boolean()
  def authorized?(_board_id, nil), do: false
  def authorized?(board_id, user), do: AgentWorkflow.authorized_reviewer?(board_id, user)

  # Runs once the review's transaction has returned, and through
  # AfterCommit.defer/2, so when the caller holds its own transaction open
  # (the app's decisions) the notification, webhooks and review telemetry wait
  # for that outer commit too and are dropped if it rolls back.
  defp after_commit({:ok, task} = result, fun) do
    AfterCommit.defer(fn -> fun.(task) end)
    result
  end

  defp after_commit(error, _fun), do: error

  # When the review also moved the task, its webhook event was held back
  # inside the transaction (`webhook: false` below) and is emitted here,
  # before task.reviewed.
  defp emit_reviewed_webhooks(task, moved?) do
    case Repo.preload(task, :column) do
      %Task{column: %{board_id: board_id}} = task ->
        if moved?, do: Broadcaster.emit_webhook(task, moved_event(task), board_id)
        Broadcaster.emit_webhook(task, :task_reviewed, board_id)

      _no_column ->
        :ok
    end
  end

  defp moved_event(%Task{review_status: :approved}), do: :task_completed
  defp moved_event(%Task{}), do: :task_returned_to_doing

  defp run_transaction(scope, task, user, base_attrs, opts, context) do
    # Telemetry the approval causes (task.completed, task.unblocked,
    # goal.completed, goal.grace_window_scheduled, the audit event) is held
    # back until this transaction commits.
    AfterCommit.after_commit(fn ->
      Repo.transaction(fn -> commit!(scope, task, user, base_attrs, opts, context) end)
    end)
  end

  # The task row is locked first, so two reviews of one task run one after the
  # other: the second reads the task once the first has committed, finds it no
  # longer pending and is refused with `:not_found`. The audit row is the last
  # write, so any refusal rolls back before it and a committed review always
  # has exactly one row. `fetched` is the fresh record with its column, which
  # the row's board id and change size read.
  defp commit!(scope, task, user, base_attrs, opts, context) do
    with :ok <- lock_task_row(task.id),
         {:ok, fetched} <- Reviews.get_pending_review(scope, task.id),
         :ok <- authorize_write(fetched, user),
         {:ok, final} <- write_review(task, user, base_attrs, opts),
         :ok <- Audit.record(base_attrs.review_status, fetched, user, context) do
      final
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_task_row(task_id) do
    query = from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE", select: t.id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  # `get_pending_review/2` is membership-scoped (it lists every board member's
  # queue, read-only included), so it must not double as the write gate. The
  # request-changes path sets `move_after_review?: false` and never reaches
  # `AgentWorkflow.mark_reviewed/2`, where board-write access is otherwise
  # enforced — so we re-run the same check here, inside the transaction, to
  # close the read-only->write escalation (D138). The check runs before any
  # review field is persisted, so an unauthorized caller rolls back cleanly.
  defp authorize_write(%Task{column: %{board_id: board_id}}, user) do
    if authorized?(board_id, user), do: :ok, else: {:error, :not_authorized}
  end

  defp write_review(task, user, base_attrs, opts) do
    with {:ok, prepared} <- persist_review_fields(task, user, base_attrs) do
      maybe_mark_reviewed(prepared, user, opts)
    end
  end

  defp maybe_mark_reviewed(task, user, opts) do
    if Keyword.get(opts, :move_after_review?, true) do
      normalize_workflow(AgentWorkflow.mark_reviewed(task, user, webhook: false))
    else
      {:ok, task}
    end
  end

  defp persist_review_fields(task, user, base_attrs) do
    attrs =
      base_attrs
      |> Map.put(:reviewed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put(:reviewed_by_id, user.id)

    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  defp normalize_workflow({:ok, task, _after_review_hook}), do: {:ok, task}
  defp normalize_workflow({:ok, task}), do: {:ok, task}
  defp normalize_workflow({:error, _} = err), do: err
end
