defmodule Kanban.Tasks.Lifecycle do
  @moduledoc """
  Task lifecycle operations: update, delete, archive, and unarchive.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Dependencies
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

  # Existing single-task update path. Preserves the original side-effect
  # ordering (priority/assignment/dependencies/status histories, then broadcast).
  defp update_without_cascade(task, changeset) do
    case Repo.update(changeset) do
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
  PubSub `:task_updated` event is broadcast so open ArchiveLive /
  BoardLive sessions refresh.
  """
  def archive_task(%Task{} = task, attrs \\ %{}) do
    archive_attrs =
      attrs
      |> Map.new()
      |> Map.put(:archived_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case task |> Task.archive_changeset(archive_attrs) |> Repo.update() do
      {:ok, updated_task} ->
        :telemetry.execute(
          [:kanban, :task, :archived],
          %{task_id: updated_task.id},
          %{identifier: updated_task.identifier}
        )

        Broadcaster.broadcast_task_change(updated_task, :task_updated)

        {:ok, updated_task}

      error ->
        error
    end
  end

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

    case task |> Task.archive_changeset(clear_attrs) |> Repo.update() do
      {:ok, updated_task} ->
        :telemetry.execute(
          [:kanban, :task, :unarchived],
          %{task_id: updated_task.id},
          %{identifier: updated_task.identifier}
        )

        Broadcaster.broadcast_task_change(updated_task, :task_updated)

        {:ok, updated_task}

      error ->
        error
    end
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
