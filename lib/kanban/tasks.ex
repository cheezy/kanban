defmodule Kanban.Tasks do
  @moduledoc """
  The Tasks context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

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
  Gets a single task with preloaded task histories ordered by most recent first.

  Raises `Ecto.NoResultsError` if the Task does not exist.

  ## Examples

      iex> get_task_with_history!(123)
      %Task{task_histories: [%TaskHistory{}, ...]}

  """
  def get_task_with_history!(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload(task_histories: from(h in TaskHistory, order_by: [desc: h.inserted_at]))
  end

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
      task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
      identifier = generate_identifier(column, task_type)

      attrs =
        attrs
        |> prepare_task_attrs(next_position)
        |> Map.put(:identifier, identifier)

      # Use Multi to insert task and history in a transaction
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:task, Task.changeset(%Task{column_id: column.id}, attrs))
      |> Ecto.Multi.insert(:history, fn %{task: task} ->
        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: task.id,
          type: :creation
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} -> {:ok, task}
        {:error, :task, changeset, _} -> {:error, changeset}
        {:error, :history, changeset, _} -> {:error, changeset}
      end
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
    require Logger

    Repo.transaction(fn ->
      Logger.info("perform_move: task_id=#{task.id}, old_column=#{old_column_id}, new_column=#{new_column.id}, new_position=#{new_position}, old_position=#{task.position}")

      move_task_to_temp_position(task)

      # Track if this is a cross-column move for history
      is_cross_column_move = new_column.id != old_column_id

      if is_cross_column_move do
        handle_cross_column_move(task, new_column, new_position, old_column_id)
      else
        handle_same_column_move(task, new_column, new_position)
      end

      updated_task = finalize_task_move(task, new_column, new_position)

      # Create history record if moving between columns
      if is_cross_column_move do
        old_column = Columns.get_column!(old_column_id)
        create_move_history(updated_task, old_column.name, new_column.name)
      end

      updated_task
    end)
  end

  defp move_task_to_temp_position(task) do
    require Logger
    temp_position = -1 * task.id

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [position: temp_position])

    Logger.info("Task moved to temporary position #{temp_position}")
  end

  defp handle_cross_column_move(task, new_column, new_position, old_column_id) do
    require Logger
    Logger.info("Moving between columns")

    old_column = Columns.get_column!(old_column_id)
    reorder_after_removal(old_column, task.position)

    # Log target column state before shift
    target_tasks = list_tasks(new_column)
    Logger.info("Target column has #{length(target_tasks)} tasks before shift: #{inspect(Enum.map(target_tasks, &{&1.id, &1.position}))}")

    # Make space in target column
    shift_tasks_down_for_insert(new_column, new_position)

    # Log target column state after shift
    target_tasks_after = list_tasks(new_column)
    Logger.info("Target column has #{length(target_tasks_after)} tasks after shift: #{inspect(Enum.map(target_tasks_after, &{&1.id, &1.position}))}")
  end

  defp handle_same_column_move(task, column, new_position) do
    cond do
      new_position < task.position ->
        # Moving up: shift tasks down from new_position to old_position-1
        shift_tasks_down_for_insert_range(column, new_position, task.position - 1)

      new_position > task.position ->
        # Moving down: shift tasks up from old_position+1 to new_position
        shift_tasks_up_for_insert_range(column, task.position + 1, new_position)

      true ->
        # No movement needed if positions are the same
        :ok
    end
  end

  defp finalize_task_move(task, new_column, new_position) do
    require Logger
    Logger.info("Updating task #{task.id} to final position: column_id=#{new_column.id}, position=#{new_position}")

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [column_id: new_column.id, position: new_position])

    Logger.info("Task updated successfully")

    updated_task = get_task!(task.id)
    Logger.info("Returning updated task: #{inspect(updated_task)}")
    updated_task
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
    require Logger

    # Get all tasks at or after start_position
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> order_by([t], desc: t.position)
      |> Repo.all()

    Logger.info("Shifting #{length(tasks_to_shift)} tasks down from position #{start_position}")

    # First, move all tasks to temporary negative positions to avoid constraint violations
    # We use descending order to avoid conflicts
    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    # Then, update each task to its final position (original + 1)
    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position + 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end

  defp shift_tasks_down_for_insert_range(column, start_position, end_position) do
    # Get all tasks in range
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> where([t], t.position <= ^end_position)
      |> order_by([t], desc: t.position)
      |> Repo.all()

    # First, move all tasks to temporary negative positions
    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    # Then, update each task to its final position (original + 1)
    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position + 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end

  defp shift_tasks_up_for_insert_range(column, start_position, end_position) do
    # Get all tasks in range (ascending order for upward shift)
    tasks_to_shift =
      Task
      |> where([t], t.column_id == ^column.id)
      |> where([t], t.position >= ^start_position)
      |> where([t], t.position <= ^end_position)
      |> order_by([t], asc: t.position)
      |> Repo.all()

    # First, move all tasks to temporary negative positions
    Enum.each(tasks_to_shift, fn task ->
      temp_position = -1000 - task.id

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: temp_position])
    end)

    # Then, update each task to its final position (original - 1)
    Enum.each(tasks_to_shift, fn task ->
      new_position = task.position - 1

      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: new_position])
    end)
  end

  defp generate_identifier(column, task_type) do
    # Preload the column's board to get board_id
    column = Repo.preload(column, :board)

    # Normalize task_type to atom
    task_type =
      case task_type do
        "work" -> :work
        "defect" -> :defect
        atom when is_atom(atom) -> atom
      end

    # Count tasks of the same type across all columns in the board
    count =
      Task
      |> join(:inner, [t], c in Column, on: t.column_id == c.id)
      |> where([t, c], c.board_id == ^column.board_id)
      |> where([t, c], t.type == ^task_type)
      |> Repo.aggregate(:count)

    # Generate identifier: W1, W2, D1, D2, etc.
    prefix = if task_type == :work, do: "W", else: "D"
    "#{prefix}#{count + 1}"
  end

  defp create_move_history(task, from_column_name, to_column_name) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task.id,
      type: :move,
      from_column: from_column_name,
      to_column: to_column_name
    })
    |> Repo.insert!()
  end
end
