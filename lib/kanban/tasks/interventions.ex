defmodule Kanban.Tasks.Interventions do
  @moduledoc """
  Authorization and write operations for in-page interventions on a goal.

  An intervention mutates a goal (and its not-started children) directly from
  the /agents page. `can_intervene?/2` is the single authorization gate both
  the context write ops and the LiveView action guard call before mutating
  anything, so the two paths cannot drift apart. The actor set the
  requirements name is "the goal's delivery-target owner OR the goal's board
  owner", and the scoped user must ALSO pass the same board-access guard the
  /agents reads use — belonging to the goal's board.

  `reassign_goal_unstarted/3` is the first write action: it reassigns the goal
  and only its not-started, unclaimed children (a not-started column, see
  `Kanban.Columns.Stage`, with status `:open`) to a new user, atomically, skipping any child claimed since the
  caller inspected the goal. Eligibility is re-read inside the transaction
  under a row lock so a race with an agent claim is caught rather than silently
  overwritten — this is deliberately narrower than the `Lifecycle` assignment
  cascade, which touches ALL non-completed children (wrong scope here).

  Ownership is delegated to the existing predicates rather than reimplemented:
  `Kanban.Targets.owner?/2` and `Kanban.Boards.owner?/2`. Board accessibility
  reuses `Kanban.Queries.BoardScope`. The predicate fails closed — a `nil`
  scope, a scope without a user, or a goal on an inaccessible board all return
  `false`.

  The transactions themselves — the `FOR UPDATE` candidate re-read, the
  `Ecto.Multi` of updates and history rows, and the broadcast — live in
  `Kanban.Tasks.InterventionTransactions`, which performs no authorization.
  Every public function here checks `can_intervene?/2` before calling it, and
  keeps the `task_assigned` notification and the `Kanban.Tasks.GoalTelemetry`
  side effects.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications.Events
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.InterventionTransactions
  alias Kanban.Tasks.Task

  @allowed_priorities [:low, :medium, :high, :critical]

  @doc """
  Returns `true` when the scoped user may run an in-page intervention on `goal`.

  The user must be the owner of the goal's delivery target OR the owner of the
  goal's board, AND the goal must be on a board the scoped user can access.
  Returns `false` for a `nil` scope, a scope whose user is `nil`, a non-owner,
  or a goal on a board the user cannot access.
  """
  @spec can_intervene?(Scope.t() | nil, Task.t()) :: boolean()
  def can_intervene?(nil, _goal), do: false
  def can_intervene?(%Scope{user: nil}, _goal), do: false

  def can_intervene?(%Scope{user: user} = scope, %Task{} = goal) do
    goal = Repo.preload(goal, [:target, column: :board])

    owner?(goal, user) and accessible?(scope, goal)
  end

  defp owner?(%Task{target: %DeliveryTarget{} = target} = goal, user) do
    Targets.owner?(target, user) or Boards.owner?(goal.column.board, user)
  end

  defp owner?(%Task{} = goal, user) do
    Boards.owner?(goal.column.board, user)
  end

  defp accessible?(scope, %Task{} = goal) do
    Task
    |> where(id: ^goal.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.exists?()
  end

  @doc """
  Reassigns `goal` and its not-started, unclaimed children to
  `new_assigned_to_id`, atomically.

  Only children on a not-started column (Backlog/Ready, or a custom column
  before the board's first Doing/Review column; see `Kanban.Columns.Stage`)
  with status `:open` are moved; any
  such child that has been claimed (status `:in_progress`) since the caller
  inspected the goal is left untouched and surfaced in `:skipped`. A child that
  a concurrent claim has already moved *out* of a not-started column is no longer a
  candidate at all, so it appears in neither list — it is simply not touched.
  Children in Doing, Review, or Done are never considered. Assignment history
  is recorded for the goal and each moved child.

  `new_assigned_to_id` must reference an enabled user who is a member of the
  goal's board (or be `nil` to unassign); assigning work to an off-board,
  disabled (D385) or nonexistent user is rejected. The scoped user must pass `can_intervene?/2`.
  Returns:

    * `{:ok, %{moved: [tasks], skipped: [tasks]}}` — `moved` is the goal plus
      every reassigned child; `skipped` is the Backlog/Ready children that were
      already claimed.
    * `{:error, :unauthorized}` — the scope may not intervene on this goal.
    * `{:error, :assignee_not_on_board}` — the assignee is not a board member,
      or is a board member whose account is disabled.
    * `{:error, changeset}` — a write failed; the whole transaction rolled back.
  """
  @spec reassign_goal_unstarted(Scope.t() | nil, Task.t(), integer() | nil) ::
          {:ok, %{moved: [Task.t()], skipped: [Task.t()]}}
          | {:error, :unauthorized | :assignee_not_on_board | Ecto.Changeset.t()}
  def reassign_goal_unstarted(scope, %Task{} = goal, new_assigned_to_id) do
    if can_intervene?(scope, goal) do
      goal
      |> InterventionTransactions.reassign(new_assigned_to_id)
      |> notify_reassigned(goal, scope)
      |> GoalTelemetry.reassigned(scope)
    else
      {:error, :unauthorized}
    end
  end

  # One task_assigned notification for the goal, never one per moved child.
  # Hooked here rather than in Kanban.Tasks.InterventionTransactions, whose
  # finalize step undo and reprioritize share.
  defp notify_reassigned(
         {:ok, %{moved: [%Task{assigned_to_id: new_id} = updated_goal | _]}} = result,
         %Task{assigned_to_id: old_id},
         %Scope{user: actor}
       )
       when new_id != old_id do
    Events.task_assigned(updated_goal, actor)
    result
  end

  defp notify_reassigned(result, _goal, _scope), do: result

  @doc """
  Read-only preview of what `reassign_goal_unstarted/3` would move for `goal`.

  Gated by `can_intervene?/2` (scope-first, like the write) — returns
  `{:error, :unauthorized}` for a scope that may not intervene, so the preview
  cannot read a goal's children or board members without the same authorization
  the write enforces.

  On success returns `{:ok, %{goal, children, members}}`: the goal (with its
  `:target` and `column: :board` preloaded), the not-started, unclaimed children
  that would be reassigned, and the goal's board members and org-admins (candidate assignees for
  the owner selector). Performs no row locking — the `FOR UPDATE` guard applies
  only inside the write transaction, so the previewed children are a best-effort
  snapshot; the authoritative moved and skipped sets come from
  `reassign_goal_unstarted/3` at confirm time.
  """
  @spec reassign_preview(Scope.t() | nil, Task.t()) ::
          {:ok, %{goal: Task.t(), children: [Task.t()], members: [map()]}}
          | {:error, :unauthorized}
  def reassign_preview(scope, %Task{} = goal) do
    with {:ok, goal, children} <- intervention_preview(scope, goal) do
      {:ok, %{goal: goal, children: children, members: candidate_assignees(goal.column.board)}}
    end
  end

  # The board's members, then the org-admins of its Organization who reach it
  # without a row (Kanban.Boards.Assignable), in the board_users shape the
  # dialog reads.
  defp candidate_assignees(board) do
    derived = board.id |> Boards.list_derived_assignees() |> Enum.map(&%{user: &1})
    Boards.list_board_users(board) ++ derived
  end

  @doc """
  Read-only preview of what `reprioritize_goal_unstarted/3` would change for
  `goal`.

  Gated by `can_intervene?/2` (scope-first, like the write and
  `reassign_preview/2`) — returns `{:error, :unauthorized}` for a scope that may
  not intervene, so the preview cannot read a goal's children without the same
  authorization the write enforces.

  On success returns `{:ok, %{goal, children}}`: the goal (with its `:target` and
  `column: :board` preloaded) and the not-started, unclaimed children that would
  be reprioritized. Like `reassign_preview/2` it performs no row locking — the
  previewed children are a best-effort snapshot; the authoritative moved and
  skipped sets come from `reprioritize_goal_unstarted/3` at confirm time. The
  member list `reassign_preview/2` returns is omitted, since a priority change
  needs no assignee selector.
  """
  @spec reprioritize_preview(Scope.t() | nil, Task.t()) ::
          {:ok, %{goal: Task.t(), children: [Task.t()]}}
          | {:error, :unauthorized}
  def reprioritize_preview(scope, %Task{} = goal) do
    with {:ok, goal, children} <- intervention_preview(scope, goal) do
      {:ok, %{goal: goal, children: children}}
    end
  end

  # Shared read for the goal-level intervention previews: authorizes via
  # can_intervene?/2 (scope-first), then returns the goal (with :target and
  # column: :board preloaded) and the not-started, unclaimed children that would
  # actually move. `InterventionTransactions.preview_children/1` applies the same
  # `:open` eligibility the write uses, so the preview lists exactly the children
  # that would move (claimed ones are excluded — they would be skipped). No row
  # locking; the `FOR UPDATE` guard applies only inside the write transaction.
  defp intervention_preview(scope, %Task{} = goal) do
    if can_intervene?(scope, goal) do
      goal = Repo.preload(goal, [:target, column: :board])

      {:ok, goal, InterventionTransactions.preview_children(goal)}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Sets `goal` and its not-started, unclaimed children to `new_priority`,
  atomically.

  `new_priority` must be one of `#{inspect(@allowed_priorities)}` (an atom, or
  the equivalent string); any other value returns `{:error, :invalid_priority}`
  without touching the database. Child selection is identical to
  `reassign_goal_unstarted/3` (not-started column, status `:open`, re-read
  under a row lock), so the two actions stay consistent — a claimed child is
  surfaced in `:skipped`, and Doing/Review/Done children are never considered.
  Priority-change history is recorded for the goal and each moved child.

  The scoped user must pass `can_intervene?/2`. Returns:

    * `{:ok, %{moved: [tasks], skipped: [tasks]}}` — `moved` is the goal plus
      every reprioritized child; `skipped` is the already-claimed children.
    * `{:error, :unauthorized}` — the scope may not intervene on this goal.
    * `{:error, :invalid_priority}` — `new_priority` is not an allowed value.
  """
  @spec reprioritize_goal_unstarted(Scope.t() | nil, Task.t(), atom() | String.t()) ::
          {:ok, %{moved: [Task.t()], skipped: [Task.t()]}}
          | {:error, :unauthorized | :invalid_priority | Ecto.Changeset.t()}
  def reprioritize_goal_unstarted(scope, %Task{} = goal, new_priority) do
    if can_intervene?(scope, goal) do
      with {:ok, priority} <- validate_priority(new_priority) do
        goal
        |> InterventionTransactions.reprioritize(priority)
        |> GoalTelemetry.reprioritized(scope, priority)
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Restores a specific, previously-moved set of tasks to their prior
  `assigned_to_id` — the undo of `reassign_goal_unstarted/3`.

  `restorations` is a list of `%{id: task_id, prior: prior_assigned_to_id}` (the
  goal's own entry included). Unlike the forward op, this touches **exactly** the
  given ids — never the goal's current not-started set — and restores each task
  to **its own** prior value, so a task that never moved (a since-added child, or
  one that was skipped originally) is never affected. Only ids still on a
  Backlog/Ready column with status `:open` are restored (the goal itself is
  always restored); any that were claimed/moved since are surfaced in `:skipped`.
  Assignment history is recorded for each restored task. Gated by
  `can_intervene?/2`; the caller supplies the authoritative server-side snapshot.

  Returns `{:ok, %{moved: restored, skipped: unrestorable}}` or
  `{:error, :unauthorized}`.
  """
  @spec undo_reassignment(Scope.t() | nil, Task.t(), [%{id: integer(), prior: integer() | nil}]) ::
          {:ok, %{moved: [Task.t()], skipped: [Task.t()]}} | {:error, :unauthorized}
  def undo_reassignment(scope, %Task{} = goal, restorations) do
    run_undo(scope, goal, restorations, :assigned_to_id)
  end

  @doc """
  Restores a specific, previously-moved set of tasks to their prior `priority` —
  the undo of `reprioritize_goal_unstarted/3`. Same set-scoped, per-task
  semantics and return shape as `undo_reassignment/3`; priority-change history is
  recorded for each restored task.
  """
  @spec undo_reprioritization(Scope.t() | nil, Task.t(), [%{id: integer(), prior: atom()}]) ::
          {:ok, %{moved: [Task.t()], skipped: [Task.t()]}} | {:error, :unauthorized}
  def undo_reprioritization(scope, %Task{} = goal, restorations) do
    run_undo(scope, goal, restorations, :priority)
  end

  defp validate_priority(priority) when priority in @allowed_priorities, do: {:ok, priority}

  defp validate_priority(priority) when is_binary(priority) do
    case Enum.find(@allowed_priorities, fn allowed -> Atom.to_string(allowed) == priority end) do
      nil -> {:error, :invalid_priority}
      allowed -> {:ok, allowed}
    end
  end

  defp validate_priority(_priority), do: {:error, :invalid_priority}

  # Authorizes, then builds the per-task priors and the moved child ids (goal
  # excluded — it is always restored) for `InterventionTransactions.undo/4`,
  # which restores each task to its own prior value and touches nothing else.
  defp run_undo(scope, goal, restorations, field) do
    if can_intervene?(scope, goal) do
      priors = Map.new(restorations, &{&1.id, &1.prior})
      child_ids = restorations |> Enum.map(& &1.id) |> Enum.reject(&(&1 == goal.id))

      goal
      |> InterventionTransactions.undo(child_ids, field, priors)
      |> GoalTelemetry.undone(field, scope)
    else
      {:error, :unauthorized}
    end
  end
end
