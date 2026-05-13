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

  When `attrs` includes a non-nil `parent_id` (atom or string key) referencing
  an existing **goal** that has a non-nil `assigned_to_id`, AND `attrs` does NOT
  carry an explicit `assigned_to_id` key, the new task inherits the goal's
  `assigned_to_id` at creation time. Explicit `assigned_to_id` values in
  `attrs` (including explicit `nil`) are always preserved — the inheritance
  only fills the gap when the caller did not specify an assignee.
  """
  def create_task(column, attrs \\ %{}) do
    do_create_task(column, attrs, &Task.changeset/2)
  end

  @doc """
  API-safe create path for POST /api/tasks.

  Uses `Task.api_create_changeset/2`, which casts only the strict allow-list.
  The controller layer is responsible for stripping forbidden client-supplied
  fields (status, claimed_at, completed_*, reviewed_*, identifier, etc.) before
  reaching this function — defense-in-depth lives in both layers.
  """
  def api_create_task(column, attrs \\ %{}) do
    do_create_task(column, attrs, &Task.api_create_changeset/2)
  end

  defp do_create_task(column, attrs, changeset_fn) do
    attrs = maybe_inherit_assignment_from_parent(attrs)
    task_type = get_task_type_from_attrs(attrs)
    should_check_wip = task_type in [:work, :defect]

    if !should_check_wip || Positioning.can_add_task?(column) do
      column
      |> insert_task_with_history(attrs, changeset_fn)
      |> emit_task_creation_telemetry(column)
    else
      {:error, :wip_limit_reached}
    end
  end

  @doc """
  Creates a goal with nested child tasks in a single atomic transaction.
  """
  def create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []) do
    do_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs, &Task.changeset/2)
  end

  @doc """
  API-safe goal+children create path for POST /api/tasks/batch.

  Uses `Task.api_create_changeset/2` for both the goal and every child task.
  Controller is responsible for stripping forbidden client-supplied fields
  before this function is called.
  """
  def api_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []) do
    do_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs, &Task.api_create_changeset/2)
  end

  defp do_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs, changeset_fn) do
    column
    |> build_goal_creation_multi(goal_attrs, child_tasks_attrs, changeset_fn)
    |> Repo.transaction()
    |> handle_goal_creation_result(column)
  end

  defp build_goal_creation_multi(column, goal_attrs, child_tasks_attrs, changeset_fn) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:lock_and_prepare, goal_lock_and_prepare_fun(column, child_tasks_attrs))
    |> Ecto.Multi.insert(:goal, fn %{lock_and_prepare: prep} ->
      attrs = prepare_goal_attrs(goal_attrs, prep.goal_id, prep.position)
      changeset_fn.(%Task{column_id: column.id}, attrs)
    end)
    |> Ecto.Multi.insert(:goal_history, fn %{goal: goal} ->
      TaskHistory.changeset(%TaskHistory{}, %{task_id: goal.id, type: :creation})
    end)
    |> insert_child_tasks(column, child_tasks_attrs, changeset_fn)
  end

  defp goal_lock_and_prepare_fun(column, child_tasks_attrs) do
    fn _repo, _changes ->
      next_position = Positioning.get_next_position_locked(column)
      goal_identifier = Identifiers.generate_identifier(column.board_id, :goal)

      child_identifiers =
        Identifiers.pregenerate_task_identifiers(column.board_id, child_tasks_attrs)

      {:ok, %{position: next_position, goal_id: goal_identifier, child_ids: child_identifiers}}
    end
  end

  defp prepare_goal_attrs(attrs, identifier, position) do
    prepared_attrs = prepare_task_attrs(attrs, position)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    type_key = if is_map_key(prepared_attrs, "position"), do: "type", else: :type

    prepared_attrs
    |> Map.put(identifier_key, identifier)
    |> Map.put(type_key, :goal)
  end

  defp insert_child_tasks(multi, column, child_tasks_attrs, changeset_fn) do
    child_tasks_attrs
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {child_attrs, index}, multi_acc ->
      add_child_task_steps(multi_acc, column, child_attrs, index, changeset_fn)
    end)
  end

  defp add_child_task_steps(multi_acc, column, child_attrs, index, changeset_fn) do
    task_key = {:child_task, index}
    history_key = {:child_task_history, index}

    multi_acc
    |> Ecto.Multi.insert(task_key, fn %{goal: goal, lock_and_prepare: prep} ->
      child_attrs_with_parent =
        prepare_child_task_attrs(
          child_attrs,
          goal,
          index,
          prep.child_ids,
          prep.position
        )

      changeset_fn.(%Task{column_id: column.id}, child_attrs_with_parent)
    end)
    |> Ecto.Multi.insert(history_key, fn changes ->
      child_task = Map.get(changes, task_key)

      TaskHistory.changeset(%TaskHistory{}, %{
        task_id: child_task.id,
        type: :creation
      })
    end)
  end

  defp prepare_child_task_attrs(attrs, goal, index, task_identifiers, base_position) do
    next_position = base_position + index + 1
    identifier = Enum.at(task_identifiers, index)

    prepared_attrs = prepare_task_attrs(attrs, next_position)

    prepared_attrs = convert_index_based_dependencies(prepared_attrs, task_identifiers)

    identifier_key =
      if is_map_key(prepared_attrs, "position"), do: "identifier", else: :identifier

    parent_id_key = if is_map_key(prepared_attrs, "position"), do: "parent_id", else: :parent_id

    prepared_attrs = inherit_creator_info(prepared_attrs, goal)
    prepared_attrs = inherit_assignment_from_goal_struct(prepared_attrs, goal)

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

  # Looks up the parent task by `parent_id` in attrs (atom or string key) and,
  # when the parent is a goal with a non-nil assigned_to_id AND attrs does not
  # already carry an explicit assigned_to_id key, returns attrs with the
  # parent's assigned_to_id injected. Used by `create_task/2` so a new task
  # added under an existing assigned goal inherits that goal's assignee.
  defp maybe_inherit_assignment_from_parent(attrs) when is_map(attrs) do
    if assigned_to_id_explicit?(attrs) do
      attrs
    else
      case fetch_parent_id(attrs) do
        nil -> attrs
        parent_id -> apply_inheritance_from_parent_id(attrs, parent_id)
      end
    end
  end

  defp maybe_inherit_assignment_from_parent(attrs), do: attrs

  defp apply_inheritance_from_parent_id(attrs, parent_id) do
    case Repo.get(Task, parent_id) do
      %Task{type: :goal, assigned_to_id: assigned_id} when not is_nil(assigned_id) ->
        put_assigned_to_id(attrs, assigned_id)

      _ ->
        attrs
    end
  end

  # Variant used inside `create_goal_with_tasks/3` where the goal struct is
  # already in hand (just inserted by the Multi). Avoids a redundant DB lookup
  # and keeps the rule consistent with the create_task/2 path: child attrs
  # without an explicit assigned_to_id inherit the goal's assignment, when set.
  defp inherit_assignment_from_goal_struct(attrs, %Task{assigned_to_id: nil}), do: attrs

  defp inherit_assignment_from_goal_struct(attrs, %Task{assigned_to_id: assigned_id}) do
    if assigned_to_id_explicit?(attrs) do
      attrs
    else
      put_assigned_to_id(attrs, assigned_id)
    end
  end

  defp assigned_to_id_explicit?(attrs) do
    Map.has_key?(attrs, :assigned_to_id) or Map.has_key?(attrs, "assigned_to_id")
  end

  defp fetch_parent_id(attrs) do
    case Map.get(attrs, :parent_id, Map.get(attrs, "parent_id")) do
      nil -> nil
      parent_id -> parent_id
    end
  end

  defp put_assigned_to_id(attrs, assigned_id) do
    has_string_keys? = Map.keys(attrs) |> Enum.any?(&is_binary/1)
    key = if has_string_keys?, do: "assigned_to_id", else: :assigned_to_id
    Map.put(attrs, key, assigned_id)
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

  defp insert_task_with_history(column, attrs, changeset_fn) do
    column
    |> build_task_creation_multi(attrs, changeset_fn)
    |> Repo.transaction()
    |> handle_task_creation_result(attrs)
  end

  defp build_task_creation_multi(column, attrs, changeset_fn) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:lock_and_prepare, task_lock_and_prepare_fun(column, attrs))
    |> Ecto.Multi.insert(:task, task_insert_fun(column, attrs, changeset_fn))
    |> Ecto.Multi.insert(:history, fn %{task: task} ->
      TaskHistory.changeset(%TaskHistory{}, %{task_id: task.id, type: :creation})
    end)
  end

  defp task_lock_and_prepare_fun(column, attrs) do
    fn _repo, _changes ->
      next_position = Positioning.get_next_position_locked(column)
      task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
      identifier = Identifiers.generate_identifier(column.board_id, task_type)
      {:ok, %{position: next_position, identifier: identifier}}
    end
  end

  defp task_insert_fun(column, attrs, changeset_fn) do
    fn %{lock_and_prepare: prep} ->
      task_attrs =
        attrs
        |> prepare_task_attrs(prep.position)
        |> put_key("identifier", prep.identifier)

      %Task{column_id: column.id}
      |> changeset_fn.(task_attrs)
      |> Dependencies.validate_circular_dependencies()
    end
  end

  defp put_key(attrs, key, value) do
    actual_key =
      if Map.keys(attrs) |> Enum.any?(&is_binary/1), do: key, else: String.to_existing_atom(key)

    Map.put(attrs, actual_key, value)
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
