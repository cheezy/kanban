defmodule Kanban.Reviews do
  @moduledoc """
  Read + write API for the workspace Review Queue at `/review`.

  A task is "pending review" when:

    * `needs_review` is `true`
    * `review_status` is `nil` or `:pending` (both are treated as "no
      decision yet" by the Task schema)
    * its `Column` is named `"Review"`
    * it is not archived (`archived_at` is `nil`): an archived task left in
      Review is off every queue, and approving it or requesting changes on it
      is refused with `:not_found`

  `completed_at` is intentionally **not** part of this filter — a task in
  the Review column is not yet completed; `completed_at` only gets stamped
  when the reviewer approves and the task transitions to Done.

  A pending task has been waiting since `waiting_since/1`: its
  `review_requested_at`, stamped each time it enters the Review column (an
  agent completion, including a resubmission after "request changes", or a
  drag in from another column), else its `updated_at`. The queue order, the
  header's oldest age, the queue cards, the detail header and the weekly
  digest all use it, so one task shows one age everywhere.

  All public functions are scope-aware: when a `Kanban.Accounts.Scope` is
  passed, results are filtered to tasks on boards the scoped user has
  effective access to — a `Kanban.Boards.BoardUser` row, or derived org-admin
  access through `Kanban.Workspaces.Policy`. When `nil`, the full set is
  returned.

  The two mutation functions (`approve_review/3`, `request_changes_review/3`)
  wrap the two-step contract required by `Kanban.Tasks.AgentWorkflow.mark_reviewed/2`:
  the caller must persist `review_status`, `reviewed_at`, and `reviewed_by_id`
  on the task BEFORE invoking the workflow transition, because
  `mark_reviewed/2` reads `task.review_status` to decide the destination
  column. Both calls run inside an outer `Repo.transaction/1` so a
  workflow-step failure rolls back the review-field write
  (`Kanban.Reviews.ReviewCommit`). Only the scope's user with write access to
  the task's board may decide it (`can_review?/2`); a read-only member is
  refused with `:not_authorized`.

  Nothing a review causes outside the database happens before its commit
  (`Kanban.Telemetry.AfterCommit`): its `[:kanban, :task, :completed]` and
  goal events such as `[:kanban, :goal, :completed]`, the audit event's
  `[:kanban, :audit, *]` telemetry and `security_audit` log line, the
  completer's notification (`Kanban.Notifications.Events.task_reviewed/2`),
  the webhooks and `[:kanban, :task, :review_approved]` or
  `[:kanban, :task, :review_changes_requested]`. A rolled-back review emits and
  sends none of them, including when the review runs inside a caller's own
  transaction that is wrapped in `AfterCommit.after_commit/1`, as the app's
  decisions are. Once it has committed, `[:kanban, :task, :completed]` is
  emitted first, then the goal events in the order the approval caused them,
  then the audit event, then the review event. Both review events carry `via`
  and `device_class`, and each review emits exactly one of them.

  Every committed review, web or app, also writes one audit event —
  `:review_approved` or `:review_changes_requested` — as the last write inside
  the same transaction, so a refused or rolled-back review leaves no row
  (`Kanban.Reviews.Audit`). Callers say
  where the review was made through `opts`: `:via` (`:web`, `:ios` or
  `:android`), `:device` (the `Kanban.Devices.Device`, for an app review) and,
  on an approval, `:approval_key` (`true` when the device's approval
  signature was verified). The web passes `via: :web`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Reviews.DiffHighlighter
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Reviews.MobileReview
  alias Kanban.Reviews.MobileReviewFile
  alias Kanban.Reviews.ReviewCommit
  alias Kanban.Tasks.Task

  @review_column_name "Review"

  @doc """
  Returns the list of tasks currently pending review.

  Tasks are ordered by `waiting_since/1` ascending (oldest first, ties by
  id) so the reviewer surfaces the most stale work at the top of the queue;
  editing a pending task does not move it. `:column` and the column's
  `:board` are preloaded so the queue UI can render the board chip without
  N+1 lookups.

  ## Options

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. Limits results to tasks on
      boards the scoped user is a member of. When `nil`, all pending tasks
      are returned.
  """
  @spec list_pending_reviews(keyword()) :: [Task.t()]
  def list_pending_reviews(opts \\ []) do
    Task
    |> pending_review_query()
    |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
    |> order_by([t],
      asc: fragment("COALESCE(?, ?)", t.review_requested_at, t.updated_at),
      asc: t.id
    )
    |> preload([t], [:completed_by, column: :board])
    |> Repo.all()
  end

  @doc """
  Returns when a pending task started waiting for review, as a UTC
  `DateTime`: its `review_requested_at`, else its `updated_at` for a task
  that predates the stamp or was created directly in the Review column.
  Returns `nil` when neither is present.

  Takes a `Task` or any map with those keys.
  """
  @spec waiting_since(map()) :: DateTime.t() | nil
  def waiting_since(%{review_requested_at: %DateTime{} = at}), do: at

  def waiting_since(%{updated_at: %NaiveDateTime{} = at}),
    do: DateTime.from_naive!(at, "Etc/UTC")

  def waiting_since(%{updated_at: %DateTime{} = at}), do: at
  def waiting_since(_task), do: nil

  @doc """
  Returns a single pending-review task by id, scoped to the caller.

  Returns `{:ok, task}` when the task is pending review and the caller
  can access its board, `{:error, :not_found}` otherwise.

  The returned task has `:column` and `:board` preloaded.
  """
  @spec get_pending_review(Scope.t() | nil, integer() | String.t()) ::
          {:ok, Task.t()} | {:error, :not_found}
  def get_pending_review(scope, id) do
    Task
    |> pending_review_query()
    |> where([t], t.id == ^id)
    |> BoardScope.apply_board_scope(scope)
    |> preload([t], [:completed_by, column: :board])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Task{} = task -> {:ok, task}
    end
  end

  @doc """
  Returns a pending-review task the scoped user can decide: one
  `get_pending_review/2` finds (pending, on a board they can see) on a board
  they can also write to, the same board-write check an approval or a request
  for changes runs (`AgentWorkflow.authorized_reviewer?/2`). A read-only
  member gets `{:error, :not_found}`, as for a task they cannot see, one
  that has left Review, or one that was archived while still in Review, so the
  answer reveals nothing.

  The task has `:completed_by`, `:parent`, `:column` and the column's
  `:board` preloaded. This is the read path of the app's review screen
  (`GET /api/me/reviews/:task_id`, W2751).
  """
  @spec get_reviewable_task(Scope.t(), integer()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_reviewable_task(%Scope{} = scope, id) do
    with {:ok, %Task{archived_at: nil} = task} <- get_pending_review(scope, id),
         :ok <- authorize_review(task, scope_user(scope)) do
      {:ok, Repo.preload(task, :parent)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Whether the scope's user may decide `task`'s review (approve it or request
  changes): they can write to its board, the check `approve_review/3` and
  `request_changes_review/3` run again inside their transaction. `task` needs
  its `:column` loaded. A read-only member, or no user, is `false`.
  """
  @spec can_review?(Scope.t() | nil, Task.t()) :: boolean()
  def can_review?(scope, %Task{column: %{board_id: board_id}}),
    do: ReviewCommit.authorized?(board_id, scope_user(scope))

  def can_review?(_scope, _task), do: false

  @doc """
  The ids of the boards among `tasks`' (each with its `:column` loaded) on
  which the scope's user may decide reviews, as a set, checking each board
  once. `/review` uses it to offer Approve and Request changes only where
  they would be accepted.
  """
  @spec reviewable_board_ids(Scope.t() | nil, [Task.t()]) :: MapSet.t(integer())
  def reviewable_board_ids(scope, tasks) when is_list(tasks) do
    user = scope_user(scope)

    tasks
    |> Enum.flat_map(fn
      %Task{column: %{board_id: board_id}} -> [board_id]
      _task -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(&ReviewCommit.authorized?(&1, user))
    |> MapSet.new()
  end

  @doc """
  The app's review screen for `task`, a task from `get_reviewable_task/2`,
  as `Kanban.Reviews.MobileReview.build/3` returns it for a device of
  `device_class`. Loads the tasks that depend on it for `holds_up`.
  """
  @spec mobile_review(Task.t(), MobileGuard.device_class()) :: MobileReview.t()
  def mobile_review(%Task{} = task, device_class) do
    MobileReview.build(task, Kanban.Tasks.get_dependent_tasks(task), device_class)
  end

  @doc """
  One file of `task`, a task from `get_reviewable_task/2`, for the app's
  flagged-file screen (`GET /api/me/reviews/:task_id/files/:index`, W2753):
  `index` is its position in `changed_files`, and its diff is highlighted by
  `Kanban.Reviews.DiffHighlighter.highlight/4`. Returns `{:error, :not_found}`
  for an index that names no file of this task, and
  `{:error, {:files_changed, current_version}}` when `files_version` (the
  detail's, sent back by the app) no longer matches the task's file list
  (`Kanban.Reviews.MobileReviewFile.build/4`); `nil` skips that check.
  """
  @spec mobile_review_file(Task.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, MobileReviewFile.t()} | {:error, :not_found | {:files_changed, String.t()}}
  def mobile_review_file(%Task{} = task, index, files_version \\ nil) do
    MobileReview.file(task, index, &DiffHighlighter.highlight/4, files_version)
  end

  @doc """
  Returns aggregate counters for the queue header.

  The map contains:

    * `:count` — total number of pending-review tasks
    * `:distinct_agents` — distinct non-nil `completed_by_agent` values
    * `:oldest_age_minutes` — minutes since the oldest pending task's
      `waiting_since/1`, clamped to 0; `nil` when the queue is empty
  """
  @spec queue_stats(keyword()) :: %{
          count: non_neg_integer(),
          distinct_agents: non_neg_integer(),
          oldest_age_minutes: non_neg_integer() | nil
        }
  def queue_stats(opts \\ []) do
    tasks =
      Task
      |> pending_review_query()
      |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
      |> select([t], %{
        review_requested_at: t.review_requested_at,
        updated_at: t.updated_at,
        agent: t.completed_by_agent
      })
      |> Repo.all()

    %{
      count: length(tasks),
      distinct_agents: count_distinct_agents(tasks),
      oldest_age_minutes: oldest_age_minutes(tasks)
    }
  end

  # --- Query helpers ---------------------------------------------------------

  defp pending_review_query(query) do
    from(t in query,
      join: c in assoc(t, :column),
      as: :column,
      where:
        t.needs_review == true and is_nil(t.archived_at) and
          (is_nil(t.review_status) or t.review_status == :pending)
    )
    |> where(^Columns.name_matches(:column, @review_column_name))
  end

  # --- queue_stats helpers ---------------------------------------------------

  defp count_distinct_agents(tasks) do
    tasks
    |> Enum.map(& &1.agent)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp oldest_age_minutes([]), do: nil

  defp oldest_age_minutes(tasks) do
    oldest =
      tasks
      |> Enum.map(&waiting_since/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    case oldest do
      nil ->
        nil

      %DateTime{} = since ->
        DateTime.utc_now()
        |> DateTime.diff(since, :second)
        |> max(0)
        |> div(60)
    end
  end

  # --- Reviewer actions ------------------------------------------------------

  @doc """
  Approves a pending-review task on behalf of the scoped user.

  Sets `review_status` to `:approved`, stamps `reviewed_at` with the current
  UTC second, and sets `reviewed_by_id` from `scope.user.id`. Then delegates
  to `Kanban.Tasks.AgentWorkflow.mark_reviewed/2` which moves the task to
  the board's Done column and fires the standard completion side effects
  (telemetry, PubSub, dependency unblock).

  The two writes run inside an outer `Repo.transaction/1` so that a
  workflow-step failure rolls back the review-field update. The completion
  telemetry is held back until that transaction commits, so a rolled-back or
  refused approval emits no `[:kanban, :task, :completed]`, no goal events and
  no `[:kanban, :task, :review_approved]`, no audit telemetry, no
  notification and no webhook. A committed approval writes one
  `:review_approved` audit event inside the same transaction.

  `opts` says where the approval was made: `:via` (`:web`, `:ios` or
  `:android`), `:device` (the reviewer's `Kanban.Devices.Device`, for the app)
  and `:approval_key` (`true` when the caller verified the device's approval
  signature). See `Kanban.Reviews.Audit.context/2`.

  Returns `{:ok, task}` on success or `{:error, reason}` where `reason` is
  one of: `:not_found` (task is missing, archived, no longer pending, or on
  an inaccessible board), `:not_authorized` (user has read-only board
  access), `:column_not_found` (the board has no Done column: one named
  "Done", ignoring case and surrounding whitespace, as
  `Kanban.Columns.named?/2` compares), `:review_not_performed`,
  `:invalid_column`, `:invalid_review_status`, or an `Ecto.Changeset.t/0`
  for validation failures.
  """
  @spec approve_review(Scope.t() | nil, Task.t(), keyword()) ::
          {:ok, Task.t()} | {:error, atom() | Ecto.Changeset.t()}
  def approve_review(scope, %Task{} = task, opts \\ []) do
    perform_review(
      scope,
      task,
      %{review_status: :approved},
      Keyword.put(opts, :move_after_review?, true)
    )
  end

  @doc """
  Records a "changes requested" review on behalf of the scoped user.

  Requires `:review_notes` in `opts` — the whole point of the action is to
  pass the reviewer's feedback back to the agent. Sets `review_status` to
  `:changes_requested`, persists `:review_notes`, stamps `reviewed_at`,
  and sets `reviewed_by_id`. The task stays in the Review column so the
  agent can pick up the notes and move it back to Doing itself. A committed
  request writes one `:review_changes_requested` audit event inside the same
  transaction; `opts` also takes `:via` and `:device`, as `approve_review/3`
  does. The notes are never recorded in the audit event.

  Returns `{:ok, task}` on success or `{:error, reason}` — additional
  reason atoms over `approve_review/3`: `:review_notes_required`.
  """
  @spec request_changes_review(Scope.t() | nil, Task.t(), keyword()) ::
          {:ok, Task.t()} | {:error, atom() | Ecto.Changeset.t()}
  def request_changes_review(scope, %Task{} = task, opts) do
    case fetch_review_notes(opts) do
      {:error, _} = err ->
        err

      {:ok, notes} ->
        # Request-changes only stamps the review fields — the task stays in
        # the Review column so the agent can pick up the notes, address
        # them, and move the task back to Doing themselves. Approving still
        # routes the task forward to Done via the agent workflow.
        perform_review(
          scope,
          task,
          %{review_status: :changes_requested, review_notes: notes},
          Keyword.put(opts, :move_after_review?, false)
        )
    end
  end

  defp fetch_review_notes(opts) do
    case Keyword.get(opts, :review_notes) do
      nil ->
        {:error, :review_notes_required}

      "" ->
        {:error, :review_notes_required}

      notes when is_binary(notes) ->
        if String.trim(notes) == "" do
          {:error, :review_notes_required}
        else
          {:ok, notes}
        end

      _ ->
        {:error, :review_notes_required}
    end
  end

  defp perform_review(scope, %Task{} = task, base_attrs, opts) do
    case scope_user(scope) do
      nil -> {:error, :not_authorized}
      user -> ReviewCommit.perform(scope, task, user, base_attrs, opts)
    end
  end

  defp authorize_review(%Task{column: %{board_id: board_id}}, user) do
    if ReviewCommit.authorized?(board_id, user), do: :ok, else: {:error, :not_authorized}
  end

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_), do: nil
end
