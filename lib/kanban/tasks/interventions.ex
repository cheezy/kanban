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

  defp run_reassign(goal, new_assigned_to_id) do
    Multi.new()
    |> Multi.run(:assignee, fn repo, _changes ->
      check_assignee_on_board(repo, goal, new_assigned_to_id)
    end)
    |> Multi.run(:candidates, fn repo, _changes ->
      candidates =
        goal.id
        |> not_started_children_query()
        |> repo.all()

      {:ok, candidates}
    end)
    |> Multi.merge(fn %{candidates: candidates} ->
      {eligible, _skipped} = partition_candidates(candidates)
      reassign_multi(goal, eligible, new_assigned_to_id)
    end)
    |> Repo.transaction()
    |> handle_reassign_result()
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

  defp reassign_multi(goal, eligible, new_assigned_to_id) do
    multi =
      Multi.new()
      |> Multi.update(:goal, assign_changeset(goal, new_assigned_to_id))
      |> Multi.insert(
        :goal_history,
        assignment_history(goal.id, goal.assigned_to_id, new_assigned_to_id)
      )

    Enum.reduce(eligible, multi, fn child, acc ->
      acc
      |> Multi.update({:child, child.id}, assign_changeset(child, new_assigned_to_id))
      |> Multi.insert(
        {:child_history, child.id},
        assignment_history(child.id, child.assigned_to_id, new_assigned_to_id)
      )
    end)
  end

  defp assign_changeset(%Task{} = task, new_assigned_to_id) do
    Task.changeset(task, %{assigned_to_id: new_assigned_to_id})
  end

  defp assignment_history(task_id, from_user_id, to_user_id) do
    TaskHistory.changeset(%TaskHistory{}, %{
      task_id: task_id,
      type: :assignment,
      from_user_id: from_user_id,
      to_user_id: to_user_id
    })
  end

  defp handle_reassign_result({:ok, changes}) do
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
  defp handle_reassign_result({:error, _step, failed_value, _changes}) do
    {:error, failed_value}
  end
end
