defmodule Kanban.Tasks do
  @moduledoc """
  The Tasks context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Returns the list of tasks for a column, ordered by position.

  ## Examples

      iex> list_tasks(column)
      [%Task{}, ...]

  """
  def list_tasks(column) do
    Task
    |> where([t], t.column_id == ^column.id)
    |> order_by([t], t.position)
    |> Repo.all()
  end

  @doc """
  Gets a single task.

  Raises `Ecto.NoResultsError` if the Task does not exist.

  ## Examples

      iex> get_task!(123)
      %Task{}

      iex> get_task!(456)
      ** (Ecto.NoResultsError)

  """
  def get_task!(id), do: Repo.get!(Task, id)

  @doc """
  Creates a task for a column with automatic position assignment.
  Respects WIP limit - returns error if column is at capacity.

  ## Examples

      iex> create_task(column, %{title: "New Task"})
      {:ok, %Task{}}

      iex> create_task(column, %{title: nil})
      {:error, %Ecto.Changeset{}}

      iex> create_task(full_column, %{title: "Task"})
      {:error, :wip_limit_reached}

  """
  def create_task(column, attrs \\ %{}) do
    # Check WIP limit before creating
    if can_add_task?(column) do
      next_position = get_next_position(column)
      attrs = prepare_task_attrs(attrs, next_position)

      %Task{column_id: column.id}
      |> Task.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :wip_limit_reached}
    end
  end

  @doc """
  Updates a task.

  ## Examples

      iex> update_task(task, %{title: "Updated Title"})
      {:ok, %Task{}}

      iex> update_task(task, %{title: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a task and reorders the remaining tasks.

  ## Examples

      iex> delete_task(task)
      {:ok, %Task{}}

      iex> delete_task(task)
      {:error, %Ecto.Changeset{}}

  """
  def delete_task(%Task{} = task) do
    result = Repo.delete(task)

    # Reorder remaining tasks after deletion
    case result do
      {:ok, deleted_task} ->
        reorder_after_deletion(deleted_task)
        {:ok, deleted_task}

      error ->
        error
    end
  end

  @doc """
  Moves a task to a different column at a specific position.
  Respects WIP limit of target column.

  ## Examples

      iex> move_task(task, new_column, 0)
      {:ok, %Task{}}

      iex> move_task(task, full_column, 0)
      {:error, :wip_limit_reached}

  """
  def move_task(%Task{} = task, %Column{} = new_column, new_position) do
    old_column_id = task.column_id

    # If moving to a different column, check WIP limit
    if new_column.id != old_column_id do
      # Count current tasks in target column (excluding this task if it's already there)
      current_count =
        Task
        |> where([t], t.column_id == ^new_column.id)
        |> Repo.aggregate(:count)

      # Check if we can add to the target column
      if new_column.wip_limit > 0 and current_count >= new_column.wip_limit do
        {:error, :wip_limit_reached}
      else
        perform_move(task, new_column, new_position, old_column_id)
      end
    else
      # Moving within same column, no WIP limit check needed
      perform_move(task, new_column, new_position, old_column_id)
    end
  end

  @doc """
  Reorders tasks within a column based on a list of task IDs.

  ## Examples

      iex> reorder_tasks(column, [3, 1, 2])
      :ok

  """
  def reorder_tasks(column, task_ids) do
    # Use a transaction to handle the unique constraint on (column_id, position)
    Repo.transaction(fn ->
      # First, set all positions to large negative values based on ID to avoid constraint violations
      tasks = list_tasks(column)

      Enum.each(tasks, fn task ->
        Task
        |> where([t], t.id == ^task.id)
        |> Repo.update_all(set: [position: -1 * task.id])
      end)

      # Then update each task with its new position
      task_ids
      |> Enum.with_index()
      |> Enum.each(fn {task_id, index} ->
        Task
        |> where([t], t.id == ^task_id and t.column_id == ^column.id)
        |> Repo.update_all(set: [position: index])
      end)
    end)

    :ok
  end

  @doc """
  Checks if a task can be added to a column (respects WIP limit).

  ## Examples

      iex> can_add_task?(column)
      true

      iex> can_add_task?(full_column)
      false

  """
  def can_add_task?(%Column{} = column) do
    # WIP limit of 0 means no limit
    if column.wip_limit == 0 do
      true
    else
      current_count =
        Task
        |> where([t], t.column_id == ^column.id)
        |> Repo.aggregate(:count)

      current_count < column.wip_limit
    end
  end

  # Private functions

  defp prepare_task_attrs(attrs, position) do
    case attrs do
      %{} = map when is_map_key(map, "title") or is_map_key(map, :title) ->
        # Convert to atom keys if needed, then add position
        attrs
        |> Enum.into(%{}, fn
          {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
          {k, v} -> {k, v}
        end)
        |> Map.put(:position, position)

      _ ->
        Map.put(attrs, :position, position)
    end
  end

  defp get_next_position(column) do
    query =
      from t in Task,
        where: t.column_id == ^column.id,
        select: max(t.position)

    case Repo.one(query) do
      nil -> 0
      max_position -> max_position + 1
    end
  end

  defp reorder_after_deletion(deleted_task) do
    # Get all tasks after the deleted position in the same column
    query =
      from t in Task,
        where: t.column_id == ^deleted_task.column_id,
        where: t.position > ^deleted_task.position,
        order_by: t.position

    tasks = Repo.all(query)

    # Decrement the position of each task
    Enum.each(tasks, fn task ->
      update_task(task, %{position: task.position - 1})
    end)
  end

  defp perform_move(task, new_column, new_position, old_column_id) do
    Repo.transaction(fn ->
      # Step 1: Move task to a temporary position to avoid constraint violations
      temp_position = -1 * task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])

      # Step 2: Handle the source column (if moving between columns)
      if new_column.id != old_column_id do
        old_column = Columns.get_column!(old_column_id)
        reorder_after_removal(old_column, task.position)

        # Make space in the target column
        shift_tasks_down_for_insert(new_column, new_position)
      else
        # Moving within the same column
        cond do
          new_position < task.position ->
            # Moving up: shift tasks down from new_position to old_position-1
            shift_tasks_down_for_insert_range(new_column, new_position, task.position - 1)

          new_position > task.position ->
            # Moving down: shift tasks up from old_position+1 to new_position
            shift_tasks_up_for_insert_range(new_column, task.position + 1, new_position)

          true ->
            # No movement needed if positions are the same
            :ok
        end
      end

      # Step 3: Update the task to its final position
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [column_id: new_column.id, position: new_position])

      # Return the updated task
      get_task!(task.id)
    end)
  end

  defp reorder_after_removal(column, removed_position) do
    # Get all tasks after the removed position
    query =
      from t in Task,
        where: t.column_id == ^column.id,
        where: t.position > ^removed_position,
        order_by: t.position

    tasks = Repo.all(query)

    # Decrement the position of each task
    Enum.each(tasks, fn task ->
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: task.position - 1])
    end)
  end

  defp shift_tasks_down_for_insert(column, start_position) do
    # Shift all tasks at or after start_position down by 1
    Task
    |> where([t], t.column_id == ^column.id)
    |> where([t], t.position >= ^start_position)
    |> Repo.update_all(inc: [position: 1])
  end

  defp shift_tasks_down_for_insert_range(column, start_position, end_position) do
    # Shift tasks in range down by 1
    Task
    |> where([t], t.column_id == ^column.id)
    |> where([t], t.position >= ^start_position)
    |> where([t], t.position <= ^end_position)
    |> Repo.update_all(inc: [position: 1])
  end

  defp shift_tasks_up_for_insert_range(column, start_position, end_position) do
    # Shift tasks in range up by 1
    Task
    |> where([t], t.column_id == ^column.id)
    |> where([t], t.position >= ^start_position)
    |> where([t], t.position <= ^end_position)
    |> Repo.update_all(inc: [position: -1])
  end
end
