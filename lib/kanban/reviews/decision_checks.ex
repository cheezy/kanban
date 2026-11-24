defmodule Kanban.Reviews.DecisionChecks do
  @moduledoc """
  The checks every app review decision runs before it is made
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.5), shared by the
  signed approval (`Kanban.Reviews.Approval`) and the request for changes
  (`Kanban.Reviews.RequestChanges`).

  `decidable/4` runs checks 1 to 3, in this order, and stops at the first
  that fails:

    1. **Access.** The task exists, is not archived, is on a board the person
       can see and they can write to it (the review write check). Anything
       else is `:not_found`, so no later answer reveals a task the person
       cannot review.
    2. **State.** The review is still pending, and its `review_requested_at`
       matches the one sent: else `{:conflict, :already_decided, task}` or
       `{:conflict, :resubmitted, task}` with the current task. A missing or
       malformed `review_requested_at` is `{:bad_request, message}`.
    3. **Plan.** `:mobile_app`, for the person and then for the task's board:
       `{:plan_required, :mobile_app}`.

  `replayable/2` runs checks 1 and 3 alone, before a stored result is
  replayed for a retried request (`KanbanWeb.API.Me.Idempotent`), so a person
  who lost access or the plan since the first request is refused rather than
  answered from the store.

  `recheck_locked/4` runs inside the decision's commit transaction: it locks
  the task row and the device row, runs the access check again, refuses a
  device revoked since its request was admitted (`:revoked`), checks the
  state again, so a review decided or resubmitted between the checks and the
  commit answers 409, and checks the plan again, so a downgrade committed
  between the checks and the commit is `{:plan_required, :mobile_app}`.
  Under the lock the plan is read from the database: the person's
  membership as it is now, not the one the scope was built with. The plan
  rows are not locked, so a downgrade committed after this read and before
  the commit still lets that one decision through (design doc §24,
  decision 20).
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Device
  alias Kanban.Plans
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

  @requested_at_message "review_requested_at is required: the ISO 8601 extended-format timestamp the challenge returned, such as 2026-11-18T09:30:00Z, or null or an empty string for a task that has none."

  @typedoc "`:any` when the caller may omit `review_requested_at` and did."
  @type requested :: DateTime.t() | nil | :any

  @doc """
  Checks 1 to 3 for task `task_id`. `mode` is `:required` when `params` must
  carry `"review_requested_at"` (`nil` or `""` for a task without one), or
  `:optional` when it may be left out, which matches any stamp.

  Returns `{:ok, pending_task, requested}` or `{:error, reason}`.
  """
  @spec decidable(Scope.t(), integer(), map(), :required | :optional) ::
          {:ok, Task.t(), requested()} | {:error, term()}
  def decidable(%Scope{} = scope, task_id, params, mode)
      when is_map(params) and mode in [:required, :optional] do
    with {:ok, task} <- fetch_decidable(scope, task_id),
         {:ok, requested} <- requested_at(params, mode),
         do: pending_and_planned(scope, task, requested)
  end

  # Checks 2 and 3, on a task that passed check 1.
  defp pending_and_planned(scope, task, requested) do
    with {:ok, pending} <- check_state(scope, task, requested),
         :ok <- check_plan(scope, pending),
         do: {:ok, pending, requested}
  end

  @doc """
  Under the task row lock, inside the decision's transaction: the task is
  still visible and decidable, `device` is still active (`:revoked`
  otherwise), the review is still pending with the stamp `requested`, and
  the person and the task's board still have the `:mobile_app` plan
  (`{:plan_required, :mobile_app}` otherwise, as `decidable/4` answers).

  Returns `{:ok, fresh_task}` or `{:error, reason}`.
  """
  @spec recheck_locked(Scope.t(), Device.t(), Task.t(), requested()) ::
          {:ok, Task.t()} | {:error, term()}
  def recheck_locked(%Scope{} = scope, %Device{} = device, %Task{} = task, requested) do
    with :ok <- lock_task_row(task.id),
         {:ok, current} <- fetch_decidable(scope, task.id),
         :ok <- lock_active_device(device),
         do: locked_state_and_plan(scope, task, current, requested)
  end

  # The review state, then the plan, both under the row lock.
  defp locked_state_and_plan(scope, task, current, requested) do
    with {:ok, fresh} <- locked_state(scope, task, requested),
         :ok <- check_locked_plan(scope, current),
         do: {:ok, fresh}
  end

  @doc """
  Whether two `review_requested_at` stamps are the same, to the second.
  `nil` matches only `nil`.
  """
  @spec same_stamp?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def same_stamp?(nil, nil), do: true

  def same_stamp?(%DateTime{} = stored, %DateTime{} = requested),
    do: stored |> DateTime.truncate(:second) |> DateTime.compare(requested) == :eq

  def same_stamp?(_stored, _requested), do: false

  @doc """
  Checks 1 and 3 alone, for replaying a stored decision: the person can still
  review task `task_id` and still has the `:mobile_app` plan. The state check
  is left out, since the stored decision is what decided the review.

  Returns `:ok` or `{:error, reason}`, as `decidable/4` does.
  """
  @spec replayable(Scope.t(), integer()) :: :ok | {:error, term()}
  def replayable(%Scope{} = scope, task_id) do
    with {:ok, task} <- fetch_decidable(scope, task_id), do: check_plan(scope, task)
  end

  # --- 1. Access ---------------------------------------------------------------

  defp fetch_decidable(%Scope{user: %{id: _} = user} = scope, task_id)
       when is_integer(task_id) do
    Task
    |> where([t], t.id == ^task_id and is_nil(t.archived_at))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([t], [:completed_by, :reviewed_by, column: :board])
    |> Repo.one()
    |> authorize(user)
  end

  defp fetch_decidable(_scope, _task_id), do: {:error, :not_found}

  defp authorize(%Task{column: %{board_id: board_id}} = task, user) do
    if AgentWorkflow.authorized_reviewer?(board_id, user),
      do: {:ok, task},
      else: {:error, :not_found}
  end

  defp authorize(_task, _user), do: {:error, :not_found}

  # --- 2. State ------------------------------------------------------------------

  # `:any` means the caller sent none, so the challenge binds the task's own.
  defp requested_at(params, mode) do
    case Map.fetch(params, "review_requested_at") do
      :error when mode == :optional -> {:ok, :any}
      :error -> {:error, {:bad_request, @requested_at_message}}
      {:ok, empty} when empty in [nil, ""] -> {:ok, nil}
      {:ok, value} when is_binary(value) -> parse_requested_at(value)
      {:ok, _other} -> {:error, {:bad_request, @requested_at_message}}
    end
  end

  defp parse_requested_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.truncate(at, :second)}
      {:error, _reason} -> {:error, {:bad_request, @requested_at_message}}
    end
  end

  defp check_state(scope, %Task{} = task, requested) do
    case Reviews.get_pending_review(scope, task.id) do
      {:ok, pending} -> match_requested(Repo.preload(pending, :reviewed_by), requested)
      {:error, :not_found} -> {:error, {:conflict, :already_decided, task}}
    end
  end

  defp match_requested(pending, :any), do: {:ok, pending}

  defp match_requested(%Task{review_requested_at: stored} = pending, requested) do
    if same_stamp?(stored, requested),
      do: {:ok, pending},
      else: {:error, {:conflict, :resubmitted, pending}}
  end

  # --- 3. Plan -------------------------------------------------------------------

  defp check_plan(user_or_scope, %Task{column: %{board: board}}) do
    with :ok <- Plans.check_user(user_or_scope, :mobile_app, surface: :controller) do
      Plans.check_board(board, :mobile_app, surface: :controller)
    end
  end

  # Under the lock, from the database: the scope's user, not its membership
  # snapshot (a scope that carries one is decided without a query), and the
  # board `fetch_decidable/2` just read, whose workspace is not preloaded.
  defp check_locked_plan(%Scope{user: user}, %Task{} = current), do: check_plan(user, current)

  # --- Under the lock --------------------------------------------------------------

  defp lock_task_row(task_id) do
    query = from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE", select: t.id)
    if Repo.one(query), do: :ok, else: {:error, :not_found}
  end

  # FOR SHARE: a revoke waits for this commit, and one made before it is seen.
  defp lock_active_device(%Device{id: device_id}) do
    query =
      from(d in Device,
        where: d.id == ^device_id and is_nil(d.revoked_at),
        lock: "FOR SHARE",
        select: d.id
      )

    if Repo.one(query), do: :ok, else: {:error, :revoked}
  end

  # Under the row lock, a review decided or resubmitted since the checks ran
  # is a conflict with the task as it is now.
  defp locked_state(scope, %Task{} = task, requested) do
    case check_state(scope, task, requested) do
      {:error, {:conflict, :already_decided, _stale}} ->
        current = Task |> Repo.get!(task.id) |> Repo.preload([:reviewed_by, column: :board])
        {:error, {:conflict, :already_decided, current}}

      result ->
        result
    end
  end
end
