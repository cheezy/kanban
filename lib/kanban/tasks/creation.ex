defmodule Kanban.Tasks.Creation do
  @moduledoc """
  Task and goal creation with automatic positioning, identifier generation,
  and dependency handling.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Identifiers
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @doc """
  Creates a task for a column with automatic position assignment.
  Respects WIP limit - returns error if column is at capacity.
  """
  def create_task(column, attrs \\ %{}) do
    task_type = get_task_type_from_attrs(attrs)
    should_check_wip = task_type in [:work, :defect]

    if !should_check_wip || Positioning.can_add_task?(column) do
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
  """
  def create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []) do
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
    next_position = Positioning.get_next_position(column)
    identifier = Identifiers.generate_identifier(column, :goal)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    type_key = if is_map_key(prepared_attrs, "position"), do: "type", else: :type

    prepared_attrs
    |> Map.put(identifier_key, identifier)
    |> Map.put(type_key, :goal)
  end

  defp insert_child_tasks(multi, column, child_tasks_attrs) do
    task_identifiers = Identifiers.pregenerate_task_identifiers(column, child_tasks_attrs)

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
    next_position = Positioning.get_next_position(column) + index + 1
    identifier = Enum.at(task_identifiers, index)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    prepared_attrs = convert_index_based_dependencies(prepared_attrs, task_identifiers)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    parent_id_key = if is_map_key(prepared_attrs, "position"), do: "parent_id", else: :parent_id

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
      case Dependencies.update_task_blocking_status(task) do
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
    Broadcaster.broadcast_task_change(goal, :task_created)
    Enum.each(child_tasks, fn task -> Broadcaster.broadcast_task_change(task, :task_created) end)
  end

  defp emit_goal_creation_telemetry(goal, child_tasks, column) do
    :telemetry.execute(
      [:kanban, :goal, :created_with_tasks],
      %{goal_count: 1, task_count: length(child_tasks)},
      %{goal_id: goal.id, column_id: column.id}
    )
  end

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
    next_position = Positioning.get_next_position(column)
    task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
    identifier = Identifiers.generate_identifier(column, task_type)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    Map.put(prepared_attrs, identifier_key, identifier)
  end

  defp insert_task_with_history(column, attrs) do
    changeset =
      %Task{column_id: column.id}
      |> Task.changeset(attrs)
      |> Dependencies.validate_circular_dependencies()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:task, changeset)
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
      Dependencies.update_task_blocking_status(task)
    end
  end

  defp emit_task_creation_telemetry({:ok, task} = result, column) do
    :telemetry.execute([:kanban, :task, :creation], %{count: 1}, %{
      task_id: task.id,
      column_id: column.id
    })

    Broadcaster.broadcast_task_change(task, :task_created)

    result
  end

  defp emit_task_creation_telemetry(error, _column), do: error

  defp get_task_type_from_attrs(attrs) do
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
    has_string_keys? = Map.keys(attrs) |> Enum.any?(&is_binary/1)

    if has_string_keys? do
      Map.put(attrs, "position", position)
    else
      Map.put(attrs, :position, position)
    end
  end
end
