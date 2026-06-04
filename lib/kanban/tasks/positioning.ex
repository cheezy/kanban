defmodule Kanban.Tasks.Positioning do
  @moduledoc """
  Task positioning and movement within and between columns.

  Handles moving tasks, reordering, WIP limit checks, and position-related
  helpers used by other submodules.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task

  require Logger

  @doc """
  Moves a task to a different column at a specific position.
  Respects WIP limit of target column.
  """
  def move_task(%Task{} = task, %Column{} = new_column, new_position) do
    old_column_id = task.column_id
    result = check_wip_and_perform_move(task, new_column, new_position, old_column_id)

    case result do
      {:ok, updated_task} ->
        Broadcaster.broadcast_task_change(updated_task, :task_moved)
        {:ok, updated_task}

      error ->
        error
    end
  end

  defp check_wip_and_perform_move(task, new_column, new_position, old_column_id) do
    cross_column? = new_column.id != old_column_id
    should_check_wip = cross_column? and task.type in [:work, :defect]

    if should_check_wip and wip_limit_exceeded?(new_column) do
      {:error, :wip_limit_reached}
    else
      perform_move(task, new_column, new_position, old_column_id)
    end
  end

  defp wip_limit_exceeded?(new_column) do
    current_count =
      Task
      |> where([t], t.column_id == ^new_column.id)
      |> where([t], t.type in [:work, :defect])
      |> where([t], is_nil(t.archived_at))
      |> Repo.aggregate(:count)

    new_column.wip_limit > 0 and current_count >= new_column.wip_limit
  end

  @doc """
  Reorders tasks within a column based on a list of task IDs.
  """
  def reorder_tasks(column, task_ids) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [column.id])

      # Move all LIVE tasks in the column to temp negative positions to avoid
      # unique constraint violations on the partial (column_id, position) index.
      # Archived tasks are excluded — they keep their stale positions and are
      # never renumbered (and the partial index ignores them anyway).
      Repo.query!(
        "UPDATE tasks SET position = -1 * id WHERE column_id = $1 AND position >= 0 AND archived_at IS NULL",
        [column.id]
      )

      assign_reorder_positions(column, task_ids)
      assign_remaining_positions(column, length(task_ids))
    end)

    :ok
  end

  defp assign_reorder_positions(column, task_ids) do
    task_ids
    |> Enum.with_index()
    |> Enum.each(fn {task_id, index} ->
      Task
      |> where([t], t.id == ^task_id and t.column_id == ^column.id)
      |> Repo.update_all(set: [position: index])
    end)
  end

  defp assign_remaining_positions(column, offset) do
    # Reassign positions to any remaining LIVE tasks still at temp positions
    # (live tasks in the column that were not included in task_ids). Archived
    # tasks were never moved to a temp position, so they are excluded here too.
    remaining_ids =
      Task
      |> where([t], t.column_id == ^column.id and t.position < 0)
      |> where([t], is_nil(t.archived_at))
      |> order_by([t], asc: t.id)
      |> select([t], t.id)
      |> Repo.all()

    remaining_ids
    |> Enum.with_index(offset)
    |> Enum.each(fn {id, pos} ->
      Task
      |> where([t], t.id == ^id)
      |> Repo.update_all(set: [position: pos])
    end)
  end

  @doc """
  Checks if a task can be added to a column (respects WIP limit).
  """
  def can_add_task?(%Column{} = column) do
    if column.wip_limit == 0 do
      true
    else
      current_count =
        Task
        |> where([t], t.column_id == ^column.id)
        |> where([t], t.type in [:work, :defect])
        |> where([t], is_nil(t.archived_at))
        |> Repo.aggregate(:count)

      current_count < column.wip_limit
    end
  end

  @doc """
  Gets the next position for a task in a column.

  WARNING: This function is not safe for concurrent use. If two callers
  read the same max position before either writes, both will get the same
  value, causing a unique constraint violation. Use `get_next_position_locked/1`
  inside a transaction for concurrent-safe position allocation.
  """
  def get_next_position(column) do
    compute_next_position(column.id)
  end

  @doc """
  Gets the next position for a task in a column with an advisory lock.

  Acquires a PostgreSQL transaction-level advisory lock on the column ID,
  serializing all position allocations for that column. This prevents
  duplicate position errors when concurrent operations target the same column.

  MUST be called within a `Repo.transaction` — the lock is released
  automatically when the transaction commits or rolls back.
  """
  def get_next_position_locked(column) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [column.id])
    compute_next_position(column.id)
  end

  defp compute_next_position(column_id) do
    query =
      from t in Task,
        where: t.column_id == ^column_id,
        where: is_nil(t.archived_at),
        select: max(t.position)

    case Repo.one(query) do
      nil -> 0
      max_position -> max_position + 1
    end
  end

  @doc """
  Determines the status updates for a task based on the target column name.
  """
  def determine_status_for_column(column_name, task) do
    if task.status == :blocked do
      %{completed_at: nil}
    else
      case column_name do
        name when name in ["Ready", "Backlog"] ->
          %{status: :open, completed_at: nil}

        name when name in ["Doing", "Review"] ->
          %{status: :in_progress, completed_at: nil}

        "Done" ->
          completed_at = task.completed_at || DateTime.utc_now()
          %{status: :completed, completed_at: completed_at}

        _ ->
          %{status: :in_progress, completed_at: nil}
      end
    end
  end

  @doc """
  Reorders tasks after a task is deleted, decrementing positions.
  """
  def reorder_after_deletion(deleted_task) do
    query =
      from t in Task,
        where: t.column_id == ^deleted_task.column_id,
        where: t.position > ^deleted_task.position,
        where: is_nil(t.archived_at),
        order_by: t.position

    tasks = Repo.all(query)

    Enum.each(tasks, fn task ->
      Kanban.Tasks.update_task(task, %{position: task.position - 1})
    end)
  end

  defp perform_move(task, new_column, new_position, old_column_id) do
    Repo.transaction(fn ->
      # Lock columns in consistent order to prevent deadlocks
      [old_column_id, new_column.id]
      |> Enum.sort()
      |> Enum.each(fn col_id ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [col_id])
      end)

      Logger.info(
        "perform_move: task_id=#{task.id}, old_column=#{old_column_id}, new_column=#{new_column.id}, new_position=#{new_position}, old_position=#{task.position}"
      )

      move_task_to_temp_position(task)

      is_cross_column_move = new_column.id != old_column_id

      if is_cross_column_move do
        handle_cross_column_move(task, new_column, new_position, old_column_id)
      else
        handle_same_column_move(task, new_column, new_position)
      end

      updated_task = finalize_task_move(task, new_column, new_position)

      if is_cross_column_move do
        old_column = Columns.get_column!(old_column_id)
        History.create_move_history(updated_task, old_column.name, new_column.name)

        Goals.update_parent_goal_position(updated_task, old_column_id, new_column.id)
      end

      updated_task
    end)
  end

  defp move_task_to_temp_position(task) do
    temp_position = -1 * task.id

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [position: temp_position])

    Logger.info("Task moved to temporary position #{temp_position}")
  end

  defp handle_cross_column_move(task, new_column, new_position, old_column_id) do
    Logger.info("Moving between columns")

    old_column = Columns.get_column!(old_column_id)
    reorder_after_removal(old_column, task.position)

    target_tasks = Queries.list_tasks(new_column)

    Logger.info(
      "Target column has #{length(target_tasks)} tasks before shift: #{inspect(Enum.map(target_tasks, &{&1.id, &1.position}))}"
    )

    shift_tasks_down_for_insert(new_column, new_position)

    target_tasks_after = Queries.list_tasks(new_column)

    Logger.info(
      "Target column has #{length(target_tasks_after)} tasks after shift: #{inspect(Enum.map(target_tasks_after, &{&1.id, &1.position}))}"
    )
  end

  defp handle_same_column_move(task, column, new_position) do
    cond do
      new_position < task.position ->
        shift_tasks_down_for_insert_range(column, new_position, task.position - 1)

      new_position > task.position ->
        shift_tasks_up_for_insert_range(column, task.position + 1, new_position)

      true ->
        :ok
    end
  end

  defp finalize_task_move(task, new_column, new_position) do
    Logger.info(
      "Updating task #{task.id} to final position: column_id=#{new_column.id}, position=#{new_position}"
    )

    status_updates = determine_status_for_column(new_column.name, task)
    updates = Map.merge(%{column_id: new_column.id, position: new_position}, status_updates)

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: Map.to_list(updates))

    Logger.info("Task updated successfully with status: #{inspect(updates[:status])}")

    updated_task = Queries.get_task!(task.id)
    Logger.info("Returning updated task: #{inspect(updated_task)}")

    updated_task
  end

  defp reorder_after_removal(column, removed_position) do
    query =
      from t in Task,
        where: t.column_id == ^column.id,
        where: t.position > ^removed_position,
        where: is_nil(t.archived_at),
        order_by: t.position

    tasks = Repo.all(query)

    Enum.each(tasks, fn task ->
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: task.position - 1])
    end)
  end

  defp shift_tasks_down_for_insert(column, start_position) do
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> where([t], is_nil(t.archived_at))
      |> order_by([t], desc: t.position)
      |> Repo.all()

    Logger.info("Shifting #{length(tasks_to_shift)} tasks down from position #{start_position}")

    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position + 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end

  defp shift_tasks_down_for_insert_range(column, start_position, end_position) do
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> where([t], t.position <= ^end_position)
      |> where([t], is_nil(t.archived_at))
      |> order_by([t], desc: t.position)
      |> Repo.all()

    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position + 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end

  defp shift_tasks_up_for_insert_range(column, start_position, end_position) do
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> where([t], t.position <= ^end_position)
      |> where([t], is_nil(t.archived_at))
      |> order_by([t], asc: t.position)
      |> Repo.all()

    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position - 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end
end
