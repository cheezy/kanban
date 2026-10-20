defmodule Kanban.Tasks.Lifecycle do
  @moduledoc """
  Task lifecycle operations: update and delete, including the goal-to-children
  assignment cascade. Archiving lives in `Kanban.Tasks.Archiving`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.ChangesetText
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.Assignees
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.DbErrors
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Tasks.TaskTelemetry

  @doc """
  Updates a task.

  When the task is a goal AND the changeset includes `:assigned_to_id`, this
  function ALSO cascades the new assignment to every non-completed child task
  whose `assigned_to_id` differs from the new value. The cascade is atomic:
  goal update, child updates, and assignment_history rows all commit together
  in a single transaction. If any step fails, none persist.

  When the assignee changes, the new assignee is notified once after the
  write commits (`Kanban.Notifications.Events.task_assigned/2`) — once for a
  goal, never per cascaded child. `opts`:

    * `:actor` — the user making the change; assigning a task to yourself
      notifies nobody. Omitted, the change is treated as a system change and
      the assignee is notified.
    * `:telemetry` — `false` skips the `[:kanban, :task, :updated]` event.
      Only for internal bookkeeping writes that are not an edit, such as the
      position shifts after a delete. Defaults to `true`.
    * `:webhook` — `false` skips the task's webhook event (the board
      broadcast still happens). Same use as `:telemetry`. Defaults to `true`.
      A save that changed nothing never emits one.

  A saved change emits `[:kanban, :task, :updated]` with `source: :ui` once
  the write has committed (once for a goal, never per cascaded child).

  Changing the assignee to a disabled account returns an error changeset on
  `:assigned_to_id` and writes nothing (`Kanban.Tasks.Assignees`). Keeping an
  assignee who was disabled later, or clearing the assignee, still saves.
  """
  def update_task(%Task{} = task, attrs, opts \\ []) do
    changeset = task |> Task.changeset(attrs) |> Assignees.validate_enabled_assignee()
    changeset = Dependencies.validate_circular_dependencies(changeset)
    assignment_changed? = Map.has_key?(changeset.changes, :assigned_to_id)

    result =
      if assignment_changed? and task.type == :goal do
        update_goal_with_cascade(task, changeset)
      else
        update_without_cascade(task, changeset, Keyword.take(opts, [:webhook]))
      end

    result
    |> notify_assignment(assignment_changed?, opts)
    |> emit_updated(changeset, opts)
  end

  defp emit_updated(result, changeset, opts) do
    if Keyword.get(opts, :telemetry, true),
      do: TaskTelemetry.updated(result, changeset, :ui, Keyword.get(opts, :actor)),
      else: result
  end

  defp notify_assignment({:ok, updated} = result, true, opts) do
    Events.task_assigned(updated, Keyword.get(opts, :actor))
    result
  end

  defp notify_assignment(result, _assignment_changed?, _opts), do: result

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

    task
    |> update_without_cascade(changeset)
    |> TaskTelemetry.updated(changeset, :api, nil)
  end

  @doc """
  Persists the per-file diff snapshot on a task without firing any side
  effects (no PubSub broadcast, no history rows, no preload chain). Used by
  `PUT /api/tasks/:id/changed_files`, where the agent uploads a diff
  snapshot independently of the completion request.

  Callers must pre-validate the list with
  `Kanban.Tasks.CompletionValidation.validate_changed_files/1`. Accepts a
  list only; `[]` is a legitimate explicit-clear value. `nil` is rejected
  at the function-clause level to prevent silent NULL writes. A NUL byte or
  invalid UTF-8 anywhere in an entry, which the `jsonb` column cannot hold, is
  refused as a changeset error on `:changed_files` (D383).
  """
  @spec update_changed_files(Task.t(), list()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_changed_files(%Task{} = task, changed_files)
      when is_list(changed_files) do
    task
    |> Ecto.Changeset.change(changed_files: changed_files)
    |> ChangesetText.validate_storable([:changed_files])
    |> Repo.update()
  end

  # Existing single-task update path. Preserves the original side-effect
  # ordering (priority/assignment/dependencies/status histories, then broadcast).
  defp update_without_cascade(task, changeset, broadcast_opts \\ []) do
    # Wrap only the DB write: a 22001 on a bounded column without a per-field
    # validator becomes {:error, value_too_long_changeset} (a clean 422) rather
    # than a raised Postgrex.Error / HTTP 500. The success-path side effects run
    # outside the rescue so a history/broadcast error is never mis-attributed.
    case DbErrors.translate_value_too_long(fn -> Repo.update(changeset) end, &{:error, &1}) do
      {:ok, updated_task} ->
        updated_task = fire_update_side_effects(task, updated_task, changeset)
        Broadcaster.broadcast_task_update(updated_task, changeset, broadcast_opts)

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
  # Goes through `Goals.update_parent_goal_position_locked/2`, the locked entry
  # point creation.ex and agent_workflow.ex use too, so each goal is re-placed
  # while holding the locks of every column it writes to (D373). It no-ops for
  # a task whose parent is nil or not a goal, so no parent_id guard is needed.
  #
  # `updated_task` carries the NEW parent_id; `task` is the pre-update struct,
  # so its parent_id is still the OLD value — recalculating both covers moves
  # between goals and removals. Each goal takes its own locked pass.
  defp recalculate_moved_task_parent_goals(task, updated_task) do
    Goals.update_parent_goal_position_locked(updated_task)
    Goals.update_parent_goal_position_locked(task)
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
          TaskTelemetry.deleted(deleted_task)

          if parent_id do
            delete_goal_if_no_children(parent_id)
          end

          {:ok, deleted_task}

        error ->
          error
      end
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
