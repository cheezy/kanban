defmodule Kanban.Targets.Queries do
  @moduledoc """
  Board-scoped Ecto reads for delivery targets and their member goals.

  This module is the single place `Kanban.Targets` builds and runs its
  *board-scoped* reads — the owner-scoped ones deliberately stay behind, see
  below. It owns the fetching; `Kanban.Targets.Progress` owns the math over what
  is fetched, and `Kanban.Targets` composes the two into the public API. Nothing
  here computes progress, derives status, or maps a goal into a display shape —
  a function that does either belongs in `Progress`.

  ## Board scoping

  Every read here is board-scoped through the *member goals*, never through
  target ownership. A delivery target has no `board_id` of its own; it relates
  to boards only via the goal-type tasks that reference it through
  `tasks.target_id`. `member_target_ids_query/1` is the one place that
  relationship is expressed, and `list_targets/1`, `list_archived_targets/1`,
  and `get_target/2` all filter through it, so target visibility is defined
  exactly once.

  A `nil` scope (or `%Scope{user: nil}`) means "no board filter", matching the
  convention in `Kanban.Reviews` and `Kanban.Archives`.

  **The owner-scoped reads deliberately do not live here.** `get_owned_target/2`
  filters on `owner_id` rather than board membership, and stays in
  `Kanban.Targets` alongside the ownership checks it belongs with. The two
  scoping models coexist on purpose; mixing them in one module invites a shared
  "fetch a target" helper that silently drops one of the two checks.

  ## Ordering

  Every goal-listing function returns goals in ascending *numeric* identifier
  order (so `G18` precedes `G131`), tie-broken by `id` ascending, via
  `sort_by_identifier/1`. Callers depend on this order; `Progress` preserves it
  when mapping, it does not re-sort.

  ## The `_with_owner` variants

  `list_member_goals/2` preloads `:column` only; `list_member_goals_with_owner/2`
  preloads `[:column, :assigned_to]`. They are separate functions rather than one
  with an option because they back different pages with different query costs —
  merging them would silently add an `:assigned_to` preload to the boards strip
  and the /agents rollup, which fetch member goals on every refresh.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  @doc """
  Every *active* delivery target with at least one member goal on a board the
  scoped user can access, ordered by `target_date` (soonest first).
  """
  @spec list_targets(Scope.t() | nil) :: [DeliveryTarget.t()]
  def list_targets(scope) do
    DeliveryTarget
    |> where([dt], dt.id in subquery(member_target_ids_query(scope)))
    |> where([dt], is_nil(dt.archived_at))
    |> order_by([dt], asc: dt.target_date, asc: dt.id)
    |> Repo.all()
  end

  @doc """
  Every *archived* delivery target visible to the scoped user, newest archived
  first. The archived-only mirror of `list_targets/1`.
  """
  @spec list_archived_targets(Scope.t() | nil) :: [DeliveryTarget.t()]
  def list_archived_targets(scope) do
    DeliveryTarget
    |> where([dt], dt.id in subquery(member_target_ids_query(scope)))
    |> where([dt], not is_nil(dt.archived_at))
    |> order_by([dt], desc: dt.archived_at, desc: dt.id)
    |> Repo.all()
  end

  @doc """
  Fetches a single delivery target by id under the caller's board scope.

  Returns `{:ok, target}` when the target has a member goal on an accessible
  board, `{:error, :not_found}` otherwise (including a target with no member
  goals). Resolves archived targets too, so an archived target stays fetchable
  and therefore unarchivable.
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
  The goal-type member tasks of `target` on boards the scoped user can access,
  each with its `:column` preloaded (so `goal.column.board_id` scopes each
  goal's own child query downstream).
  """
  @spec list_member_goals(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_member_goals(scope, %DeliveryTarget{} = target) do
    Task
    |> where([t], t.type == :goal and t.target_id == ^target.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload(:column)
    |> Repo.all()
    |> sort_by_identifier()
  end

  @doc """
  Like `list_member_goals/2`, but preloads `[:column, :assigned_to]` so a caller
  rendering an owner column needs no further query.
  """
  @spec list_member_goals_with_owner(Scope.t() | nil, DeliveryTarget.t()) :: [Task.t()]
  def list_member_goals_with_owner(scope, %DeliveryTarget{} = target) do
    Task
    |> where([t], t.type == :goal and t.target_id == ^target.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([:column, :assigned_to])
    |> Repo.all()
    |> sort_by_identifier()
  end

  @doc """
  Goal-type tasks visible to `scope` that are not yet assigned to ANY target —
  the candidates an owner can attach.

  Only unassigned goals (`is_nil(target_id)`) qualify, so assigning cannot
  silently steal a goal from another target. Preloads nothing.
  """
  @spec list_assignable_goals(Scope.t() | nil, boolean()) :: [Task.t()]
  def list_assignable_goals(scope, exclude_archived?) do
    Task
    |> where([t], t.type == :goal and is_nil(t.target_id))
    |> maybe_exclude_archived(exclude_archived?)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.all()
    |> sort_by_identifier()
  end

  @doc """
  Like `list_assignable_goals/2`, but preloads `[:column, :assigned_to]` — note
  `list_assignable_goals/2` preloads neither.
  """
  @spec list_assignable_goals_with_owner(Scope.t() | nil, boolean()) :: [Task.t()]
  def list_assignable_goals_with_owner(scope, exclude_archived?) do
    Task
    |> where([t], t.type == :goal and is_nil(t.target_id))
    |> maybe_exclude_archived(exclude_archived?)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([:column, :assigned_to])
    |> Repo.all()
    |> sort_by_identifier()
  end

  @doc """
  Lead times (in seconds, as floats) of every completed non-goal task on the
  given boards — the historical sample behind a target's estimated completion
  date (`Kanban.Targets.Estimation`).

  Mirrors the filters of `Kanban.Metrics.get_lead_time_stats/2` (completed
  only, goal-type excluded, creation-to-completion diffed in SQL) with one
  deliberate deviation: the sample is **unwindowed** — all history, no
  `time_range` — because a pace estimate wants the full record, not a trailing
  window.

  Unlike every other read in this module it takes pre-resolved `board_ids`
  rather than a `Scope`: the ids come from the caller's already scope-filtered
  member goals (`goal.column.board_id`), so board scoping is upheld by
  construction. An empty id list short-circuits to `[]` without a query.
  """
  @spec list_completed_lead_times([pos_integer()]) :: [float()]
  def list_completed_lead_times([]), do: []

  def list_completed_lead_times(board_ids) when is_list(board_ids) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.type != ^:goal)
    |> select([t], fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, t.inserted_at))
    |> Repo.all()
    |> Enum.map(&decimal_to_float/1)
  end

  # EXTRACT(EPOCH ...) comes back as a Postgres numeric -> Decimal; downstream
  # arithmetic (Kanban.Targets.Estimation) needs plain numbers. Same
  # normalization Kanban.Metrics applies to its lead-time seconds.
  defp decimal_to_float(%Decimal{} = seconds), do: Decimal.to_float(seconds)
  defp decimal_to_float(seconds), do: seconds

  @doc """
  Fetches a single task by id under the caller's board scope, `:column`
  preloaded. Returns `nil` when the task is missing or on a board the caller
  cannot access. A nil / userless scope applies no board filter.
  """
  @spec fetch_scoped_task(Scope.t() | nil, integer() | String.t()) :: Task.t() | nil
  def fetch_scoped_task(scope, id) do
    Task
    |> where([t], t.id == ^id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload(:column)
    |> Repo.one()
  end

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

  # Drops archived goals (those with a set `archived_at`) when asked; a no-op
  # otherwise. Applied before BoardScope's joins so only the `t` binding exists.
  defp maybe_exclude_archived(query, true), do: where(query, [t], is_nil(t.archived_at))
  defp maybe_exclude_archived(query, false), do: query

  # Orders goals by the integer embedded in their identifier ("G18" -> 18) so
  # numeric order holds (G18 before G131) instead of the string order the bare
  # Repo.all() returns. Identifier numbers are generated per board and so are
  # not globally unique; `id` ascending is the deterministic tie-breaker. Parses
  # defensively: an identifier with no digits sorts as 0 rather than raising.
  defp sort_by_identifier(goals) do
    Enum.sort_by(goals, &{identifier_number(&1.identifier), &1.id})
  end

  defp identifier_number(identifier) do
    case Regex.run(~r/\d+/, identifier || "") do
      [digits] -> String.to_integer(digits)
      nil -> 0
    end
  end
end
