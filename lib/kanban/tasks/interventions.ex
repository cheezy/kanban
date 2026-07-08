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
  and only its not-started, unclaimed children (Backlog/Ready column, status
  `:open`) to a new user, atomically, skipping any child claimed since the
  caller inspected the goal. Eligibility is re-read inside the transaction
  under a row lock so a race with an agent claim is caught rather than silently
  overwritten — this is deliberately narrower than the `Lifecycle` assignment
  cascade, which touches ALL non-completed children (wrong scope here).

  Ownership is delegated to the existing predicates rather than reimplemented:
  `Kanban.Targets.owner?/2` and `Kanban.Boards.owner?/2`. Board accessibility
  reuses `Kanban.Queries.BoardScope`. The predicate fails closed — a `nil`
  scope, a scope without a user, or a goal on an inaccessible board all return
  `false`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @not_started_columns ["Backlog", "Ready"]
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

  Only children on a Backlog/Ready column with status `:open` are moved; any
  such child that has been claimed (status `:in_progress`) since the caller
  inspected the goal is left untouched and surfaced in `:skipped`. A child that
  a concurrent claim has already moved *out* of Backlog/Ready is no longer a
  candidate at all, so it appears in neither list — it is simply not touched.
  Children in Doing, Review, or Done are never considered. Assignment history
  is recorded for the goal and each moved child.

  `new_assigned_to_id` must reference a user who is a member of the goal's
  board (or be `nil` to unassign); assigning work to an off-board or
  nonexistent user is rejected. The scoped user must pass `can_intervene?/2`.
  Returns:

    * `{:ok, %{moved: [tasks], skipped: [tasks]}}` — `moved` is the goal plus
      every reassigned child; `skipped` is the Backlog/Ready children that were
      already claimed.
    * `{:error, :unauthorized}` — the scope may not intervene on this goal.
    * `{:error, :assignee_not_on_board}` — the assignee is not a board member.
    * `{:error, changeset}` — a write failed; the whole transaction rolled back.
  """
  @spec reassign_goal_unstarted(Scope.t() | nil, Task.t(), integer() | nil) ::
          {:ok, %{moved: [Task.t()], skipped: [Task.t()]}}
          | {:error, :unauthorized | :assignee_not_on_board | Ecto.Changeset.t()}
  def reassign_goal_unstarted(scope, %Task{} = goal, new_assigned_to_id) do
    if can_intervene?(scope, goal) do
      run_reassign(goal, new_assigned_to_id)
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
  `reassign_goal_unstarted/3` (Backlog/Ready column, status `:open`, re-read
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
        run_reprioritize(goal, priority)
      end
    else
      {:error, :unauthorized}
    end
  end

  defp validate_priority(priority) when priority in @allowed_priorities, do: {:ok, priority}

  defp validate_priority(priority) when is_binary(priority) do
    case Enum.find(@allowed_priorities, fn allowed -> Atom.to_string(allowed) == priority end) do
      nil -> {:error, :invalid_priority}
      allowed -> {:ok, allowed}
    end
  end

  defp validate_priority(_priority), do: {:error, :invalid_priority}

  defp run_reassign(goal, new_assigned_to_id) do
    item_changeset = fn task -> assign_changeset(task, new_assigned_to_id) end
    history = fn task -> assignment_history(task.id, task.assigned_to_id, new_assigned_to_id) end

    Multi.new()
    |> Multi.run(:assignee, fn repo, _changes ->
      check_assignee_on_board(repo, goal, new_assigned_to_id)
    end)
    |> Multi.run(:candidates, fn repo, _changes -> {:ok, read_candidates(repo, goal)} end)
    |> Multi.merge(fn %{candidates: candidates} ->
      {eligible, _skipped} = partition_candidates(candidates)
      changes_multi(goal, eligible, item_changeset, history)
    end)
    |> Repo.transaction()
    |> finalize_intervention()
  end

  defp run_reprioritize(goal, new_priority) do
    item_changeset = fn task -> priority_changeset(task, new_priority) end
    history = fn task -> priority_history(task.id, task.priority, new_priority) end

    Multi.new()
    |> Multi.run(:candidates, fn repo, _changes -> {:ok, read_candidates(repo, goal)} end)
    |> Multi.merge(fn %{candidates: candidates} ->
      {eligible, _skipped} = partition_candidates(candidates)
      changes_multi(goal, eligible, item_changeset, history)
    end)
    |> Repo.transaction()
    |> finalize_intervention()
  end

  defp read_candidates(repo, goal) do
    goal.id
    |> not_started_children_query()
    |> repo.all()
  end

  # nil unassigns and needs no membership check. Otherwise the assignee must
  # belong to the goal's board — the FK guarantees the user exists, but the
  # write must also honor BoardScope so work is never assigned off-board. Run
  # inside the transaction (via the passed repo) so a step failure rolls the
  # whole operation back rather than leaving a partial reassignment.
  defp check_assignee_on_board(_repo, _goal, nil), do: {:ok, nil}

  defp check_assignee_on_board(repo, goal, new_assigned_to_id) do
    %{column: %{board_id: board_id}} = repo.preload(goal, :column)

    member? =
      from(bu in BoardUser,
        where: bu.board_id == ^board_id and bu.user_id == ^new_assigned_to_id
      )
      |> repo.exists?()

    if member?, do: {:ok, new_assigned_to_id}, else: {:error, :assignee_not_on_board}
  end

  # Re-read inside the transaction under FOR UPDATE so a concurrent claim that
  # flips a child to :in_progress either lands before this lock (child is seen
  # as claimed and skipped) or blocks behind it (child stays :open and is
  # reassigned) — never a lost update. The lock targets only task rows because
  # the column filter uses a subquery rather than a join.
  defp not_started_children_query(goal_id) do
    not_started_column_ids =
      from(c in Column, where: c.name in ^@not_started_columns, select: c.id)

    from(t in Task,
      where: t.parent_id == ^goal_id,
      where: t.column_id in subquery(not_started_column_ids),
      where: is_nil(t.archived_at),
      lock: "FOR UPDATE"
    )
  end

  defp partition_candidates(candidates) do
    Enum.split_with(candidates, fn %Task{status: status} -> status == :open end)
  end

  # Builds the goal + per-child update/history steps shared by both
  # interventions. `item_changeset` and `history` are closures that turn a task
  # into its Ecto changesets, so the same reduce serves reassignment (assigned_to
  # + assignment history) and reprioritization (priority + priority-change
  # history).
  defp changes_multi(goal, eligible, item_changeset, history) do
    multi =
      Multi.new()
      |> Multi.update(:goal, item_changeset.(goal))
      |> Multi.insert(:goal_history, history.(goal))

    Enum.reduce(eligible, multi, fn child, acc ->
      acc
      |> Multi.update({:child, child.id}, item_changeset.(child))
      |> Multi.insert({:child_history, child.id}, history.(child))
    end)
  end

  defp assign_changeset(%Task{} = task, new_assigned_to_id) do
    Task.changeset(task, %{assigned_to_id: new_assigned_to_id})
  end

  defp priority_changeset(%Task{} = task, new_priority) do
    Task.changeset(task, %{priority: new_priority})
  end

  defp assignment_history(task_id, from_user_id, to_user_id) do
    TaskHistory.changeset(%TaskHistory{}, %{
      task_id: task_id,
      type: :assignment,
      from_user_id: from_user_id,
      to_user_id: to_user_id
    })
  end

  defp priority_history(task_id, from_priority, to_priority) do
    TaskHistory.changeset(%TaskHistory{}, %{
      task_id: task_id,
      type: :priority_change,
      from_priority: Atom.to_string(from_priority),
      to_priority: Atom.to_string(to_priority)
    })
  end

  defp finalize_intervention({:ok, changes}) do
    {eligible, skipped} = partition_candidates(changes.candidates)

    moved_children = Enum.map(eligible, fn child -> Map.fetch!(changes, {:child, child.id}) end)
    moved = [changes.goal | moved_children]

    Enum.each(moved, &Broadcaster.broadcast_task_change(&1, :task_updated))

    {:ok, %{moved: moved, skipped: skipped}}
  end

  # A failed Multi step yields `{:error, step, failed_value, changes}`. The
  # membership step fails with the atom `:assignee_not_on_board`; an update or
  # insert step fails with an `%Ecto.Changeset{}` — pass whichever through, the
  # transaction has already rolled back either way.
  defp finalize_intervention({:error, _step, failed_value, _changes}) do
    {:error, failed_value}
  end
end
