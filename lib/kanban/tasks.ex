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
    |> preload(:assigned_to)
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
  def get_task!(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload(:assigned_to)
  end

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
    |> Repo.preload(
      task_histories:
        from(h in TaskHistory,
          order_by: [desc: h.inserted_at],
          preload: [:from_user, :to_user]
        )
    )
  end

  @doc """
  Gets a single task with all related data preloaded for read-only view.

  Raises `Ecto.NoResultsError` if the Task does not exist.

  ## Examples

      iex> get_task_for_view!(123)
      %Task{task_histories: [...], comments: [...], assigned_to: %User{}, column: %Column{}}

  """
  def get_task_for_view!(id) do
    alias Kanban.Tasks.TaskComment

    Task
    |> Repo.get!(id)
    |> Repo.preload([
      :assigned_to,
      :column,
      :created_by,
      :completed_by,
      :reviewed_by,
      task_histories:
        from(h in TaskHistory,
          order_by: [desc: h.inserted_at],
          preload: [:from_user, :to_user]
        ),
      comments: from(c in TaskComment, order_by: [asc: c.inserted_at])
    ])
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
      attrs = prepare_task_creation_attrs(column, attrs)

      column
      |> insert_task_with_history(attrs)
      |> emit_task_creation_telemetry(column)
    else
      {:error, :wip_limit_reached}
    end
  end

  defp prepare_task_creation_attrs(column, attrs) do
    next_position = get_next_position(column)
    task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
    identifier = generate_identifier(column, task_type)

    attrs
    |> prepare_task_attrs(next_position)
    |> Map.put(:identifier, identifier)
  end

  defp insert_task_with_history(column, attrs) do
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
  end

  defp emit_task_creation_telemetry({:ok, task} = result, column) do
    :telemetry.execute([:kanban, :task, :creation], %{count: 1}, %{
      task_id: task.id,
      column_id: column.id
    })

    # Broadcast task creation
    broadcast_task_change(task, :task_created)

    result
  end

  defp emit_task_creation_telemetry(error, _column), do: error

  @doc """
  Updates a task.

  ## Examples

      iex> update_task(task, %{title: "Updated Title"})
      {:ok, %Task{}}

      iex> update_task(task, %{title: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_task(%Task{} = task, attrs) do
    changeset = Task.changeset(task, attrs)
    priority_changed? = Map.has_key?(changeset.changes, :priority)
    assignment_changed? = Map.has_key?(changeset.changes, :assigned_to_id)

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        if priority_changed? do
          create_priority_change_history(task.priority, updated_task.priority, updated_task.id)
        end

        if assignment_changed? do
          create_assignment_history(
            task.assigned_to_id,
            updated_task.assigned_to_id,
            updated_task.id
          )
        end

        # Broadcast specific event based on what changed
        broadcast_task_update(updated_task, changeset)

        {:ok, updated_task}

      error ->
        error
    end
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
        # Broadcast task deletion
        broadcast_task_change(deleted_task, :task_deleted)
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
    result =
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

    # Broadcast AFTER transaction commits
    case result do
      {:ok, updated_task} ->
        broadcast_task_change(updated_task, :task_moved)
        {:ok, updated_task}

      error ->
        error
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
      Logger.info(
        "perform_move: task_id=#{task.id}, old_column=#{old_column_id}, new_column=#{new_column.id}, new_position=#{new_position}, old_position=#{task.position}"
      )

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

    Logger.info(
      "Target column has #{length(target_tasks)} tasks before shift: #{inspect(Enum.map(target_tasks, &{&1.id, &1.position}))}"
    )

    # Make space in target column
    shift_tasks_down_for_insert(new_column, new_position)

    # Log target column state after shift
    target_tasks_after = list_tasks(new_column)

    Logger.info(
      "Target column has #{length(target_tasks_after)} tasks after shift: #{inspect(Enum.map(target_tasks_after, &{&1.id, &1.position}))}"
    )
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

    Logger.info(
      "Updating task #{task.id} to final position: column_id=#{new_column.id}, position=#{new_position}"
    )

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [column_id: new_column.id, position: new_position])

    Logger.info("Task updated successfully")

    updated_task = get_task!(task.id)
    Logger.info("Returning updated task: #{inspect(updated_task)}")

    # Broadcast will happen AFTER transaction commits (in move_task/3)
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

  defp generate_identifier(_column, task_type) do
    # Normalize task_type to atom
    task_type =
      case task_type do
        "work" -> :work
        "defect" -> :defect
        atom when is_atom(atom) -> atom
      end

    # Get the prefix for this task type
    prefix = if task_type == :work, do: "W", else: "D"

    # Find the maximum identifier number for this type across ALL tasks
    # Since identifier has a global unique constraint, we need global uniqueness
    max_number =
      Task
      |> where([t], t.type == ^task_type)
      |> select([t], t.identifier)
      |> Repo.all()
      |> Enum.map(fn identifier ->
        # Extract numeric part (e.g., "W11" -> 11, "W01A" -> 1)
        # Remove prefix and extract only leading digits
        identifier
        |> String.replace(prefix, "")
        |> String.replace(~r/[^0-9].*$/, "")
        |> case do
          "" -> 0
          num_str -> String.to_integer(num_str)
        end
      end)
      |> case do
        [] -> 0
        numbers -> Enum.max(numbers)
      end

    # Generate identifier: W1, W2, D1, D2, etc.
    "#{prefix}#{max_number + 1}"
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

  defp create_priority_change_history(from_priority, to_priority, task_id) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task_id,
      type: :priority_change,
      from_priority: Atom.to_string(from_priority),
      to_priority: Atom.to_string(to_priority)
    })
    |> Repo.insert!()
  end

  defp create_assignment_history(from_user_id, to_user_id, task_id) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task_id,
      type: :assignment,
      from_user_id: from_user_id,
      to_user_id: to_user_id
    })
    |> Repo.insert!()
  end

  defp broadcast_task_change(%Task{} = task, event) do
    require Logger
    # Get the task's column to know which board to broadcast to
    task_with_column = Repo.preload(task, [:column, :created_by, :completed_by, :reviewed_by])
    column = task_with_column.column

    if column do
      # Get the board_id from the column
      column_with_board = Repo.preload(column, :board)
      board_id = column_with_board.board.id

      Logger.info("Broadcasting #{event} for task #{task.id} to board:#{board_id}")

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{board_id}",
        {__MODULE__, event, task_with_column}
      )

      # Telemetry event for monitoring
      :telemetry.execute(
        [:kanban, :pubsub, :broadcast],
        %{count: 1},
        %{event: event, task_id: task.id, board_id: board_id}
      )
    else
      Logger.warning("Cannot broadcast #{event} for task #{task.id} - no column found")
    end
  end

  # Helper to broadcast specific events based on changeset changes
  defp broadcast_task_update(%Task{} = task, %Ecto.Changeset{} = changeset) do
    cond do
      Map.has_key?(changeset.changes, :status) ->
        broadcast_task_change(task, :task_status_changed)
      Map.has_key?(changeset.changes, :claimed_at) ->
        broadcast_task_change(task, :task_claimed)
      Map.has_key?(changeset.changes, :completed_at) ->
        broadcast_task_change(task, :task_completed)
      Map.has_key?(changeset.changes, :review_status) ->
        broadcast_task_change(task, :task_reviewed)
      true ->
        broadcast_task_change(task, :task_updated)
    end
  end

  @doc """
  Returns all tasks that modify a specific file.

  Uses PostgreSQL's @> (contains) operator with GIN index for fast lookups.

  ## Examples

      iex> get_tasks_modifying_file("lib/kanban/tasks.ex")
      [%Task{}, ...]

  """
  def get_tasks_modifying_file(file_path) do
    # Query for tasks where key_files JSONB array contains an element with file_path
    from(t in Task,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'file_path' = ?)",
          t.key_files,
          ^file_path
        )
    )
    |> Repo.all()
  end

  @doc """
  Returns all tasks that require a specific technology.

  Uses PostgreSQL's array contains operator.

  ## Examples

      iex> get_tasks_requiring_technology("ecto")
      [%Task{}, ...]

  """
  def get_tasks_requiring_technology(tech) do
    # Query for tasks where technology_requirements JSONB array contains the tech string
    # Pass the array directly and let Ecto handle the JSONB conversion
    from(t in Task,
      where: fragment("? @> ?", t.technology_requirements, ^[tech])
    )
    |> Repo.all()
  end

  @doc """
  Returns all tasks with command-based verification steps.

  ## Examples

      iex> get_tasks_with_automated_verification()
      [%Task{}, ...]

  """
  def get_tasks_with_automated_verification do
    from(t in Task,
      where:
        fragment(
          "? @> ?::jsonb",
          t.verification_steps,
          ^Jason.encode!([%{step_type: "command"}])
        )
    )
    |> Repo.all()
  end
end
