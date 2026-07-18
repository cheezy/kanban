defmodule Kanban.Tasks.Lifecycle do
  @moduledoc """
  Task lifecycle operations: update, delete, archive, and unarchive.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.DbErrors
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @doc """
  Updates a task.

  When the task is a goal AND the changeset includes `:assigned_to_id`, this
  function ALSO cascades the new assignment to every non-completed child task
  whose `assigned_to_id` differs from the new value. The cascade is atomic:
  goal update, child updates, and assignment_history rows all commit together
  in a single transaction. If any step fails, none persist.
  """
  def update_task(%Task{} = task, attrs) do
    changeset = Task.changeset(task, attrs)
    changeset = Dependencies.validate_circular_dependencies(changeset)
    assignment_changed? = Map.has_key?(changeset.changes, :assigned_to_id)

    if assignment_changed? and task.type == :goal do
      update_goal_with_cascade(task, changeset)
    else
      update_without_cascade(task, changeset)
    end
  end

  @doc """
  API-safe update path for PATCH /api/tasks/:id.

  Uses `Task.api_update_changeset/2` which enforces a strict allow-list,
  blocking mass-assignment of workflow/audit fields (status, assigned_to_id,
  claimed_at, completed_*, reviewed_*, identifier, parent_id, time_spent_minutes,
  archived_at, …). Workflow endpoints (claim/complete/mark_reviewed) set those
  fields via their own internal paths that bypass this changeset.

  The cascade branch from `update_task/2` is unreachable here because
  `:assigned_to_id` is not in the allow-list — API callers cannot trigger a
  goal-to-children assignment cascade.
  """
  def api_update_task(%Task{} = task, attrs) do
    changeset = Task.api_update_changeset(task, attrs)
    changeset = Dependencies.validate_circular_dependencies(changeset)
    update_without_cascade(task, changeset)
  end

  @doc """
  Persists the per-file diff snapshot on a task without firing any side
  effects (no PubSub broadcast, no history rows, no preload chain). Used by
  `PUT /api/tasks/:id/changed_files`, where the agent uploads a diff
  snapshot independently of the completion request.

  Callers must pre-validate the list with
  `Kanban.Tasks.CompletionValidation.validate_changed_files/1`. Accepts a
  list only; `[]` is a legitimate explicit-clear value. `nil` is rejected
  at the function-clause level to prevent silent NULL writes.
  """
  @spec update_changed_files(Task.t(), list()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_changed_files(%Task{} = task, changed_files)
      when is_list(changed_files) do
    task
    |> Ecto.Changeset.change(changed_files: changed_files)
    |> Repo.update()
  end

  # Existing single-task update path. Preserves the original side-effect
  # ordering (priority/assignment/dependencies/status histories, then broadcast).
  defp update_without_cascade(task, changeset) do
    # Wrap only the DB write: a 22001 on a bounded column without a per-field
    # validator becomes {:error, value_too_long_changeset} (a clean 422) rather
    # than a raised Postgrex.Error / HTTP 500. The success-path side effects run
    # outside the rescue so a history/broadcast error is never mis-attributed.
    case DbErrors.translate_value_too_long(fn -> Repo.update(changeset) end, &{:error, &1}) do
      {:ok, updated_task} ->
        updated_task = fire_update_side_effects(task, updated_task, changeset)
        Broadcaster.broadcast_task_update(updated_task, changeset)

        {:ok, updated_task}

      error ->
        error
    end
  end

  defp fire_update_side_effects(task, updated_task, changeset) do
    if Map.has_key?(changeset.changes, :priority) do
      History.create_priority_change_history(
        task.priority,
        updated_task.priority,
        updated_task.id
      )
    end

    if Map.has_key?(changeset.changes, :assigned_to_id) do
      History.create_assignment_history(
        task.assigned_to_id,
        updated_task.assigned_to_id,
        updated_task.id
      )
    end

    if Map.has_key?(changeset.changes, :dependencies) do
      Dependencies.update_task_blocking_status(updated_task)
    end

    if Map.has_key?(changeset.changes, :parent_id) do
      recalculate_moved_task_parent_goals(task, updated_task)
    end

    if Map.has_key?(changeset.changes, :status) && updated_task.status == :completed do
      updated_task = Repo.preload(updated_task, :column)

      Dependencies.unblock_dependent_tasks(
        updated_task.identifier,
        updated_task.column.board_id
      )

      updated_task
    else
      updated_task
    end
  end

  # Recalculates the affected parent goals' column positions after a task's
  # `:parent_id` changes via the edit form (added to a goal, removed from a
  # goal, or moved between goals). Mirrors the D166 create-path recalc in
  # creation.ex so a Done goal that gains a non-Done child is pulled back onto
  # the board, and the goal a task left is advanced.
  #
  # Reuses `Goals.update_parent_goal_position/3` — the same entry point used by
  # creation.ex, positioning.ex, and agent_workflow.ex — so no positioning
  # logic is duplicated. That function no-ops safely for tasks whose parent is
  # nil or not a goal (via `get_parent_goal/1`), so no parent_id guard is
  # needed here. Its 2nd/3rd column args are unused by the recalc; the task's
  # own column is passed for self-documentation.
  #
  # `updated_task` carries the NEW parent_id; `task` is the pre-update struct,
  # so its parent_id is still the OLD value — recalculating both covers moves
  # between goals and removals.
  defp recalculate_moved_task_parent_goals(task, updated_task) do
    Goals.update_parent_goal_position(
      updated_task,
      updated_task.column_id,
      updated_task.column_id
    )

    Goals.update_parent_goal_position(task, task.column_id, task.column_id)

    :ok
  end

  # Atomic goal-with-cascade update path. Runs:
  #   1. Update the goal (Multi.update :goal)
  #   2. Insert the goal's own assignment_history row
  #   3. For each eligible child (non-completed, assigned_to_id != new):
  #        - Multi.update {:child, child.id} with the new assigned_to_id
  #        - Multi.insert {:child_history, child.id} for the child's history row
  # If any step fails, the whole transaction rolls back and the function
  # returns {:error, changeset}. After commit, the function broadcasts
  # task_update events for the goal AND each cascaded child.
  defp update_goal_with_cascade(goal, changeset) do
    new_assigned_to_id = Ecto.Changeset.get_change(changeset, :assigned_to_id)
    children = fetch_eligible_children(goal.id, new_assigned_to_id)
    multi = build_cascade_multi(goal, changeset, new_assigned_to_id, children)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        updated_goal = Map.fetch!(changes, :goal)
        fire_concurrent_goal_side_effects(goal, updated_goal, changeset)

        Broadcaster.broadcast_task_update(updated_goal, changeset)

        Enum.each(children, fn child ->
          updated_child = Map.fetch!(changes, {:child, child.id})
          Broadcaster.broadcast_task_change(updated_child, :task_updated)
        end)

        {:ok, updated_goal}

      {:error, _step, failed_changeset, _changes_so_far} ->
        {:error, failed_changeset}
    end
  end

  defp build_cascade_multi(goal, changeset, new_assigned_to_id, children) do
    multi =
      Multi.new()
      |> Multi.update(:goal, changeset)
      |> Multi.insert(
        :goal_history,
        build_assignment_history(goal.id, goal.assigned_to_id, new_assigned_to_id)
      )

    Enum.reduce(children, multi, fn child, acc ->
      acc
      |> Multi.update(
        {:child, child.id},
        Task.changeset(child, %{assigned_to_id: new_assigned_to_id})
      )
      |> Multi.insert(
        {:child_history, child.id},
        build_assignment_history(child.id, child.assigned_to_id, new_assigned_to_id)
      )
    end)
  end

  # Side effects for fields that may change in the same save as the assignment.
  # The goal's own assignment_history is already inserted by the Multi (as
  # :goal_history), so it is intentionally excluded here.
  defp fire_concurrent_goal_side_effects(goal, updated_goal, changeset) do
    if Map.has_key?(changeset.changes, :priority) do
      History.create_priority_change_history(
        goal.priority,
        updated_goal.priority,
        updated_goal.id
      )
    end

    if Map.has_key?(changeset.changes, :dependencies) do
      Dependencies.update_task_blocking_status(updated_goal)
    end

    if Map.has_key?(changeset.changes, :status) and updated_goal.status == :completed do
      preloaded = Repo.preload(updated_goal, :column)
      Dependencies.unblock_dependent_tasks(preloaded.identifier, preloaded.column.board_id)
    end
  end

  defp build_assignment_history(task_id, from_user_id, to_user_id) do
    TaskHistory.changeset(%TaskHistory{}, %{
      task_id: task_id,
      type: :assignment,
      from_user_id: from_user_id,
      to_user_id: to_user_id
    })
  end

  defp fetch_eligible_children(goal_id, new_assigned_to_id) do
    eligible_children_query(goal_id, new_assigned_to_id) |> Repo.all()
  end

  # Eligible children for the cascade: non-completed children of the goal
  # whose current assigned_to_id is not already equal to the new value.
  # Two clauses because the SQL predicate differs depending on whether the new
  # assignment is nil (unassign cascade) or a concrete user id.
  defp eligible_children_query(goal_id, nil) do
    from(t in Task,
      where: t.parent_id == ^goal_id,
      where: t.status != :completed,
      where: not is_nil(t.assigned_to_id)
    )
  end

  defp eligible_children_query(goal_id, new_assigned_to_id) do
    from(t in Task,
      where: t.parent_id == ^goal_id,
      where: t.status != :completed,
      where: t.assigned_to_id != ^new_assigned_to_id or is_nil(t.assigned_to_id)
    )
  end

  @doc """
  Returns the number of children that would be re-assigned if a cascade ran
  right now — non-completed children of `goal` whose `assigned_to_id` differs
  from `new_assigned_to_id`.

  Returns 0 when `goal.type` is not `:goal`. Used by UI components that need
  to surface a "N child tasks were also updated" affordance after the cascade.
  """
  def count_cascade_affected_children(%Task{type: :goal, id: id}, new_assigned_to_id) do
    eligible_children_query(id, new_assigned_to_id) |> Repo.aggregate(:count)
  end

  def count_cascade_affected_children(_task, _new_assigned_to_id), do: 0

  @doc """
  Deletes a task and reorders the remaining tasks.

  Returns {:error, :has_dependents} if other tasks depend on this task.
  """
  def delete_task(%Task{} = task) do
    dependent_tasks = Dependencies.get_dependent_tasks(task)

    if dependent_tasks != [] do
      {:error, :has_dependents}
    else
      parent_id = task.parent_id
      result = Repo.delete(task)

      case result do
        {:ok, deleted_task} ->
          Positioning.reorder_after_deletion(deleted_task)
          Broadcaster.broadcast_task_change(deleted_task, :task_deleted)

          if parent_id do
            delete_goal_if_no_children(parent_id)
          end

          {:ok, deleted_task}

        error ->
          error
      end
    end
  end

  @doc """
  Archives a task by stamping `archived_at` and persisting optional
  archive metadata.

  When the task is a `:goal`, its non-archived child tasks are
  cascade-archived in the same transaction so the Archive view never
  shows orphaned children of an archived parent. Child attrs are
  derived from the parent's attrs:

    * `archive_reason`: inherits the parent's reason when it is
      `:completed | :wontdo | :deferred | :cancelled`; defaults to
      `:completed` when the parent has no reason or was archived as a
      `:duplicate` (children are not duplicates of whatever the parent
      was a duplicate of).
    * `archive_note`: inherits the parent's note only when the reason
      is one that requires it (`:wontdo | :deferred | :cancelled`).
    * `archived_by_id`: inherits the parent's value.
    * `duplicate_of_id`: never inherited.
    * `archived_at`: same timestamp as the parent's archive (so the
      batch groups cleanly in the Archive view).

  ## Attrs

  When `attrs` is empty (the default), only `archived_at` is set — the
  task looks identical to the legacy archive flow. Callers that want to
  surface a reason on the Archive view pass any subset of:

    * `:archive_reason` — one of `:completed`, `:duplicate`, `:wontdo`,
      `:deferred`, `:cancelled`
    * `:archive_note` — required when `:archive_reason` is `:wontdo`,
      `:deferred`, or `:cancelled`
    * `:duplicate_of_id` — required when `:archive_reason` is `:duplicate`,
      forbidden otherwise
    * `:archived_by_id` — FK to the user performing the archive

  All validation runs through `Task.changeset/2`, so the conditional
  required-field rules introduced in W570 are enforced here. The
  PubSub `:task_updated` event is broadcast for the parent and for each
  cascade-archived child so open ArchiveLive / BoardLive sessions
  refresh.
  """
  def archive_task(%Task{} = task, attrs \\ %{}) do
    attrs_map = Map.new(attrs)
    archived_at = DateTime.utc_now() |> DateTime.truncate(:second)
    archive_attrs = Map.put(attrs_map, :archived_at, archived_at)

    Multi.new()
    |> Multi.update(:goal, Task.archive_changeset(task, archive_attrs))
    |> Multi.run(:children, fn repo, %{goal: archived_goal} ->
      cascade_archive_children(repo, archived_goal, attrs_map, archived_at)
    end)
    |> Repo.transaction()
    |> handle_archive_result()
  end

  defp handle_archive_result({:ok, %{goal: updated_task, children: children}}) do
    emit_archive_telemetry(updated_task)
    Broadcaster.broadcast_task_change(updated_task, :task_updated)

    Enum.each(children, fn child ->
      emit_cascade_telemetry(child, updated_task.id)
      Broadcaster.broadcast_task_change(child, :task_updated)
    end)

    {:ok, updated_task}
  end

  defp handle_archive_result({:error, _step, changeset, _changes}), do: {:error, changeset}

  defp emit_archive_telemetry(task) do
    :telemetry.execute(
      [:kanban, :task, :archived],
      %{task_id: task.id},
      %{identifier: task.identifier}
    )
  end

  defp emit_cascade_telemetry(child, goal_id) do
    :telemetry.execute(
      [:kanban, :task, :archived],
      %{task_id: child.id},
      %{identifier: child.identifier, via: :goal_cascade, goal_id: goal_id}
    )
  end

  defp cascade_archive_children(_repo, %Task{type: type}, _parent_attrs, _archived_at)
       when type != :goal do
    {:ok, []}
  end

  defp cascade_archive_children(repo, %Task{id: goal_id}, parent_attrs, archived_at) do
    child_attrs = build_child_archive_attrs(parent_attrs, archived_at)

    children =
      from(t in Task,
        where: t.parent_id == ^goal_id and is_nil(t.archived_at)
      )
      |> repo.all()

    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      child
      |> Task.archive_changeset(child_attrs)
      |> repo.update()
      |> case do
        {:ok, archived} -> {:cont, {:ok, [archived | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @parent_reasons_that_inherit_to_children [:completed, :wontdo, :deferred, :cancelled]
  @parent_reasons_that_require_note [:wontdo, :deferred, :cancelled]

  defp build_child_archive_attrs(parent_attrs, archived_at) do
    parent_reason = Map.get(parent_attrs, :archive_reason)
    {child_reason, include_note?} = child_reason_for(parent_reason)

    %{archived_at: archived_at, archive_reason: child_reason}
    |> maybe_put(:archived_by_id, Map.get(parent_attrs, :archived_by_id))
    |> maybe_put_note(include_note?, Map.get(parent_attrs, :archive_note))
  end

  defp child_reason_for(reason) when reason in @parent_reasons_that_inherit_to_children do
    {reason, reason in @parent_reasons_that_require_note}
  end

  # nil, :duplicate, or any unexpected value → children are :completed,
  # not duplicates of whatever the parent was a duplicate of.
  defp child_reason_for(_), do: {:completed, false}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_note(map, false, _note), do: map
  defp maybe_put_note(map, true, nil), do: map
  defp maybe_put_note(map, true, note), do: Map.put(map, :archive_note, note)

  @doc """
  Unarchives a task by clearing `archived_at` and every archive-metadata
  field so the restored task looks fully alive again.

  Per W572 pitfall #3, leaving `archive_reason` set on a restored task
  would surface it on the Archive view's per-reason filter — not what
  the user expects after pressing "Restore".

  Broadcasts the PubSub `:task_updated` event so open archive pages
  drop the row from their list.
  """
  def unarchive_task(%Task{} = task) do
    clear_attrs = %{
      archived_at: nil,
      archive_reason: nil,
      archive_note: nil,
      archived_by_id: nil,
      duplicate_of_id: nil
    }

    case clear_archive_with_fresh_position(task, clear_attrs) do
      {:ok, updated_task} ->
        :telemetry.execute(
          [:kanban, :task, :unarchived],
          %{task_id: updated_task.id},
          %{identifier: updated_task.identifier}
        )

        Broadcaster.broadcast_task_change(updated_task, :task_updated)

        {:ok, updated_task}

      {:error, _} = error ->
        error
    end
  end

  # Clears the archive fields AND assigns a fresh live position in one
  # transaction. The (column_id, position) unique index is partial on
  # archived_at, so an archived task can share a position value with a live
  # one; clearing archived_at without re-positioning would violate the live
  # constraint. get_next_position_locked takes a transactional advisory lock,
  # hence the surrounding Repo.transaction.
  defp clear_archive_with_fresh_position(task, clear_attrs) do
    Repo.transaction(fn ->
      column = Kanban.Columns.get_column!(task.column_id)
      next_position = Positioning.get_next_position_locked(column)

      changeset =
        task
        |> Task.archive_changeset(clear_attrs)
        |> Ecto.Changeset.put_change(:position, next_position)

      case Repo.update(changeset) do
        {:ok, updated_task} -> updated_task
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Archives every completed, non-archived task on the given board whose
  `completed_at` is strictly older than the cutoff (default 30 days).

  Uses a single `Repo.update_all` to avoid N+1 writes when the Done
  column contains many tasks. Returns `{:ok, count}` where `count` is
  the number of tasks archived.

  Emits a `[:kanban, :task, :bulk_archived]` telemetry event with
  `%{count: count}` measurements and `%{board_id: board_id}` metadata.

  Scoped strictly to the supplied board — completed tasks on other
  boards are never touched. Tasks whose `completed_at` is `nil` are
  also skipped (their age is unknown), as are tasks already archived
  or whose `status` is not `:completed`.
  """
  def bulk_archive_completed_tasks_older_than(board_id, cutoff_days \\ 30)
      when is_integer(cutoff_days) and cutoff_days >= 0 do
    archived_at = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(archived_at, -cutoff_days * 86_400, :second)

    {count, _} =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.status == :completed,
        where: not is_nil(t.completed_at),
        where: t.completed_at < ^cutoff,
        where: is_nil(t.archived_at)
      )
      |> Repo.update_all(
        set: [
          archived_at: archived_at,
          archive_reason: :completed,
          updated_at: archived_at
        ]
      )

    emit_bulk_archive_telemetry(count, board_id)

    {:ok, count}
  end

  defp emit_bulk_archive_telemetry(count, board_id) do
    :telemetry.execute(
      [:kanban, :task, :bulk_archived],
      %{count: count},
      %{board_id: board_id}
    )
  end

  defp delete_goal_if_no_children(goal_id) do
    remaining_children_count =
      Task
      |> where([t], t.parent_id == ^goal_id)
      |> Repo.aggregate(:count)

    if remaining_children_count == 0 do
      goal = Repo.get(Task, goal_id)

      if goal do
        Repo.delete(goal)
        Positioning.reorder_after_deletion(goal)
        Broadcaster.broadcast_task_change(goal, :task_deleted)
      end
    end
  end
end
