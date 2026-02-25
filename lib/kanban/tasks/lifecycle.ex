defmodule Kanban.Tasks.Lifecycle do
  @moduledoc """
  Task lifecycle operations: update, delete, archive, and unarchive.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task

  @doc """
  Updates a task.
  """
  def update_task(%Task{} = task, attrs) do
    changeset = Task.changeset(task, attrs)
    changeset = Dependencies.validate_circular_dependencies(changeset)
    priority_changed? = Map.has_key?(changeset.changes, :priority)
    assignment_changed? = Map.has_key?(changeset.changes, :assigned_to_id)
    dependencies_changed? = Map.has_key?(changeset.changes, :dependencies)
    status_changed? = Map.has_key?(changeset.changes, :status)

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        if priority_changed? do
          History.create_priority_change_history(
            task.priority,
            updated_task.priority,
            updated_task.id
          )
        end

        if assignment_changed? do
          History.create_assignment_history(
            task.assigned_to_id,
            updated_task.assigned_to_id,
            updated_task.id
          )
        end

        if dependencies_changed? do
          Dependencies.update_task_blocking_status(updated_task)
        end

        if status_changed? && updated_task.status == :completed do
          updated_task = Repo.preload(updated_task, :column)

          Dependencies.unblock_dependent_tasks(
            updated_task.identifier,
            updated_task.column.board_id
          )
        end

        Broadcaster.broadcast_task_update(updated_task, changeset)

        {:ok, updated_task}

      error ->
        error
    end
  end

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
  Archives a task by setting archived_at to the current timestamp.
  """
  def archive_task(%Task{} = task) do
    changeset =
      Ecto.Changeset.change(task, archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        :telemetry.execute(
          [:kanban, :task, :archived],
          %{task_id: updated_task.id},
          %{identifier: updated_task.identifier}
        )

        {:ok, updated_task}

      error ->
        error
    end
  end

  @doc """
  Unarchives a task by setting archived_at to nil.
  """
  def unarchive_task(%Task{} = task) do
    changeset = Ecto.Changeset.change(task, archived_at: nil)

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        :telemetry.execute(
          [:kanban, :task, :unarchived],
          %{task_id: updated_task.id},
          %{identifier: updated_task.identifier}
        )

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
