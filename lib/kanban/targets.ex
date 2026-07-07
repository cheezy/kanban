defmodule Kanban.Targets do
  @moduledoc """
  Board-scoped CRUD and goal membership for delivery targets.

  A `Kanban.Targets.DeliveryTarget` groups goal-type tasks toward a dated
  outcome. A target has no `board_id` of its own — it relates to boards
  *only* through the goal-type tasks that reference it via `tasks.target_id`.
  Visibility therefore flows through those member goals, NOT through target
  ownership: a target is visible to a caller when it has at least one member
  goal on a board the caller can access via `Kanban.Boards.BoardUser`
  membership. A target whose goals all live on inaccessible boards — or which
  has no member goals at all — is never returned by `list_targets/1` or
  `get_target/2`.

  All public functions take a `Kanban.Accounts.Scope` as the first argument.
  A `nil` scope (or `%Scope{user: nil}`) means "no board filter" for the read
  and membership functions, matching the convention in `Kanban.Reviews` and
  `Kanban.Archives`; the two persistence functions require a real user and
  return `{:error, :not_authorized}` otherwise.

  Goal membership (`assign_goal/3`, `unassign_goal/2`) always performs a
  board-scoped fetch of the goal first, then delegates the write to
  `Kanban.Tasks.update_task/2`. That changeset (`Kanban.Tasks.Task.changeset/2`)
  enforces `target_id`-only-on-goal-type, so attaching a target to a
  work/defect task fails with a changeset error without any extra check here.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Status
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @doc """
  Returns every delivery target with at least one member goal on a board the
  scoped user can access, ordered by `target_date` (soonest first).

  Visibility flows through accessible member goals — a target whose goals are
  all on inaccessible boards, or which has no member goals, is omitted. A
  `nil` scope applies no board filter and returns every target that has at
  least one goal-type member.
  """
  @spec list_targets(Scope.t() | nil) :: [DeliveryTarget.t()]
  def list_targets(scope) do
    DeliveryTarget
    |> where([dt], dt.id in subquery(member_target_ids_query(scope)))
    |> order_by([dt], asc: dt.target_date, asc: dt.id)
    |> Repo.all()
  end

  @doc """
  Fetches a single delivery target by id, scoped to the caller.

  Returns `{:ok, target}` when the target has a member goal on an accessible
  board, `{:error, :not_found}` otherwise (including a target with no member
  goals).
  """
  @spec get_target(Scope.t() | nil, integer() | String.t()) ::
          {:ok, DeliveryTarget.t()} | {:error, :not_found}
  def get_target(scope, id) do
    DeliveryTarget
    |> where([dt], dt.id == ^id)
    |> where([dt], dt.id in subquery(member_target_ids_query(scope)))
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %DeliveryTarget{} = target -> {:ok, target}
    end
  end

  @doc """
  Creates a delivery target owned by the scoped user.

  `owner_id` is stamped server-side from `scope.user.id` on the struct — it is
  never cast from `attrs` (see `DeliveryTarget.changeset/2`). Returns
  `{:error, :not_authorized}` when there is no user on the scope.
  """
  @spec create_target(Scope.t() | nil, map()) ::
          {:ok, DeliveryTarget.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_authorized}
  def create_target(scope, attrs) do
    case scope_user(scope) do
      nil ->
        {:error, :not_authorized}

      %{id: user_id} ->
        %DeliveryTarget{owner_id: user_id}
        |> DeliveryTarget.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Returns true when `user` owns `target` (`target.owner_id == user.id`).

  Ownership is the authorization basis for editing a target and managing its
  goal assignments, mirroring `Kanban.Boards.owner?/2`.
  """
  @spec owner?(DeliveryTarget.t(), Kanban.Accounts.User.t()) :: boolean()
  def owner?(%DeliveryTarget{owner_id: owner_id}, %{id: user_id}), do: owner_id == user_id

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking delivery-target changes.

  Mirrors `Kanban.Boards.change_board/2` so the LiveView form never builds
  `DeliveryTarget.changeset/2` directly. `owner_id` is never cast (see
  `DeliveryTarget.changeset/2`).
  """
  @spec change_target(DeliveryTarget.t(), map()) :: Ecto.Changeset.t()
  def change_target(%DeliveryTarget{} = target, attrs \\ %{}) do
    DeliveryTarget.changeset(target, attrs)
  end

  @doc """
  Fetches a target the scoped user owns, by id, with `:owner` preloaded.

  Unlike `get_target/2` (board-scoped through member goals), this is scoped by
  *ownership* — so a freshly created target with no member goals is still
  editable by its owner. Returns `{:error, :not_found}` when the target is
  missing, owned by another user, or the scope has no user.
  """
  @spec get_owned_target(Scope.t() | nil, integer() | String.t()) ::
          {:ok, DeliveryTarget.t()} | {:error, :not_found}
  def get_owned_target(scope, id) do
    case scope_user(scope) do
      nil ->
        {:error, :not_found}

      %{id: user_id} ->
        DeliveryTarget
        |> where([dt], dt.id == ^id and dt.owner_id == ^user_id)
        |> preload(:owner)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %DeliveryTarget{} = target -> {:ok, target}
        end
    end
  end

  @doc """
  Updates a delivery target's editable fields (`name`, `target_date`,
  `description`). Owner-only.

  Deliberately does not require the target to have accessible member goals —
  a freshly created target must be editable before any goal is assigned.
  Returns `{:error, :not_authorized}` when there is no user on the scope, or
  when the scoped user is not the target's owner.
  """
  @spec update_target(Scope.t() | nil, DeliveryTarget.t(), map()) ::
          {:ok, DeliveryTarget.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_authorized}
  def update_target(scope, %DeliveryTarget{} = target, attrs) do
    case scope_user(scope) do
      nil ->
        {:error, :not_authorized}

      user ->
        if owner?(target, user) do
          target
          |> DeliveryTarget.changeset(attrs)
          |> Repo.update()
        else
          {:error, :not_authorized}
        end
    end
  end

  @doc """
  Attaches `goal` to `target` by setting `goal.target_id`.

  The goal is re-fetched under the caller's board scope first: when it is not
  on an accessible board (or does not exist) the function returns
  `{:error, :not_found}` without writing. The write is delegated to
  `Kanban.Tasks.update_task/2`, whose changeset rejects a `target_id` on a
  non-goal-type task, so a work/defect task yields `{:error, changeset}`.
  """
  @spec assign_goal(Scope.t() | nil, Task.t(), DeliveryTarget.t()) ::
          {:ok, Task.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def assign_goal(scope, %Task{} = goal, %DeliveryTarget{} = target) do
    case fetch_scoped_task(scope, goal.id) do
      nil -> {:error, :not_found}
      %Task{} = fetched -> Tasks.update_task(fetched, %{target_id: target.id})
    end
  end

  @doc """
  Clears the target reference on `goal` (sets `target_id` to `nil`).

  Uses the same board-scoped fetch as `assign_goal/3`; returns
  `{:error, :not_found}` when the goal is missing or on an inaccessible board.
  """
  @spec unassign_goal(Scope.t() | nil, Task.t()) ::
          {:ok, Task.t()} | {:error, :not_found}
  def unassign_goal(scope, %Task{} = goal) do
    case fetch_scoped_task(scope, goal.id) do
      nil -> {:error, :not_found}
      %Task{} = fetched -> Tasks.update_task(fetched, %{target_id: nil})
    end
  end

  @doc """
  Lists the goal-type member tasks of `target` that live on boards the scoped
  user can access. A `nil` scope applies no board filter.
  """
  @spec list_member_goals(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_member_goals(scope, %DeliveryTarget{} = target) do
    Task
    |> where([t], t.type == :goal and t.target_id == ^target.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.all()
  end

  @doc """
  Lists goal-type tasks visible to `scope` that are not yet assigned to ANY
  target — the candidates the owner can attach to `target`.

  Only unassigned goals (`is_nil(target_id)`) qualify: a goal already on
  another target is deliberately excluded so assigning here cannot silently
  steal it from someone else's target. Reassignment requires unassigning the
  goal from its current target first. Board scoping mirrors
  `list_member_goals/2` exactly: a `nil` scope applies no board filter. The
  `target` argument is retained for API symmetry with `list_member_goals/2`.
  """
  @spec list_assignable_goals(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_assignable_goals(scope, %DeliveryTarget{} = _target) do
    Task
    |> where([t], t.type == :goal and is_nil(t.target_id))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.all()
  end

  @typedoc """
  One boards-page summary row for a delivery target: the target itself, its
  read-time derived `Kanban.Targets.Status`, and the aggregate child-task
  progress used by the targets strip.
  """
  @type target_summary :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100
        }

  @doc """
  Aggregates every accessible delivery target into the shape the boards-page
  targets strip renders.

  For each target visible to `scope` (via `list_targets/1`), this walks the
  target's board-scoped member goals (`list_member_goals/2`) and, per goal, its
  board-scoped child tasks (`Kanban.Tasks.get_task_children/2`) to produce:

    * `:status` — the read-time `Kanban.Targets.Status.derive/3` verdict
      (`:complete | :on_track | :at_risk | :missed`).
    * `:completed` / `:total` — the single completed/total fraction across ALL
      member goals' child tasks (a childless goal contributes `0/0` to this
      display fraction; when every goal is childless the fraction is `0/0`).
    * `:percentage` — `round(completed / total * 100)`, or `0` when `total == 0`.

  ## Scoping / security

  Every count is derived only from `scope`-filtered reads: `list_member_goals/2`
  restricts to goals on boards the caller can access, and `get_task_children/2`
  is board-scoped to that goal's own board (`goal.column.board_id`). A target
  whose goals live on inaccessible boards is already dropped by
  `list_targets/1`, so no cross-board child counts can leak into a summary.

  ## Time injection

  `today` is injected here at the impure context boundary (defaulting to
  `Date.utc_today/0`, mirroring the `_from`/`today` split in
  `Kanban.Agents.Metrics`). `Kanban.Targets.Status.derive/3` stays pure — it
  never reads the clock.

  This issues one member-goal query per target and one child query per goal
  (N+1). That is acceptable for the boards index, which refreshes only every
  30s; a batched version can replace it later without changing the shape.
  """
  @spec list_targets_with_status(Scope.t() | nil, Date.t()) :: [target_summary()]
  def list_targets_with_status(scope, today \\ Date.utc_today()) do
    scope
    |> list_targets()
    |> Enum.map(&summarize_target(scope, &1, today))
  end

  # --- Query / auth helpers -------------------------------------------------

  # Distinct target_ids reachable from the caller's accessible goal-type tasks.
  # Task-rooted so BoardScope can walk t -> column -> board_users; it adds the
  # column join itself, so no named binding is required from the caller. Used
  # as a subquery (`dt.id in subquery(...)`), which cannot fan out — the outer
  # DeliveryTarget query needs no `distinct`.
  defp member_target_ids_query(scope) do
    Task
    |> where([t], t.type == :goal and not is_nil(t.target_id))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> select([t], t.target_id)
  end

  # Fetches a single task by id under the caller's board scope. Returns nil
  # when the task is missing or on a board the caller cannot access. A nil /
  # userless scope applies no board filter (BoardScope no-ops).
  defp fetch_scoped_task(scope, id) do
    Task
    |> where([t], t.id == ^id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.one()
  end

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_), do: nil

  defp summarize_target(scope, %DeliveryTarget{} = target, today) do
    progress = target_goal_progress(scope, target)
    {completed, total} = aggregate_children(progress)

    %{
      target: target,
      status: Status.derive(target, progress, today),
      completed: completed,
      total: total,
      percentage: percentage(completed, total)
    }
  end

  # One Status.goal_progress snapshot per accessible member goal. :column is
  # preloaded so each goal's own board_id scopes its child-task query.
  defp target_goal_progress(scope, target) do
    scope
    |> list_member_goals(target)
    |> Repo.preload(:column)
    |> Enum.map(&goal_progress_entry/1)
  end

  defp goal_progress_entry(%Task{} = goal) do
    children = Tasks.get_task_children(goal.id, goal.column.board_id)

    %{
      completed_children: Enum.count(children, &(&1.status == :completed)),
      total_children: length(children),
      goal_complete?: goal.status == :completed
    }
  end

  # Display fraction across every member goal's child tasks (childless goals
  # add 0/0). Distinct from Status.derive's work-share, which counts a childless
  # goal as one unit — the two measures are intentionally separate.
  defp aggregate_children(progress) do
    Enum.reduce(progress, {0, 0}, fn gp, {done, total} ->
      {done + gp.completed_children, total + gp.total_children}
    end)
  end

  defp percentage(_completed, 0), do: 0
  defp percentage(completed, total), do: round(completed / total * 100)
end
