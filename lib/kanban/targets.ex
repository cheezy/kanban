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

  Archiving is a second, independent axis: `archived_at` (`nil` = active) gates
  `list_targets/1` and its derivatives, while `list_archived_targets/1` reads
  the archived set under the same board scoping. `get_target/2` and
  `get_owned_target/2` deliberately still resolve an archived target by id, so
  an archived target remains fetchable (and therefore unarchivable). Archiving
  itself (`archive_target/2`, `unarchive_target/2`) is *owner*-scoped rather
  than board-scoped — the same split `update_target/3` already uses.

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
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Progress
  alias Kanban.Targets.Queries
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @doc """
  Returns every *active* delivery target with at least one member goal on a
  board the scoped user can access, ordered by `target_date` (soonest first).

  Visibility flows through accessible member goals — a target whose goals are
  all on inaccessible boards, or which has no member goals, is omitted. A
  `nil` scope applies no board filter and returns every target that has at
  least one goal-type member.

  Archived targets (`archived_at` set) are excluded. Because every active-target
  listing is built on this query, archiving a target removes it from the boards
  strip (`list_targets_with_status/2`) and the /agents rollup
  (`list_targets_with_status_and_goals/2`) in one place. Use
  `list_archived_targets/1` to read them back.
  """
  @spec list_targets(Scope.t() | nil) :: [DeliveryTarget.t()]
  def list_targets(scope), do: Queries.list_targets(scope)

  @doc """
  Returns every *archived* delivery target visible to the scoped user, newest
  archived first.

  The board-scoped visibility model is identical to `list_targets/1` (a target
  is visible through its accessible member goals) — this is its archived-only
  mirror. `archived_at` orders the list descending, with `id` as a deterministic
  tiebreak.
  """
  @spec list_archived_targets(Scope.t() | nil) :: [DeliveryTarget.t()]
  def list_archived_targets(scope), do: Queries.list_archived_targets(scope)

  @doc """
  Fetches a single delivery target by id, scoped to the caller.

  Returns `{:ok, target}` when the target has a member goal on an accessible
  board, `{:error, :not_found}` otherwise (including a target with no member
  goals).
  """
  @spec get_target(Scope.t() | nil, integer() | String.t()) ::
          {:ok, DeliveryTarget.t()} | {:error, :not_found}
  def get_target(scope, id), do: Queries.get_target(scope, id)

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
  Archives a target the scoped user owns, stamping `archived_at`.

  Only a `:complete` target may be archived: completeness is derived at archive
  time from the target's member goals via `Kanban.Targets.Status.derive/3` —
  there is no stored status column to trust. The gate lives here in the context,
  not in the UI, so no LiveView or API caller can archive an incomplete target.

  Returns:

    * `{:ok, target}` — archived.
    * `{:error, :not_found}` — the target is missing, or is owned by another
      user. Ownership is checked *before* completeness, so a non-owner cannot
      distinguish "exists but incomplete" from "does not exist".
    * `{:error, :not_complete}` — owned, but its derived status is not
      `:complete`. A target with **no** member goals derives `:on_track` (an
      empty target has delivered nothing — see `Status.derive/3`), so it lands
      here too and can never be archived.

  Archiving is idempotent in effect: re-archiving an already-archived complete
  target simply re-stamps `archived_at`.
  """
  @spec archive_target(Scope.t() | nil, integer() | String.t()) ::
          {:ok, DeliveryTarget.t()}
          | {:error, :not_found}
          | {:error, :not_complete}
          | {:error, Ecto.Changeset.t()}
  def archive_target(scope, id) do
    with {:ok, target} <- get_owned_target(scope, id),
         :complete <- Progress.derive_target_status(scope, target) do
      target
      |> DeliveryTarget.archive_changeset(%{archived_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :not_found} -> {:error, :not_found}
      status when is_atom(status) -> {:error, :not_complete}
    end
  end

  @doc """
  Unarchives a target the scoped user owns, clearing `archived_at`.

  Owner-gated exactly as `archive_target/2`, but *not* gated on completeness —
  a target that drifted out of `:complete` while archived (a member goal
  reopened, a new goal assigned) must still be recoverable. Returns
  `{:error, :not_found}` when the target is missing or owned by another user.

  Unarchiving an already-active target is a no-op write that succeeds.
  """
  @spec unarchive_target(Scope.t() | nil, integer() | String.t()) ::
          {:ok, DeliveryTarget.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def unarchive_target(scope, id) do
    with {:ok, target} <- get_owned_target(scope, id) do
      target
      |> DeliveryTarget.archive_changeset(%{archived_at: nil})
      |> Repo.update()
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
          {:ok, Task.t()}
          | {:error, :not_found}
          | {:error, :not_authorized}
          | {:error, Ecto.Changeset.t()}
  def assign_goal(scope, %Task{} = goal, %DeliveryTarget{} = target) do
    case Queries.fetch_scoped_task(scope, goal.id) do
      nil ->
        {:error, :not_found}

      %Task{} = fetched ->
        with :ok <- authorize_goal_board_write(scope, fetched) do
          Tasks.update_task(fetched, %{target_id: target.id})
        end
    end
  end

  @doc """
  Clears the target reference on `goal` (sets `target_id` to `nil`).

  Uses the same board-scoped fetch as `assign_goal/3`; returns
  `{:error, :not_found}` when the goal is missing or on an inaccessible board.
  """
  @spec unassign_goal(Scope.t() | nil, Task.t()) ::
          {:ok, Task.t()} | {:error, :not_found} | {:error, :not_authorized}
  def unassign_goal(scope, %Task{} = goal) do
    case Queries.fetch_scoped_task(scope, goal.id) do
      nil ->
        {:error, :not_found}

      %Task{} = fetched ->
        with :ok <- authorize_goal_board_write(scope, fetched) do
          Tasks.update_task(fetched, %{target_id: nil})
        end
    end
  end

  @doc """
  Lists the goal-type member tasks of `target` that live on boards the scoped
  user can access, each with its `:column` preloaded (so `goal.column.board_id`
  is available to callers such as the target drill-down and
  `member_goal_children/1`). A `nil` scope applies no board filter.

  Goals are returned in ascending numeric identifier order (so `G18` precedes
  `G131`), tie-broken by `id` ascending, via `sort_by_identifier/1`.
  """
  @spec list_member_goals(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_member_goals(scope, %DeliveryTarget{} = target) do
    Queries.list_member_goals(scope, target)
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

  Candidates are returned in ascending numeric identifier order (so `G18`
  precedes `G131`), tie-broken by `id` ascending, matching
  `list_member_goals/2`.

  ## Options

    * `:exclude_archived` — when `true`, archived goals (those with a set
      `archived_at`) are dropped from the result. Defaults to `false`, so the
      historic behavior (archived goals included) is unchanged.
  """
  @spec list_assignable_goals(Scope.t() | nil, DeliveryTarget.t(), keyword()) :: [Task.t()]
  def list_assignable_goals(scope, %DeliveryTarget{} = _target, opts \\ []) do
    Queries.list_assignable_goals(scope, Keyword.get(opts, :exclude_archived, false))
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

  Details are returned in ascending numeric identifier order (so `G18` precedes
  `G131`), tie-broken by `id` ascending, matching `list_member_goals/2`. The
  goals are sorted before `goal_detail_views/1` maps them, which preserves the
  order.
  """
  @spec list_member_goal_details(Scope.t() | nil, DeliveryTarget.t()) ::
          [goal_progress_detail()]
  def list_member_goal_details(scope, %DeliveryTarget{} = target) do
    scope
    |> Queries.list_member_goals_with_owner(target)
    |> Progress.goal_detail_views()
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

  Details are returned in ascending numeric identifier order (so `G18` precedes
  `G131`), tie-broken by `id` ascending, matching `list_assignable_goals/2`. The
  goals are sorted before `goal_detail_views/1` maps them, which preserves the
  order.

  ## Options

    * `:exclude_archived` — when `true`, archived goals (those with a set
      `archived_at`) are dropped. Defaults to `false`, so the historic behavior
      (archived goals included) is unchanged. This backs the Edit Target page's
      "hide archived goals" checkbox.
  """
  @spec list_assignable_goal_details(Scope.t() | nil, DeliveryTarget.t(), keyword()) ::
          [goal_progress_detail()]
  def list_assignable_goal_details(scope, %DeliveryTarget{} = _target, opts \\ []) do
    scope
    |> Queries.list_assignable_goals_with_owner(Keyword.get(opts, :exclude_archived, false))
    |> Progress.goal_detail_views()
  end

  @typedoc "See `Kanban.Targets.Progress.target_summary/0`."
  @type target_summary :: Progress.target_summary()

  @typedoc "See `Kanban.Targets.Progress.target_summary_with_goals/0`."
  @type target_summary_with_goals :: Progress.target_summary_with_goals()

  @typedoc "See `Kanban.Targets.Progress.goal_flow/0`."
  @type goal_flow :: Progress.goal_flow()

  @typedoc "See `Kanban.Targets.Progress.goal_progress_detail/0`."
  @type goal_progress_detail :: Progress.goal_progress_detail()

  @typedoc "See `Kanban.Targets.Progress.target_progress/0`."
  @type target_progress :: Progress.target_progress()

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
    * `:estimated_completion_date` — `today` plus remaining tasks × the 50th
      percentile (median) lead time of ALL historical completed non-goal tasks on the
      member goals' boards (`Kanban.Targets.Estimation`). `nil` when the
      target is `:complete`, nothing remains, or there is no historical
      sample — `nil` means the strip renders no estimate at all. Costs one
      extra lead-time query per estimable target on top of the N+1 documented
      below.

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
    |> Enum.map(&Progress.summarize_target(scope, &1, today))
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

  Unlike `list_targets_with_status/2`, `:estimated_completion_date` is always
  `nil` here — the /agents rollup refreshes constantly, and estimating would
  add a lead-time query per target (see `Kanban.Targets.Progress`'s
  "Estimated completion" section).

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
      {summary, goals} = Progress.summarize_target_with_goals(scope, target, today)
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
      `:percentage`. Its `:estimated_completion_date` is always `nil` — the
      drill-down (which also serves archived, necessarily-complete targets)
      does not estimate.
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
    Progress.build_target_progress(scope, target, today)
  end

  def get_target_progress(scope, id, today) when is_integer(id) or is_binary(id) do
    case get_target(scope, id) do
      {:ok, target} -> Progress.build_target_progress(scope, target, today)
      {:error, :not_found} = error -> error
    end
  end

  # --- Query / auth helpers -------------------------------------------------

  # Writing a goal's `target_id` lands on the goal's board, so board-write
  # access (:owner or :modify) on THAT board is required — membership alone is
  # not enough. The target-owner check upstream does not cover this: a target
  # owner who is only a read-only member of the goal's board must not be able
  # to set or clear the goal's target linkage (W1677 M1).
  defp authorize_goal_board_write(scope, %Task{column: %{board_id: board_id}}) do
    case scope_user(scope) do
      nil ->
        {:error, :not_authorized}

      %{id: user_id} ->
        if Boards.get_user_access(board_id, user_id) in [:owner, :modify] do
          :ok
        else
          {:error, :not_authorized}
        end
    end
  end

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_), do: nil
end
