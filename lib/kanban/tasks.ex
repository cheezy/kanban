defmodule Kanban.Tasks do
  @moduledoc """
  The Tasks context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Hooks
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @doc """
  Returns the list of tasks for a column, ordered by position.

  By default, excludes archived tasks. Pass `include_archived: true` to include them.

  ## Examples

      iex> list_tasks(column)
      [%Task{}, ...]

      iex> list_tasks(column, include_archived: true)
      [%Task{}, ...]

  """
  def list_tasks(column, opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    Task
    |> where([t], t.column_id == ^column.id)
    |> maybe_filter_archived(include_archived)
    |> order_by([t], t.position)
    |> preload(:assigned_to)
    |> Repo.all()
  end

  defp maybe_filter_archived(query, false) do
    where(query, [t], is_nil(t.archived_at))
  end

  defp maybe_filter_archived(query, true), do: query

  @doc """
  Returns archived tasks for a column, sorted by archived_at descending.

  ## Examples

      iex> list_archived_tasks(column)
      [%Task{}, ...]

  """
  def list_archived_tasks(column) do
    Task
    |> where([t], t.column_id == ^column.id)
    |> where([t], not is_nil(t.archived_at))
    |> order_by([t], desc: t.archived_at)
    |> preload(:assigned_to)
    |> Repo.all()
  end

  @doc """
  Returns all archived tasks for a board, sorted by archived_at descending.

  ## Examples

      iex> list_archived_tasks_for_board(board_id)
      [%Task{}, ...]

  """
  def list_archived_tasks_for_board(board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.archived_at))
    |> order_by([t], desc: t.archived_at)
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

    task =
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

    if task.type == :goal do
      task
      |> Repo.preload(children: from(t in Task, order_by: [asc: t.position], preload: [:column]))
    else
      task
    end
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
    # Goals don't count toward WIP limit, so only check limit for work and defect tasks
    task_type = get_task_type_from_attrs(attrs)

    should_check_wip = task_type in [:work, :defect]

    # Check WIP limit before creating (skip check for goals)
    if !should_check_wip || can_add_task?(column) do
      attrs = prepare_task_creation_attrs(column, attrs)

      column
      |> insert_task_with_history(attrs)
      |> emit_task_creation_telemetry(column)
    else
      {:error, :wip_limit_reached}
    end
  end

  @doc """
  Creates a goal with nested child tasks in a single atomic transaction.

  Accepts a column, goal attributes, and a list of child task attributes.
  Creates the goal first, then creates all child tasks with parent_id set.
  All tasks are created atomically using Ecto.Multi.

  ## Examples

      iex> create_goal_with_tasks(column, %{title: "My Goal"}, [
        %{title: "Task 1", type: "work"},
        %{title: "Task 2", type: "defect"}
      ])
      {:ok, %{goal: %Task{}, child_tasks: [%Task{}, %Task{}]}}

      iex> create_goal_with_tasks(column, %{title: nil}, [])
      {:error, :goal, %Ecto.Changeset{}, %{}}

  """
  def create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []) do
    # Goals don't count toward WIP limit, so skip the check
    goal_attrs = prepare_goal_attrs(column, goal_attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:goal, Task.changeset(%Task{column_id: column.id}, goal_attrs))
    |> Ecto.Multi.insert(:goal_history, fn %{goal: goal} ->
      TaskHistory.changeset(%TaskHistory{}, %{
        task_id: goal.id,
        type: :creation
      })
    end)
    |> insert_child_tasks(column, child_tasks_attrs)
    |> Repo.transaction()
    |> handle_goal_creation_result(column)
  end

  defp prepare_goal_attrs(column, attrs) do
    next_position = get_next_position(column)
    identifier = generate_identifier(column, :goal)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    type_key = if is_map_key(prepared_attrs, "position"), do: "type", else: :type

    prepared_attrs
    |> Map.put(identifier_key, identifier)
    |> Map.put(type_key, :goal)
  end

  defp insert_child_tasks(multi, column, child_tasks_attrs) do
    # First pass: pre-generate identifiers for all child tasks
    task_identifiers = pregenerate_task_identifiers(column, child_tasks_attrs)

    child_tasks_attrs
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {child_attrs, index}, multi_acc ->
      task_key = {:child_task, index}
      history_key = {:child_task_history, index}

      multi_acc
      |> Ecto.Multi.insert(task_key, fn %{goal: goal} ->
        child_attrs_with_parent =
          prepare_child_task_attrs(column, child_attrs, goal, index, task_identifiers)

        Task.changeset(%Task{column_id: column.id}, child_attrs_with_parent)
      end)
      |> Ecto.Multi.insert(history_key, fn changes ->
        child_task = Map.get(changes, task_key)

        TaskHistory.changeset(%TaskHistory{}, %{
          task_id: child_task.id,
          type: :creation
        })
      end)
    end)
  end

  defp prepare_child_task_attrs(column, attrs, goal, index, task_identifiers) do
    next_position = get_next_position(column) + index + 1
    identifier = Enum.at(task_identifiers, index)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    # Convert index-based dependencies to actual identifiers
    prepared_attrs = convert_index_based_dependencies(prepared_attrs, task_identifiers)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    parent_id_key = if is_map_key(prepared_attrs, "position"), do: "parent_id", else: :parent_id

    # Inherit creator information from parent goal if not already set in child attrs
    prepared_attrs = inherit_creator_info(prepared_attrs, goal)

    prepared_attrs
    |> Map.put(identifier_key, identifier)
    |> Map.put(parent_id_key, goal.id)
  end

  defp inherit_creator_info(attrs, goal) do
    has_string_keys? = Map.keys(attrs) |> Enum.any?(&is_binary/1)

    created_by_id_key = if has_string_keys?, do: "created_by_id", else: :created_by_id
    created_by_agent_key = if has_string_keys?, do: "created_by_agent", else: :created_by_agent

    attrs
    |> Map.put_new(created_by_id_key, goal.created_by_id)
    |> maybe_put_created_by_agent(created_by_agent_key, goal.created_by_agent)
  end

  defp maybe_put_created_by_agent(attrs, _key, nil), do: attrs

  defp maybe_put_created_by_agent(attrs, key, agent_name) do
    Map.put_new(attrs, key, agent_name)
  end

  defp handle_goal_creation_result(transaction_result, column) do
    case transaction_result do
      {:ok, changes} ->
        goal = changes.goal
        child_tasks = extract_child_tasks(changes)

        # Update blocking status for all child tasks with dependencies
        updated_child_tasks = update_child_tasks_blocking_status(child_tasks)

        broadcast_goal_and_children(goal, updated_child_tasks)
        emit_goal_creation_telemetry(goal, updated_child_tasks, column)

        {:ok, %{goal: goal, child_tasks: updated_child_tasks}}

      {:error, failed_operation, changeset, _changes} ->
        {:error, failed_operation, changeset}
    end
  end

  defp update_child_tasks_blocking_status(child_tasks) do
    Enum.map(child_tasks, fn task ->
      case update_task_blocking_status(task) do
        {:ok, updated_task} -> updated_task
        {:error, _} -> task
      end
    end)
  end

  defp extract_child_tasks(changes) do
    changes
    |> Enum.filter(fn
      {{:child_task, _index}, _value} -> true
      _ -> false
    end)
    |> Enum.map(fn {_key, task} -> task end)
  end

  defp broadcast_goal_and_children(goal, child_tasks) do
    broadcast_task_change(goal, :task_created)
    Enum.each(child_tasks, fn task -> broadcast_task_change(task, :task_created) end)
  end

  defp emit_goal_creation_telemetry(goal, child_tasks, column) do
    :telemetry.execute(
      [:kanban, :goal, :created_with_tasks],
      %{goal_count: 1, task_count: length(child_tasks)},
      %{goal_id: goal.id, column_id: column.id}
    )
  end

  # Pre-generate all task identifiers so we can resolve index-based dependencies
  # We track counters in memory since database hasn't been updated yet
  defp pregenerate_task_identifiers(_column, child_tasks_attrs) do
    # Get initial max values from database for each type
    initial_counters = %{
      work: get_max_identifier_number(:work, "W"),
      defect: get_max_identifier_number(:defect, "D"),
      goal: get_max_identifier_number(:goal, "G")
    }

    {identifiers, _final_counters} =
      Enum.map_reduce(child_tasks_attrs, initial_counters, fn attrs, counters ->
        task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
        task_type = normalize_task_type(task_type)
        prefix = get_task_type_prefix(task_type)

        # Get and increment the counter for this type
        current_count = Map.get(counters, task_type)
        new_count = current_count + 1
        identifier = "#{prefix}#{new_count}"

        # Update counters for next iteration
        updated_counters = Map.put(counters, task_type, new_count)

        {identifier, updated_counters}
      end)

    identifiers
  end

  # Convert integer-based dependencies (indices) to actual task identifiers
  defp convert_index_based_dependencies(attrs, task_identifiers) do
    deps = Map.get(attrs, "dependencies", Map.get(attrs, :dependencies))

    if should_convert_dependencies?(deps) do
      converted_deps = convert_dependency_list(deps, task_identifiers)
      deps_key = if is_map_key(attrs, "dependencies"), do: "dependencies", else: :dependencies
      Map.put(attrs, deps_key, converted_deps)
    else
      attrs
    end
  end

  defp should_convert_dependencies?(deps) when is_list(deps) and deps != [], do: true
  defp should_convert_dependencies?(_), do: false

  defp convert_dependency_list(deps, task_identifiers) do
    Enum.map(deps, fn dep -> convert_single_dependency(dep, task_identifiers) end)
  end

  defp convert_single_dependency(idx, task_identifiers) when is_integer(idx) do
    Enum.at(task_identifiers, idx) || idx
  end

  defp convert_single_dependency(dep, _task_identifiers), do: dep

  defp prepare_task_creation_attrs(column, attrs) do
    next_position = get_next_position(column)
    task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
    identifier = generate_identifier(column, task_type)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    # Use string or atom key based on what position key was used
    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

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
    status_changed? = Map.has_key?(changeset.changes, :status)

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

        # If task was completed, unblock any dependent tasks
        if status_changed? && updated_task.status == :completed do
          unblock_dependent_tasks(updated_task.identifier)
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
      parent_id = task.parent_id
      result = Repo.delete(task)

      case result do
        {:ok, deleted_task} ->
          reorder_after_deletion(deleted_task)
          broadcast_task_change(deleted_task, :task_deleted)

          # If this task had a parent goal, check if the goal has any remaining children
          # If not, delete the goal as well
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

  ## Examples

      iex> archive_task(task)
      {:ok, %Task{}}

      iex> archive_task(task)
      {:error, %Ecto.Changeset{}}

  """
  def archive_task(%Task{} = task) do
    changeset = Task.changeset(task, %{archived_at: DateTime.utc_now()})

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

  ## Examples

      iex> unarchive_task(task)
      {:ok, %Task{}}

      iex> unarchive_task(task)
      {:error, %Ecto.Changeset{}}

  """
  def unarchive_task(%Task{} = task) do
    changeset = Task.changeset(task, %{archived_at: nil})

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
        # Delete the goal since it has no children
        Repo.delete(goal)
        reorder_after_deletion(goal)
        broadcast_task_change(goal, :task_deleted)
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

    # If moving to a different column, check WIP limit (only for work and defect tasks)
    result =
      if new_column.id != old_column_id do
        # Goals don't count toward WIP limit, so skip check for them
        should_check_wip = task.type in [:work, :defect]

        if should_check_wip do
          # Count current work and defect tasks in target column (goals don't count toward WIP limit)
          current_count =
            Task
            |> where([t], t.column_id == ^new_column.id)
            |> where([t], t.type in [:work, :defect])
            |> Repo.aggregate(:count)

          # Check if we can add to the target column
          if new_column.wip_limit > 0 and current_count >= new_column.wip_limit do
            {:error, :wip_limit_reached}
          else
            perform_move(task, new_column, new_position, old_column_id)
          end
        else
          # Skip WIP check for goals
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
      # Only count work and defect tasks, not goals
      current_count =
        Task
        |> where([t], t.column_id == ^column.id)
        |> where([t], t.type in [:work, :defect])
        |> Repo.aggregate(:count)

      current_count < column.wip_limit
    end
  end

  # Private functions

  defp get_task_type_from_attrs(attrs) do
    # Check for type in both string and atom keys
    # Default to :work if not specified
    cond do
      Map.has_key?(attrs, :type) ->
        normalize_type(attrs[:type])

      Map.has_key?(attrs, "type") ->
        normalize_type(attrs["type"])

      true ->
        :work
    end
  end

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: String.to_existing_atom(type)
  defp normalize_type(_), do: :work

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

        # Update parent goal position if this task has a parent
        update_parent_goal_position(updated_task, old_column_id, new_column.id)
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
    task_type = normalize_task_type(task_type)
    prefix = get_task_type_prefix(task_type)
    max_number = get_max_identifier_number(task_type, prefix)

    "#{prefix}#{max_number + 1}"
  end

  defp normalize_task_type(task_type) when is_atom(task_type), do: task_type
  defp normalize_task_type("work"), do: :work
  defp normalize_task_type("defect"), do: :defect
  defp normalize_task_type("goal"), do: :goal
  defp normalize_task_type(_invalid), do: :work

  defp get_task_type_prefix(:work), do: "W"
  defp get_task_type_prefix(:defect), do: "D"
  defp get_task_type_prefix(:goal), do: "G"

  defp get_max_identifier_number(_task_type, prefix) do
    # Query by prefix pattern instead of type to handle cases where
    # a task's type was changed but identifier remained the same
    # (e.g., W28 that was changed from work to defect)
    Task
    |> where([t], like(t.identifier, ^"#{prefix}%"))
    |> select([t], t.identifier)
    |> Repo.all()
    |> Enum.map(&extract_identifier_number(&1, prefix))
    |> get_max_number()
  end

  defp extract_identifier_number(identifier, prefix) do
    identifier
    |> String.replace(prefix, "")
    |> String.replace(~r/[^0-9].*$/, "")
    |> parse_number()
  end

  defp parse_number(""), do: 0
  defp parse_number(num_str), do: String.to_integer(num_str)

  defp get_max_number([]), do: 0
  defp get_max_number(numbers), do: Enum.max(numbers)

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
        where: t.type in [:work, :defect],
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        order_by: [desc: t.priority, asc: t.position],
        preload: [:column, :assigned_to, :created_by]
      )

    # Apply capability filter (always check that agent has required capabilities)
    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.required_capabilities) == 0 or
            fragment("?::varchar[] @> ?", ^agent_capabilities, t.required_capabilities)
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

  Executes the before_doing hook before moving the task.

  Returns {:ok, task} if successful, {:error, reason} if unsuccessful.

  ## Examples

      iex> claim_next_task(["code_generation"], user, board_id)
      {:ok, %Task{}}

      iex> claim_next_task(["code_generation"], user, board_id, "W15")
      {:ok, %Task{}}

      iex> claim_next_task([], user, board_id)
      {:error, :no_tasks_available}

  """
  def claim_next_task(
        agent_capabilities \\ [],
        user,
        board_id,
        task_identifier \\ nil,
        agent_name \\ "Unknown"
      ) do
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
        perform_claim(task, user, board_id, agent_name)
    end
  end

  defp get_specific_task_for_claim(identifier, agent_capabilities, board_id) do
    now = DateTime.utc_now()

    completed_task_identifiers =
      from(t in Task,
        where: t.status == :completed,
        select: t.identifier
      )

    query =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: t.identifier == ^identifier,
        where: c.board_id == ^board_id,
        where: c.name == "Ready",
        where: t.type in [:work, :defect],
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        preload: [:column, :assigned_to, :created_by]
      )

    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.required_capabilities) == 0 or
            fragment("?::varchar[] @> ?", ^agent_capabilities, t.required_capabilities)
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
              subquery(completed_task_identifiers)
            )
      )

    Repo.one(query)
  end

  defp perform_claim(task, user, board_id, agent_name) do
    board = Repo.get!(Kanban.Boards.Board, board_id)

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

        update_parent_goal_position(updated_task, task.column_id, doing_column.id)

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_updated, updated_task}
        )

        {:ok, hook_info} = Hooks.get_hook_info(updated_task, board, "before_doing", agent_name)
        {:ok, updated_task, hook_info}

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
  # credo:disable-for-lines:128
  def complete_task(task, user, params, agent_name \\ "Unknown") do
    task = Repo.preload(task, [:column, :assigned_to])
    board_id = task.column.board_id
    board = Repo.get!(Kanban.Boards.Board, board_id)

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
            :time_spent_minutes,
            :completed_by_agent
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
            old_column_id = task.column_id

            update_parent_goal_position(updated_task, old_column_id, review_column.id)

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

            {:ok, after_doing_hook} =
              Hooks.get_hook_info(updated_task, board, "after_doing", agent_name)

            {:ok, before_review_hook} =
              Hooks.get_hook_info(updated_task, board, "before_review", agent_name)

            if updated_task.needs_review do
              hooks = [after_doing_hook, before_review_hook]
              {:ok, updated_task, hooks}
            else
              done_column =
                from(c in Column,
                  where: c.board_id == ^board_id and c.name == "Done"
                )
                |> Repo.one()

              next_position = get_next_position(done_column)
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              done_changeset =
                updated_task
                |> Ecto.Changeset.change(%{
                  status: :completed,
                  completed_at: now,
                  column_id: done_column.id,
                  position: next_position
                })

              case Repo.update(done_changeset) do
                {:ok, _final_task} ->
                  final_task = get_task_for_view!(updated_task.id)

                  update_parent_goal_position(final_task, review_column.id, done_column.id)

                  Logger.info("Task #{task.id} auto-moved to Done (needs_review=false)")

                  :telemetry.execute(
                    [:kanban, :task, :completed],
                    %{task_id: final_task.id},
                    %{completed_by: user.id}
                  )

                  Phoenix.PubSub.broadcast(
                    Kanban.PubSub,
                    "board:#{board_id}",
                    {:task_completed, final_task}
                  )

                  unblock_dependent_tasks(final_task.identifier)

                  {:ok, after_review_hook} =
                    Hooks.get_hook_info(final_task, board, "after_review", agent_name)

                  hooks = [after_doing_hook, before_review_hook, after_review_hook]

                  {:ok, final_task, hooks}

                {:error, changeset} ->
                  {:error, changeset}
              end
            end

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Processes a reviewed task based on its review status.

  If review_status is "approved", moves the task from Review to Done column,
  sets status to :completed, and sets completed_at timestamp.

  If review_status is "changes_requested" or "rejected", moves the task from
  Review back to Doing column and keeps status as :in_progress.

  Only tasks in the Review column can be marked as reviewed.

  ## Parameters

    * task - The task to mark as reviewed
    * user - The user marking the task as reviewed

  ## Examples

      iex> mark_reviewed(task, user)
      {:ok, %Task{}}

  """
  def mark_reviewed(task, user) do
    task = Repo.preload(task, [:column, :assigned_to, :created_by])
    board_id = task.column.board_id

    cond do
      task.column.name != "Review" ->
        {:error, :invalid_column}

      is_nil(task.review_status) ->
        {:error, :review_not_performed}

      task.review_status == :approved ->
        move_to_done(task, user, board_id)

      task.review_status in [:changes_requested, :rejected] ->
        move_to_doing(task, user, board_id)

      true ->
        {:error, :invalid_review_status}
    end
  end

  defp move_to_done(task, user, board_id) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    agent_name = task.completed_by_agent || "Unknown"

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
        reviewed_by_id: user.id,
        column_id: done_column.id,
        position: next_position
      })

    case Repo.update(changeset) do
      {:ok, _updated_task} ->
        updated_task = get_task_for_view!(task.id)
        old_column_id = task.column_id

        update_parent_goal_position(updated_task, old_column_id, done_column.id)

        require Logger
        Logger.info("Task #{task.id} approved and moved to Done by user #{user.id}")

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

        {:ok, after_review_hook} =
          Hooks.get_hook_info(updated_task, board, "after_review", agent_name)

        {:ok, updated_task, after_review_hook}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp move_to_doing(task, user, board_id) do
    doing_column =
      from(c in Column,
        where: c.board_id == ^board_id and c.name == "Doing"
      )
      |> Repo.one()

    next_position = get_next_position(doing_column)

    changeset =
      task
      |> Ecto.Changeset.change(%{
        status: :in_progress,
        reviewed_by_id: user.id,
        column_id: doing_column.id,
        position: next_position
      })

    case Repo.update(changeset) do
      {:ok, _updated_task} ->
        updated_task = get_task_for_view!(task.id)
        old_column_id = task.column_id

        update_parent_goal_position(updated_task, old_column_id, doing_column.id)

        require Logger

        Logger.info(
          "Task #{task.id} needs changes (review status: #{task.review_status}) and moved back to Doing by user #{user.id}"
        )

        :telemetry.execute(
          [:kanban, :task, :returned_to_doing],
          %{task_id: updated_task.id},
          %{reviewed_by: user.id, review_status: task.review_status}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_returned_to_doing, updated_task}
        )

        {:ok, updated_task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Marks a task as done by moving it from Review to Done column.

  DEPRECATED: Use mark_reviewed/2 instead.

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

  @doc """
  Gets a task with hierarchical tree structure.

  For now, returns just the task itself (1 level) since goal hierarchy is not yet implemented.
  When goals are added, this will return goal → tasks (2 levels).

  Returns a map with:
  - task: The full task data
  - children: Array of child tasks (empty for now, will contain tasks when goals exist)
  - counts: Statistics about the task tree

  ## Examples

      iex> get_task_tree(123)
      %{
        task: %Task{},
        children: [],
        counts: %{total: 1, completed: 0, blocked: 0}
      }

  """
  def get_task_tree(task_id) when is_integer(task_id) do
    task = get_task_for_view!(task_id)

    # If this is a goal, query its child tasks
    children =
      if task.type == :goal do
        from(t in Task,
          where: t.parent_id == ^task_id,
          order_by: [asc: t.position],
          preload: [:column, :assigned_to, :created_by, :completed_by, :reviewed_by]
        )
        |> Repo.all()
      else
        []
      end

    # Calculate counts including children
    total_count = 1 + length(children)

    completed_count =
      if(task.status == :completed, do: 1, else: 0) +
        Enum.count(children, &(&1.status == :completed))

    blocked_count =
      if(task.status == :blocked, do: 1, else: 0) +
        Enum.count(children, &(&1.status == :blocked))

    %{
      task: task,
      children: children,
      counts: %{
        total: total_count,
        completed: completed_count,
        blocked: blocked_count
      }
    }
  end

  @doc """
  Gets all child tasks for a given parent task (goal).

  ## Examples

      iex> get_task_children(123)
      [%Task{}, ...]

  """
  def get_task_children(parent_task_id) do
    from(t in Task,
      where: t.parent_id == ^parent_task_id,
      order_by: [asc: t.position]
    )
    |> Repo.all()
  end

  defp update_parent_goal_position(moving_task, _task_old_column_id, _task_new_column_id) do
    with {:ok, parent_goal} <- get_parent_goal(moving_task),
         {:ok, goal_context} <- build_goal_context(parent_goal),
         {:ok, target_column} <- determine_target_column(goal_context),
         {:ok, _} <- move_goal_if_needed(parent_goal, target_column, goal_context, moving_task.id) do
      :ok
    else
      _ -> :ok
    end
  end

  defp get_parent_goal(%{parent_id: nil}), do: :error

  defp get_parent_goal(%{parent_id: parent_id}) do
    parent_goal = get_task!(parent_id)
    if parent_goal.type == :goal, do: {:ok, parent_goal}, else: :error
  end

  defp build_goal_context(parent_goal) do
    parent_column = Columns.get_column!(parent_goal.column_id)

    all_columns =
      from(c in Kanban.Columns.Column,
        where: c.board_id == ^parent_column.board_id,
        order_by: [asc: c.position]
      )
      |> Repo.all()

    column_map = Map.new(all_columns, fn col -> {col.id, col} end)

    children_data =
      from(t in Task,
        where: t.parent_id == ^parent_goal.id,
        select: {t.id, t.column_id}
      )
      |> Repo.all()

    if children_data == [] do
      :error
    else
      {:ok,
       %{
         all_columns: all_columns,
         column_map: column_map,
         children_data: children_data,
         child_ids: Enum.map(children_data, fn {id, _} -> id end)
       }}
    end
  end

  defp determine_target_column(goal_context) do
    done_column = find_done_column(goal_context.all_columns)

    all_in_done? =
      done_column != nil &&
        Enum.all?(goal_context.children_data, fn {_id, column_id} ->
          column_id == done_column.id
        end)

    target_column =
      if all_in_done? do
        done_column
      else
        valid_columns =
          goal_context.children_data
          |> Enum.map(fn {_id, column_id} -> goal_context.column_map[column_id] end)
          |> Enum.reject(&is_nil/1)

        case valid_columns do
          [] -> List.first(goal_context.all_columns)
          columns -> Enum.min_by(columns, & &1.position)
        end
      end

    {:ok, target_column}
  end

  defp find_done_column(columns) do
    Enum.find(columns, fn col -> String.downcase(col.name) == "done" end)
  end

  defp move_goal_if_needed(parent_goal, target_column, _goal_context, moving_task_id) do
    # Goals should always be placed at the top of the column, after any existing goals
    if target_column.id != parent_goal.column_id do
      move_goal_to_top_with_other_goals(parent_goal, target_column, moving_task_id)
    else
      {:ok, :no_change}
    end
  end

  # Calculates the target position for a goal based on two constraints:
  # 1. Must be before children (if any exist in the column)
  # 2. Must be after other goals (to keep goals grouped at top)
  defp calculate_goal_target_position(min_child_position, last_goal_position) do
    cond do
      min_child_position != nil && last_goal_position != nil ->
        # Must be before children AND after other goals
        # Use the minimum to satisfy both constraints
        min(min_child_position, last_goal_position + 1)

      min_child_position != nil ->
        # Must be before the leftmost child, no other goals to consider
        min_child_position

      last_goal_position != nil ->
        # No children in this column, place after other goals
        last_goal_position + 1

      true ->
        # No other goals and no children, place at position 0
        0
    end
  end

  defp move_goal_to_top_with_other_goals(parent_goal, target_column, _moving_task_id) do
    require Logger

    # Find the minimum position of this goal's children in the target column
    # The goal must be positioned BEFORE all its children
    min_child_position =
      from(t in Task,
        where: t.column_id == ^target_column.id and t.parent_id == ^parent_goal.id,
        select: min(t.position)
      )
      |> Repo.one()

    # Find the position after the last goal in the target column (excluding this goal)
    last_goal_position =
      from(t in Task,
        where: t.column_id == ^target_column.id and t.type == :goal and t.id != ^parent_goal.id,
        select: max(t.position)
      )
      |> Repo.one()

    # Calculate target position based on constraints
    target_position = calculate_goal_target_position(min_child_position, last_goal_position)

    Logger.info(
      "Moving goal #{parent_goal.identifier} to column #{target_column.id} at position #{target_position} (min_child_position: #{inspect(min_child_position)}, last_goal_position: #{inspect(last_goal_position)})"
    )

    # First, move the goal to a temporary negative position to avoid conflicts
    Task
    |> where([t], t.id == ^parent_goal.id)
    |> Repo.update_all(set: [column_id: target_column.id, position: -999_999])

    # Get all tasks at or after the target position that need to be shifted down
    # This includes both goals and work/defect tasks, but excludes the moving goal
    tasks_to_shift =
      from(t in Task,
        where:
          t.column_id == ^target_column.id and
            t.position >= ^target_position and
            t.id != ^parent_goal.id,
        select: %{id: t.id, position: t.position},
        order_by: [desc: t.position]
      )
      |> Repo.all()

    Logger.info("Shifting #{length(tasks_to_shift)} tasks from position #{target_position}")

    # Shift each task down by 1, from highest position to lowest to avoid conflicts
    Enum.each(tasks_to_shift, fn task ->
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: task.position + 1])
    end)

    # Place the goal at the target position
    Task
    |> where([t], t.id == ^parent_goal.id)
    |> Repo.update_all(set: [position: target_position])

    Logger.info("Goal #{parent_goal.identifier} placed at position #{target_position}")

    updated_goal = get_task!(parent_goal.id)
    broadcast_task_change(updated_goal, :task_moved)
    {:ok, :moved}
  end
end
