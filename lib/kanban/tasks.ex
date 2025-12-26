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
  Gets a task by its identifier (e.g. "W14", "D5") with all associations preloaded.

  Raises `Ecto.NoResultsError` if the Task does not exist or doesn't belong to
  any of the given column_ids.

  ## Examples

      iex> get_task_by_identifier_for_view!("W14", [1, 2, 3])
      %Task{identifier: "W14", ...}

      iex> get_task_by_identifier_for_view!("INVALID", [1, 2, 3])
      ** (Ecto.NoResultsError)

  """
  def get_task_by_identifier_for_view!(identifier, column_ids) do
    alias Kanban.Tasks.TaskComment

    Task
    |> where([t], t.identifier == ^identifier and t.column_id in ^column_ids)
    |> Repo.one!()
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

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    # Use string or atom key based on what position key was used
    identifier_key = if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    Map.put(prepared_attrs, identifier_key, identifier)
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
    |> handle_task_creation_result(attrs)
  end

  defp handle_task_creation_result(transaction_result, attrs) do
    case transaction_result do
      {:ok, %{task: task}} ->
        update_blocking_status_after_creation(task, attrs)
        {:ok, task}

      {:error, :task, changeset, _} ->
        {:error, changeset}

      {:error, :history, changeset, _} ->
        {:error, changeset}
    end
  end

  defp update_blocking_status_after_creation(task, attrs) do
    dependencies = Map.get(attrs, :dependencies, Map.get(attrs, "dependencies", []))

    if dependencies != [] do
      update_task_blocking_status(task)
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
    dependencies_changed? = Map.has_key?(changeset.changes, :dependencies)

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

        if dependencies_changed? do
          update_task_blocking_status(updated_task)
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

  Returns {:error, :has_dependents} if other tasks depend on this task.

  ## Examples

      iex> delete_task(task)
      {:ok, %Task{}}

      iex> delete_task(task)
      {:error, %Ecto.Changeset{}}

  """
  def delete_task(%Task{} = task) do
    dependent_tasks = get_dependent_tasks(task)

    if dependent_tasks != [] do
      {:error, :has_dependents}
    else
      result = Repo.delete(task)

      case result do
        {:ok, deleted_task} ->
          reorder_after_deletion(deleted_task)
          broadcast_task_change(deleted_task, :task_deleted)
          {:ok, deleted_task}

        error ->
          error
      end
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
    # Check if map has string keys by looking for any string key
    has_string_keys? = Map.keys(attrs) |> Enum.any?(&is_binary/1)

    if has_string_keys? do
      # Map has string keys, keep position as string too
      Map.put(attrs, "position", position)
    else
      # Map has atom keys, keep position as atom
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

  @doc """
  Gets the next task for an AI agent to work on.

  Returns the next available task from the "Ready" column using optimized filtering:
  1. Tasks in "Ready" column (indexed lookup)
  2. Agent has all required capabilities (array operation)
  3. All dependencies completed (subquery check)
  4. No key_file conflicts with tasks in "Doing" or "Review" (JSONB comparison)
  5. Ordered by priority (descending), then position (ascending)

  Has status "open" (not claimed) OR has expired claim.
  Returns nil if no task available.

  ## Examples

      iex> get_next_task(["code_generation", "testing"])
      %Task{}

      iex> get_next_task([])
      nil

  """
  def get_next_task(agent_capabilities \\ [], board_id) do
    now = DateTime.utc_now()

    # Subquery to find completed task identifiers
    completed_task_identifiers =
      from(t in Task,
        where: t.status == :completed,
        select: t.identifier
      )

    # Subquery to find task IDs with key_file conflicts in Doing or Review
    conflicting_task_ids =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: c.name in ["Doing", "Review"],
        where: c.board_id == ^board_id,
        where: t.status == :in_progress,
        select: %{
          id: t.id,
          key_files: t.key_files
        }
      )
      |> Repo.all()

    # Main query for next task
    query =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: c.name == "Ready",
        where: c.board_id == ^board_id,
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        order_by: [desc: t.priority, asc: t.position],
        preload: [:column, :assigned_to, :created_by]
      )

    # Apply capability filter (always check that agent has required capabilities)
    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.required_capabilities) == 0 or
            fragment("? <@ ?", t.required_capabilities, ^agent_capabilities)
      )

    # Apply dependency filter
    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.dependencies) == 0 or
            fragment(
              "NOT EXISTS (
                SELECT 1
                FROM unnest(?) AS dep_id
                WHERE dep_id NOT IN (?)
              )",
              t.dependencies,
              subquery(completed_task_identifiers)
            )
      )

    # Get all potential tasks and find first without key_file conflicts
    tasks = Repo.all(query)

    Enum.find(tasks, fn task ->
      not has_key_file_conflict?(task, conflicting_task_ids)
    end)
  end

  defp has_key_file_conflict?(task, conflicting_tasks) do
    if task.key_files && not Enum.empty?(task.key_files) do
      task_file_paths =
        task.key_files
        |> Enum.map(fn kf -> kf.file_path end)
        |> Enum.reject(&is_nil/1)

      Enum.any?(conflicting_tasks, fn conflict ->
        if conflict.key_files && not Enum.empty?(conflict.key_files) do
          conflict_paths =
            conflict.key_files
            |> Enum.map(fn kf -> kf.file_path end)
            |> Enum.reject(&is_nil/1)

          Enum.any?(task_file_paths, fn path -> path in conflict_paths end)
        else
          false
        end
      end)
    else
      false
    end
  end

  @doc """
  Atomically claims the next available task for an AI agent, or a specific task by identifier.

  Updates the task status to "in_progress", sets claimed_at, claim_expires_at,
  assigned_to, and moves it to the "Doing" column.

  Returns {:ok, task} if successful, {:error, reason} if unsuccessful.

  ## Examples

      iex> claim_next_task(["code_generation"], user, board_id)
      {:ok, %Task{}}

      iex> claim_next_task(["code_generation"], user, board_id, "W15")
      {:ok, %Task{}}

      iex> claim_next_task([], user, board_id)
      {:error, :no_tasks_available}

  """
  def claim_next_task(agent_capabilities \\ [], user, board_id, task_identifier \\ nil) do
    task =
      if task_identifier do
        get_specific_task_for_claim(task_identifier, agent_capabilities, board_id)
      else
        get_next_task(agent_capabilities, board_id)
      end

    case task do
      nil ->
        {:error, :no_tasks_available}

      task ->
        perform_claim(task, user, board_id)
    end
  end

  defp get_specific_task_for_claim(identifier, agent_capabilities, board_id) do
    now = DateTime.utc_now()

    completed_task_ids =
      from(t in Task,
        where: t.status == :completed,
        select: fragment("?::text", t.id)
      )

    query =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: t.identifier == ^identifier,
        where: c.board_id == ^board_id,
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        preload: [:column, :assigned_to, :created_by]
      )

    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.required_capabilities) == 0 or
            fragment("? <@ ?", t.required_capabilities, ^agent_capabilities)
      )

    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.dependencies) == 0 or
            fragment(
              "NOT EXISTS (
                SELECT 1
                FROM unnest(?) AS dep_id
                WHERE dep_id NOT IN (?)
              )",
              t.dependencies,
              subquery(completed_task_ids)
            )
      )

    Repo.one(query)
  end

  defp perform_claim(task, user, board_id) do
    doing_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Doing"
      )
      |> Repo.one()

    now = DateTime.utc_now()
    expires_at = now |> DateTime.add(60 * 60, :second)
    next_position = get_next_position(doing_column)

    update_query =
      from(t in Task,
        where: t.id == ^task.id,
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now)
      )

    case Repo.update_all(
           update_query,
           set: [
             status: :in_progress,
             claimed_at: now,
             claim_expires_at: expires_at,
             assigned_to_id: user.id,
             column_id: doing_column.id,
             position: next_position,
             updated_at: now
           ]
         ) do
      {1, _} ->
        updated_task = get_task_for_view!(task.id)

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_updated, updated_task}
        )

        {:ok, updated_task}

      {0, _} ->
        {:error, :no_tasks_available}
    end
  end

  @doc """
  Releases a claimed task back to the "open" status and "Ready" column.

  Clears claimed_at, claim_expires_at, and assigned_to fields.
  Optionally accepts a reason for analytics.

  Returns {:ok, task} if successful, {:error, reason} otherwise.

  ## Examples

      iex> unclaim_task(task, user, "task too complex")
      {:ok, %Task{}}

      iex> unclaim_task(task, wrong_user)
      {:error, :not_authorized}

  """
  def unclaim_task(task, user, reason \\ nil) do
    task = Repo.preload(task, [:column, :assigned_to])

    cond do
      task.status != :in_progress ->
        {:error, :not_claimed}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        ready_column =
          from(c in Column,
            where: c.board_id == ^task.column.board_id and c.name == "Ready"
          )
          |> Repo.one()

        changeset =
          task
          |> Ecto.Changeset.change(%{
            status: :open,
            claimed_at: nil,
            claim_expires_at: nil,
            assigned_to_id: nil,
            column_id: ready_column.id
          })

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])

            if reason do
              require Logger
              Logger.info("Task #{task.id} unclaimed by user #{user.id}. Reason: #{reason}")
            end

            Phoenix.PubSub.broadcast(
              Kanban.PubSub,
              "board:#{task.column.board_id}",
              {:task_updated, updated_task}
            )

            {:ok, updated_task}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Completes a task by moving it to the Review column with completion summary.

  Stores completion details (summary, actual complexity, files changed, time spent)
  and moves the task from Doing to Review. Status remains "in_progress" - final
  completion (moving to Done with status="completed") is handled by mark_done.

  ## Parameters

    * task - The task to complete
    * user - The user completing the task
    * params - Map with completion data:
      * completion_summary - String (JSON) with completion details
      * actual_complexity - Actual complexity (:small, :medium, :large)
      * actual_files_changed - Integer count of files changed
      * time_spent_minutes - Integer minutes spent

  ## Examples

      iex> complete_task(task, user, %{
        "completion_summary" => "{...json...}",
        "actual_complexity" => "medium",
        "actual_files_changed" => 3,
        "time_spent_minutes" => 25
      })
      {:ok, %Task{}}

  """
  def complete_task(task, user, params) do
    task = Repo.preload(task, [:column, :assigned_to])
    board_id = task.column.board_id

    cond do
      task.status not in [:in_progress, :blocked] ->
        {:error, :invalid_status}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      true ->
        review_column =
          from(c in Column,
            where: c.board_id == ^board_id and c.name == "Review"
          )
          |> Repo.one()

        next_position = get_next_position(review_column)

        changeset =
          task
          |> Ecto.Changeset.cast(params, [
            :completion_summary,
            :actual_complexity,
            :actual_files_changed,
            :time_spent_minutes
          ])
          |> Ecto.Changeset.put_change(:column_id, review_column.id)
          |> Ecto.Changeset.put_change(:position, next_position)
          |> Ecto.Changeset.put_change(:completed_by_id, user.id)
          |> Ecto.Changeset.validate_required([
            :completion_summary,
            :actual_complexity,
            :actual_files_changed,
            :time_spent_minutes
          ])
          |> Ecto.Changeset.validate_inclusion(:actual_complexity, [:small, :medium, :large])
          |> Ecto.Changeset.validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])

            require Logger

            Logger.info(
              "Task #{task.id} completed and moved to Review by user #{user.id}. Time spent: #{params["time_spent_minutes"]} minutes"
            )

            :telemetry.execute(
              [:kanban, :task, :moved_to_review],
              %{task_id: updated_task.id, time_spent_minutes: params["time_spent_minutes"]},
              %{completed_by_id: user.id}
            )

            Phoenix.PubSub.broadcast(
              Kanban.PubSub,
              "board:#{board_id}",
              {:task_moved_to_review, updated_task}
            )

            {:ok, updated_task}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Marks a task as done by moving it from Review to Done column.

  Sets status to :completed, sets completed_at timestamp,
  and moves the task to the Done column. This is the final step in the task workflow.

  Only tasks in the Review column can be marked as done.

  ## Parameters

    * task - The task to mark as done
    * user - The user marking the task as done

  ## Examples

      iex> mark_done(task, user)
      {:ok, %Task{}}

  """
  def mark_done(task, user) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    if task.column.name != "Review" do
      {:error, :invalid_column}
    else
      done_column =
        from(c in Column,
          where: c.board_id == ^board_id and c.name == "Done"
        )
        |> Repo.one()

      next_position = get_next_position(done_column)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        task
        |> Ecto.Changeset.change(%{
          status: :completed,
          completed_at: now,
          column_id: done_column.id,
          position: next_position
        })

      case Repo.update(changeset) do
        {:ok, _updated_task} ->
          updated_task = get_task_for_view!(task.id)

          require Logger
          Logger.info("Task #{task.id} marked as done by user #{user.id}")

          :telemetry.execute(
            [:kanban, :task, :completed],
            %{task_id: updated_task.id},
            %{completed_by: user.id}
          )

          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{board_id}",
            {:task_completed, updated_task}
          )

          unblock_dependent_tasks(updated_task.identifier)

          {:ok, updated_task}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Updates a task's blocked status based on its dependencies.

  Sets status to :blocked if any dependencies are incomplete,
  or to :open if all dependencies are complete.

  ## Examples

      iex> update_task_blocking_status(task)
      {:ok, %Task{status: :blocked}}

  """
  def update_task_blocking_status(task) do
    task = Repo.preload(task, [:column])

    dependencies = task.dependencies || []

    if Enum.empty?(dependencies) do
      {:ok, task}
    else
      incomplete_deps = get_incomplete_dependencies(dependencies)

      new_status =
        if Enum.empty?(incomplete_deps) do
          :open
        else
          :blocked
        end

      if task.status != new_status && task.status != :completed do
        changeset = Ecto.Changeset.change(task, %{status: new_status})

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            board_id = task.column.board_id

            Phoenix.PubSub.broadcast(
              Kanban.PubSub,
              "board:#{board_id}",
              {:task_updated, updated_task}
            )

            {:ok, updated_task}

          {:error, changeset} ->
            {:error, changeset}
        end
      else
        {:ok, task}
      end
    end
  end

  @doc """
  Gets all tasks that are blocked by incomplete dependencies and unblocks them
  if their dependencies are now complete.

  Called after a task is marked as done to unblock dependent tasks.

  ## Examples

      iex> unblock_dependent_tasks("W15")
      :ok

  """
  def unblock_dependent_tasks(completed_task_identifier) do
    dependent_tasks =
      from(t in Task,
        where: fragment("? && ARRAY[?]::varchar[]", t.dependencies, ^completed_task_identifier),
        where: t.status == :blocked,
        preload: [:column]
      )
      |> Repo.all()

    Enum.each(dependent_tasks, fn task ->
      update_task_blocking_status(task)
    end)

    :ok
  end

  defp get_incomplete_dependencies(dependency_identifiers) do
    completed_tasks =
      from(t in Task,
        where: t.identifier in ^dependency_identifiers,
        where: t.status == :completed,
        select: t.identifier
      )
      |> Repo.all()
      |> MapSet.new()

    dependency_identifiers
    |> Enum.reject(&MapSet.member?(completed_tasks, &1))
  end

  @doc """
  Gets the full dependency tree for a task.

  Returns a map with the task and all its recursive dependencies.

  ## Examples

      iex> get_dependency_tree(task)
      %{task: %Task{}, dependencies: [...]}

  """
  def get_dependency_tree(task) do
    dependencies = task.dependencies || []

    if Enum.empty?(dependencies) do
      %{task: task, dependencies: []}
    else
      dep_tasks =
        from(t in Task,
          where: t.identifier in ^dependencies,
          preload: [:column, :assigned_to]
        )
        |> Repo.all()

      dep_trees = Enum.map(dep_tasks, &get_dependency_tree/1)

      %{task: task, dependencies: dep_trees}
    end
  end

  @doc """
  Gets all tasks that depend on the given task.

  Returns tasks that have the given task's identifier in their dependencies array.

  ## Examples

      iex> get_dependent_tasks(task)
      [%Task{}, ...]

  """
  def get_dependent_tasks(task) do
    from(t in Task,
      where: fragment("? && ARRAY[?]::varchar[]", t.dependencies, ^task.identifier),
      preload: [:column, :assigned_to]
    )
    |> Repo.all()
  end
end
