defmodule Kanban.Tasks.InterventionTransactions do
  @moduledoc """
  The transactions behind the in-page goal interventions in
  `Kanban.Tasks.Interventions`: reassigning or reprioritizing a goal and its
  not-started, unclaimed children, undoing either, and the read that lists the
  children a preview would move.

  **This module performs no authorization.** Call it only behind
  `Kanban.Tasks.Interventions.can_intervene?/2`. It is internal to
  `Kanban.Tasks`: the `Kanban.Tasks` facade does not delegate to it, and
  `KanbanWeb` must never call it directly. The `task_assigned` notification and
  the `Kanban.Tasks.GoalTelemetry` events stay in `Kanban.Tasks.Interventions`
  and fire after the transaction commits.

  Every write re-reads its candidate children inside the transaction under a
  `FOR UPDATE` row lock, so a concurrent agent claim either lands first (the
  child is seen as claimed and returned in `:skipped`) or waits behind the lock
  (the child stays `:open` and is moved) — never a lost update. Which columns
  count as not started is decided per board by `Kanban.Columns.Stage`.
  `preview_children/1` takes no lock. Each write returns
  `{:ok, %{moved: [goal | children], skipped: claimed}}` with the goal always
  first, and broadcasts `:task_updated` for every moved task once the
  transaction returns. A failed step rolls everything back and returns
  `{:error, value}`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Columns.Stage
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @typep result :: {:ok, %{moved: [Task.t()], skipped: [Task.t()]}}

  @doc """
  Reassigns `goal` and its not-started, unclaimed children to
  `new_assigned_to_id` in one transaction, recording assignment history for each
  moved task.

  A non-`nil` assignee must be a member of the goal's board; the check runs
  inside the transaction, so an off-board assignee returns
  `{:error, :assignee_not_on_board}` and nothing changes. `nil` unassigns and
  skips the check. A failed write returns `{:error, changeset}`.
  """
  @spec reassign(Task.t(), integer() | nil) ::
          result() | {:error, :assignee_not_on_board | Ecto.Changeset.t()}
  def reassign(goal, new_assigned_to_id) do
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

  @doc """
  Sets `goal` and its not-started, unclaimed children to `new_priority` in one
  transaction, recording priority-change history for each moved task.

  `new_priority` must already be a validated priority atom —
  `Kanban.Tasks.Interventions` validates it first. A failed write returns
  `{:error, changeset}`.
  """
  @spec reprioritize(Task.t(), atom()) :: result() | {:error, Ecto.Changeset.t()}
  def reprioritize(%Task{} = goal, new_priority) do
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

  @doc """
  The undo write. Restores `goal` and exactly `child_ids` to their prior
  `field` value (`:assigned_to_id` or `:priority`), each to **its own** value
  from `priors` (task id => prior value), so a task that never moved is never
  touched.

  `priors` must carry an entry for the goal and for every id in `child_ids`.
  Only `child_ids` are read — never the goal's broader current not-started set —
  under the same `FOR UPDATE` re-read, partition, changeset + history reduce and
  finalize as the forward writes. The goal is always restored; a listed child
  claimed since falls into `:skipped`, and one moved out of a not-started column
  is left out. There is no assignee board-membership check: the prior value is a
  known-good historical state being reverted to, not a fresh off-board
  assignment. History is recorded for each restored task.
  """
  @spec undo(Task.t(), [integer()], :assigned_to_id | :priority, %{
          optional(integer()) => integer() | atom() | nil
        }) :: result() | {:error, Ecto.Changeset.t()}
  def undo(%Task{} = goal, child_ids, field, priors) do
    {item_changeset, history} = undo_changeset_and_history(field, priors)

    Multi.new()
    |> Multi.run(:candidates, fn repo, _changes ->
      {:ok, read_moved_children(repo, goal, child_ids)}
    end)
    |> Multi.merge(fn %{candidates: candidates} ->
      {eligible, _skipped} = partition_candidates(candidates)
      changes_multi(goal, eligible, item_changeset, history)
    end)
    |> Repo.transaction()
    |> finalize_intervention()
  end

  @doc """
  Returns the children a reassign or reprioritize would move right now: on a
  not-started column, not archived, with status `:open` (claimed children are
  left out, as the write would skip them).

  Takes no row lock, so the result is a best-effort snapshot; the write re-reads
  under `FOR UPDATE` at confirm time.
  """
  @spec preview_children(Task.t()) :: [Task.t()]
  def preview_children(%Task{} = goal) do
    {eligible, _claimed} =
      goal
      |> not_started_children_query(lock: false)
      |> Repo.all()
      |> partition_candidates()

    eligible
  end

  defp read_candidates(repo, goal) do
    goal
    |> not_started_children_query()
    |> repo.all()
  end

  defp undo_changeset_and_history(:assigned_to_id, priors) do
    changeset = fn task -> assign_changeset(task, Map.fetch!(priors, task.id)) end

    history = fn task ->
      assignment_history(task.id, task.assigned_to_id, Map.fetch!(priors, task.id))
    end

    {changeset, history}
  end

  defp undo_changeset_and_history(:priority, priors) do
    changeset = fn task -> priority_changeset(task, Map.fetch!(priors, task.id)) end

    history = fn task ->
      priority_history(task.id, task.priority, Map.fetch!(priors, task.id))
    end

    {changeset, history}
  end

  defp read_moved_children(repo, goal, child_ids) do
    goal
    |> not_started_children_query()
    |> where([t], t.id in ^child_ids)
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
  # the column filter is a list of ids rather than a join. The write path locks
  # (default); the read-only preview passes `lock: false`. Which columns count
  # as not started is decided per board by Kanban.Columns.Stage.
  defp not_started_children_query(%Task{} = goal, opts \\ []) do
    not_started_column_ids = goal |> board_id() |> Stage.not_started_column_ids()

    query =
      from(t in Task,
        where: t.parent_id == ^goal.id,
        where: t.column_id in ^not_started_column_ids,
        where: is_nil(t.archived_at)
      )

    if Keyword.get(opts, :lock, true) do
      from(t in query, lock: "FOR UPDATE")
    else
      query
    end
  end

  defp board_id(%Task{column_id: column_id}) do
    from(c in Column, where: c.id == ^column_id, select: c.board_id)
    |> Repo.one!()
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
