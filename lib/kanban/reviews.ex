defmodule Kanban.Reviews do
  @moduledoc """
  Read + write API for the workspace Review Queue at `/review`.

  A task is "pending review" when:

    * `needs_review` is `true`
    * `review_status` is `nil` or `:pending` (both are treated as "no
      decision yet" by the Task schema)
    * its `Column` is named `"Review"`

  `completed_at` is intentionally **not** part of this filter — a task in
  the Review column is not yet completed; `completed_at` only gets stamped
  when the reviewer approves and the task transitions to Done.

  All public functions are scope-aware: when a `Kanban.Accounts.Scope` is
  passed, results are filtered to tasks on boards the scoped user can
  access via `Kanban.Boards.BoardUser` membership. When `nil`, the
  full set is returned.

  The two mutation functions (`approve_review/3`, `request_changes_review/3`)
  wrap the two-step contract required by `Kanban.Tasks.AgentWorkflow.mark_reviewed/2`:
  the caller must persist `review_status`, `reviewed_at`, and `reviewed_by_id`
  on the task BEFORE invoking the workflow transition, because
  `mark_reviewed/2` reads `task.review_status` to decide the destination
  column. Both calls run inside an outer `Repo.transaction/1` so a
  workflow-step failure rolls back the review-field write.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

  @review_column_name "Review"

  @doc """
  Returns the list of tasks currently pending review.

  Tasks are ordered by `updated_at` ascending (oldest first) so the
  reviewer surfaces the most stale work at the top of the queue.
  `updated_at` reflects the most recent transition into the Review column
  (either the original agent completion, or an agent re-completion after
  a "request changes" round-trip). `:column`
  and the column's `:board` are preloaded so the queue UI can render the
  board chip without N+1 lookups.

  ## Options

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. Limits results to tasks on
      boards the scoped user is a member of. When `nil`, all pending tasks
      are returned.
  """
  @spec list_pending_reviews(keyword()) :: [Task.t()]
  def list_pending_reviews(opts \\ []) do
    Task
    |> pending_review_query()
    |> apply_scope(Keyword.get(opts, :scope))
    |> order_by([t], asc: t.updated_at)
    |> preload([t], [:completed_by, column: :board])
    |> Repo.all()
  end

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
    |> apply_scope(scope)
    |> preload([t], [:completed_by, column: :board])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Task{} = task -> {:ok, task}
    end
  end

  @doc """
  Returns aggregate counters for the queue header.

  The map contains:

    * `:count` — total number of pending-review tasks
    * `:distinct_agents` — distinct non-nil `completed_by_agent` values
    * `:oldest_age_minutes` — minutes since the oldest pending task's
      `updated_at` (which the agent workflow stamps when moving the task
      into Review), clamped to 0; `nil` when the queue is empty
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
      |> apply_scope(Keyword.get(opts, :scope))
      |> select([t], %{updated_at: t.updated_at, agent: t.completed_by_agent})
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
        t.needs_review == true and
          (is_nil(t.review_status) or t.review_status == :pending) and
          c.name == ^@review_column_name
    )
  end

  defp apply_scope(query, nil), do: query
  defp apply_scope(query, %Scope{user: nil}), do: query

  defp apply_scope(query, %Scope{user: user}) do
    query
    |> join(:inner, [t, column: c], bu in BoardUser, on: bu.board_id == c.board_id)
    |> where([_t, _, bu], bu.user_id == ^user.id)
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
      |> Enum.map(& &1.updated_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(NaiveDateTime, fn -> nil end)

    case oldest do
      nil ->
        nil

      %NaiveDateTime{} = ndt ->
        NaiveDateTime.utc_now()
        |> NaiveDateTime.diff(ndt, :second)
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
  workflow-step failure rolls back the review-field update.

  Returns `{:ok, task}` on success or `{:error, reason}` where `reason` is
  one of: `:not_found` (task is missing or on an inaccessible board),
  `:not_authorized` (user has read-only board access),
  `:review_not_performed`, `:invalid_column`, `:invalid_review_status`,
  or an `Ecto.Changeset.t/0` for validation failures.
  """
  @spec approve_review(Scope.t() | nil, Task.t(), keyword()) ::
          {:ok, Task.t()} | {:error, atom() | Ecto.Changeset.t()}
  def approve_review(scope, %Task{} = task, _opts \\ []) do
    # `_opts` is accepted for arity symmetry with `request_changes_review/3`;
    # no keys are currently honored.
    perform_review(scope, task, %{review_status: :approved}, move_after_review?: true)
  end

  @doc """
  Records a "changes requested" review on behalf of the scoped user.

  Requires `:review_notes` in `opts` — the whole point of the action is to
  pass the reviewer's feedback back to the agent. Sets `review_status` to
  `:changes_requested`, persists `:review_notes`, stamps `reviewed_at`,
  and sets `reviewed_by_id`. Then delegates to
  `Kanban.Tasks.AgentWorkflow.mark_reviewed/2` which moves the task back
  to the Doing column.

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
          move_after_review?: false
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
      user -> run_review_transaction(scope, task, user, base_attrs, opts)
    end
  end

  defp run_review_transaction(scope, task, user, base_attrs, opts) do
    Repo.transaction(fn -> commit_review!(scope, task, user, base_attrs, opts) end)
  end

  defp commit_review!(scope, task, user, base_attrs, opts) do
    move? = Keyword.get(opts, :move_after_review?, true)

    with {:ok, _fetched} <- get_pending_review(scope, task.id),
         {:ok, prepared} <- persist_review_fields(task, user, base_attrs),
         {:ok, final} <- maybe_mark_reviewed(prepared, user, move?) do
      final
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_mark_reviewed(task, user, true),
    do: normalize_workflow(AgentWorkflow.mark_reviewed(task, user))

  defp maybe_mark_reviewed(task, _user, false), do: {:ok, task}

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

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_), do: nil
end
