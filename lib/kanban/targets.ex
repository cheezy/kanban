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
  user can access, each with its `:column` preloaded (so `goal.column.board_id`
  is available to callers such as the target drill-down and
  `member_goal_children/1`). A `nil` scope applies no board filter.
  """
  @spec list_member_goals(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_member_goals(scope, %DeliveryTarget{} = target) do
    Task
    |> where([t], t.type == :goal and t.target_id == ^target.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload(:column)
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

  ## Options

    * `:exclude_archived` — when `true`, archived goals (those with a set
      `archived_at`) are dropped from the result. Defaults to `false`, so the
      historic behavior (archived goals included) is unchanged.
  """
  @spec list_assignable_goals(Scope.t() | nil, DeliveryTarget.t(), keyword()) :: [Task.t()]
  def list_assignable_goals(scope, %DeliveryTarget{} = _target, opts \\ []) do
    Task
    |> where([t], t.type == :goal and is_nil(t.target_id))
    |> maybe_exclude_archived(Keyword.get(opts, :exclude_archived, false))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.all()
  end

  @doc """
  Like `list_member_goals/2`, but returns each member goal as a
  `goal_progress_detail/0` (the goal plus its `:flow`/`completed`/`total`/
  `percentage` child fraction) instead of a bare `Task`.

  Every returned goal has both `:column` and `:assigned_to` preloaded so
  callers (such as the Edit Target page's member-goals table) can read
  `goal.column.board_id` and `goal.assigned_to` without further queries. Board
  scoping and per-goal child-count scoping match `list_member_goals/2` exactly;
  a `nil` scope applies no board filter.
  """
  @spec list_member_goal_details(Scope.t() | nil, DeliveryTarget.t()) ::
          [goal_progress_detail()]
  def list_member_goal_details(scope, %DeliveryTarget{} = target) do
    Task
    |> where([t], t.type == :goal and t.target_id == ^target.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([:column, :assigned_to])
    |> Repo.all()
    |> goal_detail_views()
  end

  @doc """
  Like `list_assignable_goals/2`, but returns each candidate goal as a
  `goal_progress_detail/0` instead of a bare `Task`.

  Every returned goal has both `:column` and `:assigned_to` preloaded — note
  `list_assignable_goals/2` preloads neither — so the Edit Target page's
  assignable-goals table can render progress and owner without running Ecto in
  the LiveView. Only unassigned goals (`is_nil(target_id)`) qualify, and board
  scoping matches `list_assignable_goals/2` exactly; a `nil` scope applies no
  board filter.

  ## Options

    * `:exclude_archived` — when `true`, archived goals (those with a set
      `archived_at`) are dropped. Defaults to `false`, so the historic behavior
      (archived goals included) is unchanged. This backs the Edit Target page's
      "hide archived goals" checkbox.
  """
  @spec list_assignable_goal_details(Scope.t() | nil, DeliveryTarget.t(), keyword()) ::
          [goal_progress_detail()]
  def list_assignable_goal_details(scope, %DeliveryTarget{} = _target, opts \\ []) do
    Task
    |> where([t], t.type == :goal and is_nil(t.target_id))
    |> maybe_exclude_archived(Keyword.get(opts, :exclude_archived, false))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([:column, :assigned_to])
    |> Repo.all()
    |> goal_detail_views()
  end

  # Drops archived goals (those with a set `archived_at`) when asked; a no-op
  # otherwise. Applied before BoardScope's joins so only the `t` binding exists.
  defp maybe_exclude_archived(query, true), do: where(query, [t], is_nil(t.archived_at))
  defp maybe_exclude_archived(query, false), do: query

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

  @typedoc """
  A `target_summary/0` that also carries the target's member goal tasks under
  `:goals` (`:column` preloaded, same structs `list_member_goals/2` returns).
  Returned by `list_targets_with_status_and_goals/2` so a caller needing both
  the status summary and the raw goal list fetches the member goals once.
  """
  @type target_summary_with_goals :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100,
          goals: [Task.t()]
        }

  @typedoc """
  A single goal's child-task flow, bucketed by the child's *column name*
  (not `task.status`), mirroring the boards Goals view. Every key is present
  even when zero, and `:total` is the sum of the five column buckets.
  """
  @type goal_flow :: %{
          done: non_neg_integer(),
          review: non_neg_integer(),
          doing: non_neg_integer(),
          ready: non_neg_integer(),
          backlog: non_neg_integer(),
          total: non_neg_integer()
        }

  @typedoc """
  One member goal's progress detail: the goal task, its column-bucketed
  `:flow` map, and its completed/total/percentage child fraction.
  """
  @type goal_progress_detail :: %{
          goal: Task.t(),
          flow: goal_flow(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100
        }

  @typedoc """
  The full progress payload for a single target: the same aggregate
  `target_summary/0` the boards strip uses, plus a per-goal breakdown.
  """
  @type target_progress :: %{
          summary: target_summary(),
          goals: [goal_progress_detail()]
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

  @doc """
  Like `list_targets_with_status/2`, but each summary map also carries a
  `:goals` key holding the target's member goal tasks (`[Task.t()]`, `:column`
  preloaded — the same structs, in the same order, that `list_member_goals/2`
  returns).

  `Kanban.Targets.DeliveryRollup.build/2` needs both the per-target status
  summary and the raw member-goal list. Fetching them together here means the
  member-goal query runs once per target instead of twice — the summary's own
  fetch plus a second `list_member_goals/2` call the rollup used to make. The
  `:status`/`:completed`/`:total`/`:percentage` fields are identical to a
  `list_targets_with_status/2` row; only the extra `:goals` key is added, so
  existing callers of `list_targets_with_status/2` are unaffected.

  Board scoping, the per-goal child query (N+1) characteristics, and the
  `today` injection are identical to `list_targets_with_status/2`.
  """
  @spec list_targets_with_status_and_goals(Scope.t() | nil, Date.t()) :: [
          target_summary_with_goals()
        ]
  def list_targets_with_status_and_goals(scope, today \\ Date.utc_today()) do
    scope
    |> list_targets()
    |> Enum.map(fn target ->
      {summary, goals} = summarize_target_with_goals(scope, target, today)
      Map.put(summary, :goals, goals)
    end)
  end

  @doc """
  Loads one target's full progress payload — the aggregate summary the boards
  strip renders *and* a per-goal breakdown — in a single context call, so a
  LiveView (the target hero and its goals table) never runs Ecto queries.

  `target_or_id` may be a `%DeliveryTarget{}` the caller already holds (the
  common case — the drill-down LiveView fetches it via `get_owned_target/2`),
  or a target id, which is resolved through the board-scoped `get_target/2`.

  Returns `%{summary: target_summary(), goals: [goal_progress_detail()]}`:

    * `:summary` — identical in shape and meaning to a `list_targets_with_status/2`
      row: `:status` (`Kanban.Targets.Status.derive/3`), the aggregate
      `:completed`/`:total` child fraction across all member goals, and
      `:percentage`.
    * `:goals` — one entry per accessible member goal, each carrying the goal
      task, its column-bucketed `:flow` map (`%{done, review, doing, ready,
      backlog, total}`), and that goal's own `:completed`/`:total`/`:percentage`.

  A target with no accessible member goals returns a `0/0`, `0%`, `:on_track`
  summary and an empty `:goals` list — it never raises. When `target_or_id` is
  an id that resolves to no accessible target, `{:error, :not_found}` is
  returned (mirroring `get_target/2`).

  ## Scoping / security

  Board scoping is enforced exactly as in `list_targets_with_status/2`:
  `list_member_goals/2` drops goals on boards the caller cannot access, and each
  goal's child query is board-scoped to that goal's own board — so no
  cross-board child counts can leak. The id form additionally re-checks target
  visibility through `get_target/2` before any child read.

  Like `list_targets_with_status/2`, `today` is injected at this impure
  boundary (defaulting to `Date.utc_today/0`) so `Kanban.Targets.Status.derive/3`
  stays pure. One member-goal query per call plus one child query per goal
  (N+1) — acceptable for a single drill-down page, matching the module's
  documented stance.
  """
  @spec get_target_progress(
          Scope.t() | nil,
          DeliveryTarget.t() | integer() | String.t(),
          Date.t()
        ) :: target_progress() | {:error, :not_found}
  def get_target_progress(scope, target_or_id, today \\ Date.utc_today())

  def get_target_progress(scope, %DeliveryTarget{} = target, today) do
    build_target_progress(scope, target, today)
  end

  def get_target_progress(scope, id, today) when is_integer(id) or is_binary(id) do
    case get_target(scope, id) do
      {:ok, target} -> build_target_progress(scope, target, today)
      {:error, :not_found} = error -> error
    end
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
    {summary, _goals} = summarize_target_with_goals(scope, target, today)
    summary
  end

  # Summarizes a target AND returns its member goals, fetching the member-goal
  # list exactly once. Both the aggregate summary (`summarize_target/3`, the
  # boards strip) and callers that need the raw `[Task.t()]` goal list
  # (`DeliveryRollup`, via `list_targets_with_status_and_goals/2`) share this
  # single fetch, so the member-goal query runs once per target instead of
  # twice. list_member_goals/2 preloads :column, so each goal's own board_id
  # scopes its batched child-task query in `member_goal_children/1`.
  defp summarize_target_with_goals(scope, %DeliveryTarget{} = target, today) do
    goals = list_member_goals(scope, target)
    children_by_goal = member_goal_children(goals)

    progress =
      Enum.map(goals, fn goal ->
        progress_shape(goal, Map.get(children_by_goal, goal.id, []))
      end)

    {summarize_progress(target, progress, today), goals}
  end

  # Fetches every member goal's child tasks (archived included, per D124) in one
  # query per distinct board instead of one per goal, bounding the per-goal N+1
  # the rollup used to fire on every /agents refresh (D125). list_member_goals/2
  # preloads :column, so each goal's board scopes its own children.
  defp member_goal_children(goals) do
    goals
    |> Enum.map(&{&1.id, &1.column.board_id})
    |> Tasks.get_children_including_archived_by_parent()
  end

  # The aggregate `target_summary/0` for a target given its member goals'
  # `Status`-progress shapes. Shared by `summarize_target/3` (the boards strip)
  # and `build_target_progress/3` (the drill-down) so the status/fraction math
  # lives in exactly one place.
  defp summarize_progress(%DeliveryTarget{} = target, progress, today) do
    {completed, total} = aggregate_children(progress)

    %{
      target: target,
      status: Status.derive(target, progress, today),
      completed: completed,
      total: total,
      percentage: percentage(completed, total)
    }
  end

  # The `Kanban.Targets.Status.derive/3` progress shape for one goal, computed
  # once here so the aggregate (`summarize_target/3`, `get_target_progress/3`)
  # and the per-goal breakdown never duplicate the completed/total math.
  #
  # `children` includes archived children (fetched via
  # `get_task_children_including_archived/2`): archived-completed work is
  # credited toward the fraction, archived-incomplete work is treated as removed
  # (dropped from both counts). See D124.
  defp progress_shape(%Task{} = goal, children) do
    credited = Enum.filter(children, &credited_child?/1)

    %{
      completed_children: Enum.count(credited, &(&1.status == :completed)),
      total_children: length(credited),
      goal_complete?: goal_complete?(goal)
    }
  end

  # A child counts toward the goal's completed/total fraction when it is live
  # (not archived) or archived-but-completed. Archived-incomplete children
  # (wontdo/duplicate/deferred/cancelled) are removed work and drop out of the
  # fraction entirely rather than dragging the denominator down. See D124.
  defp credited_child?(%Task{archived_at: nil}), do: true
  defp credited_child?(%Task{status: status}), do: status == :completed

  # A goal is complete when its own status is :completed, or it has been
  # archived as finished work — archive_reason :completed, or legacy nil. A goal
  # archived as :wontdo/:duplicate/:deferred/:cancelled is abandoned, not
  # complete, so it must not credit the target toward :complete. See D124.
  defp goal_complete?(%Task{status: :completed}), do: true
  defp goal_complete?(%Task{archived_at: nil}), do: false
  defp goal_complete?(%Task{archive_reason: reason}), do: reason in [:completed, nil]

  # Builds the full progress payload for one already-resolved target. The
  # target-level aggregate and the per-goal breakdown both derive from the
  # single `details` list — one child fetch per goal — reusing the shared
  # `aggregate_children/1`, `percentage/2`, and `Status.derive/3` helpers.
  defp build_target_progress(scope, %DeliveryTarget{} = target, today) do
    details =
      scope
      |> list_member_goals(target)
      |> goal_detail_entries()

    progress = Enum.map(details, & &1.progress)

    %{
      summary: summarize_progress(target, progress, today),
      goals: Enum.map(details, &goal_detail_view/1)
    }
  end

  # Maps a list of `:column`-preloaded goals to their internal detail entries
  # (one child fetch each). Shared by `build_target_progress/3` (which also
  # needs each entry's `:progress`) and `goal_detail_views/1`.
  defp goal_detail_entries(goals), do: Enum.map(goals, &goal_detail_entry/1)

  # Maps a list of `:column`-preloaded goals to the public
  # `goal_progress_detail/0` shape. The DRY entry point for
  # `list_member_goal_details/2` and `list_assignable_goal_details/2`.
  defp goal_detail_views(goals) do
    goals
    |> goal_detail_entries()
    |> Enum.map(&goal_detail_view/1)
  end

  # The public per-goal detail shape — drops the internal `:progress` key that
  # only `Status.derive/3` needs.
  defp goal_detail_view(detail) do
    Map.take(detail, [:goal, :flow, :completed, :total, :percentage])
  end

  # One member goal's detail: fetches its child tasks once (with `:column`
  # preloaded for flow bucketing), then derives the Status progress shape, the
  # column-bucketed flow map, and the completed/total/percentage fraction from
  # that single fetch.
  defp goal_detail_entry(%Task{} = goal) do
    children =
      goal.id
      |> Tasks.get_task_children_including_archived(goal.column.board_id)
      |> Repo.preload(:column)

    progress = progress_shape(goal, children)

    %{
      goal: goal,
      flow: flow_map(Enum.filter(children, &credited_child?/1)),
      completed: progress.completed_children,
      total: progress.total_children,
      percentage: percentage(progress.completed_children, progress.total_children),
      progress: progress
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

  @empty_flow %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

  # Buckets a goal's child tasks into %{done, review, doing, ready, backlog,
  # total} by each child's column NAME (never task.status), matching the boards
  # Goals view. Children must have :column preloaded.
  defp flow_map(children) do
    Enum.reduce(children, @empty_flow, fn child, acc ->
      bucket = flow_bucket_for(child)

      acc
      |> Map.update!(bucket, &(&1 + 1))
      |> Map.update!(:total, &(&1 + 1))
    end)
  end

  # Archived-completed children are credited into the progress fraction but are
  # hidden from the board, so their stale column must not drive a bucket — count
  # them as :done. Live children bucket by their column name as before. See D124.
  defp flow_bucket_for(%Task{archived_at: at, column: column}) do
    if is_nil(at), do: flow_bucket(column), else: :done
  end

  # Maps a column name to its flow bucket. Duplicates the tiny name→status case
  # from KanbanWeb.BoardLive.Show.column_status/1 deliberately: a context must
  # not depend on the web layer. Any unknown/nil column falls back to :backlog.
  defp flow_bucket(%{name: name}) when is_binary(name) do
    case String.downcase(name) do
      "backlog" -> :backlog
      "ready" -> :ready
      "doing" -> :doing
      "review" -> :review
      "done" -> :done
      _ -> :backlog
    end
  end

  defp flow_bucket(_), do: :backlog
end
