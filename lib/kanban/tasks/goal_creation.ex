defmodule Kanban.Tasks.GoalCreation do
  @moduledoc """
  Creates a goal and its child tasks in one transaction: the board lock and
  identifiers are taken once for the whole set, children inherit the goal's
  creator and assignee, and index-based `dependencies` between children are
  rewritten to the identifiers generated for them.

  Single-task creation lives in `Kanban.Tasks.Creation`; the helpers both
  share are in `Kanban.Tasks.CreationSupport`.
  """

  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.CreationSupport
  alias Kanban.Tasks.DbErrors
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Identifiers
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.HierarchyValidations
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Tasks.TaskType

  @doc """
  Creates a goal with nested child tasks in a single atomic transaction.

  Child tasks must be `work` or `defect` and carry no `tasks` of their own. A
  child of type `goal` returns `{:error, {:child_task, index}, changeset}` with
  an error on `:type`, a child with a non-empty `tasks` list the same shape with
  an error on `:tasks`, and nothing is written (D354).
  """
  def create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []) do
    do_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs, &Task.changeset/2)
  end

  @doc """
  API-safe goal+children create path for POST /api/tasks/batch.

  Uses `Task.api_create_changeset/2` for both the goal and every child task.
  Controller is responsible for stripping forbidden client-supplied fields
  before this function is called.

  `opts` takes `:before_broadcast`, called with the goal and its child tasks
  before any `:task_created` is broadcast (see `api_create_task/3`).
  """
  def api_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ [], opts \\ []) do
    do_create_goal_with_tasks(
      column,
      goal_attrs,
      child_tasks_attrs,
      &Task.api_create_changeset/2,
      opts
    )
  end

  defp do_create_goal_with_tasks(column, goal_attrs, child_tasks_attrs, changeset_fn, opts \\ []) do
    # The whole pipe runs inside the value-too-long rescue: a 22001 raised by any
    # Multi.insert rolls the transaction back atomically before the exception
    # reaches the rescue, so the synthetic 3-tuple matches the failure shape
    # handle_goal_creation_result/3 returns and the rollback is preserved.
    DbErrors.translate_value_too_long(
      fn ->
        column
        |> build_goal_creation_multi(goal_attrs, child_tasks_attrs, changeset_fn)
        |> Repo.transaction()
        |> handle_goal_creation_result(column, opts)
      end,
      fn changeset -> {:error, :db, changeset} end
    )
  end

  defp build_goal_creation_multi(column, goal_attrs, child_tasks_attrs, changeset_fn) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:child_hierarchy, child_hierarchy_fun(column, child_tasks_attrs))
    |> Ecto.Multi.run(:lock_and_prepare, goal_lock_and_prepare_fun(column, child_tasks_attrs))
    |> Ecto.Multi.insert(:goal, fn %{lock_and_prepare: prep} ->
      attrs = prepare_goal_attrs(goal_attrs, prep.goal_id, prep.position)
      column |> CreationSupport.new_task() |> changeset_fn.(attrs)
    end)
    |> Ecto.Multi.insert(:goal_history, fn %{goal: goal} ->
      TaskHistory.changeset(%TaskHistory{}, %{task_id: goal.id, type: :creation})
    end)
    |> insert_child_tasks(column, child_tasks_attrs, changeset_fn)
  end

  # A goal holds only work and defect tasks, one level deep (D354). A child of
  # type goal, or a child carrying its own tasks, is refused by the first step
  # of the transaction, before :lock_and_prepare takes the board lock or
  # generates a single identifier, so a rejected request rolls back with
  # nothing written and no identifier consumed.
  defp child_hierarchy_fun(column, child_tasks_attrs) do
    fn _repo, _changes ->
      case HierarchyValidations.child_task_error(child_tasks_attrs) do
        nil ->
          {:ok, :valid}

        {index, field, message} ->
          {:error, {index, child_hierarchy_changeset(column, field, message)}}
      end
    end
  end

  defp child_hierarchy_changeset(column, field, message) do
    column
    |> CreationSupport.new_task()
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
    |> Map.put(:action, :insert)
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
    prepared_attrs = CreationSupport.put_position(attrs, position)

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

      column |> CreationSupport.new_task() |> changeset_fn.(child_attrs_with_parent)
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

    prepared_attrs =
      attrs |> TaskType.blank_to_nil() |> CreationSupport.put_position(next_position)

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

  # The goal struct is already in hand (just inserted by the Multi), so no
  # lookup is needed. The rule matches Kanban.Tasks.Creation.create_task/2: child attrs
  # without an explicit assigned_to_id inherit the goal's assignment, when set.
  defp inherit_assignment_from_goal_struct(attrs, %Task{assigned_to_id: nil}), do: attrs

  defp inherit_assignment_from_goal_struct(attrs, %Task{assigned_to_id: assigned_id}) do
    if CreationSupport.assigned_to_id_explicit?(attrs) do
      attrs
    else
      CreationSupport.put_assigned_to_id(attrs, assigned_id)
    end
  end

  defp maybe_put_created_by_agent(attrs, _key, nil), do: attrs

  defp maybe_put_created_by_agent(attrs, key, agent_name) do
    Map.put_new(attrs, key, agent_name)
  end

  defp handle_goal_creation_result(transaction_result, column, opts) do
    case transaction_result do
      {:ok, changes} ->
        goal = changes.goal
        child_tasks = extract_child_tasks(changes)

        updated_child_tasks = update_child_tasks_blocking_status(child_tasks)

        CreationSupport.run_before_broadcast(opts, [goal, updated_child_tasks])
        broadcast_goal_and_children(goal, updated_child_tasks)
        emit_goal_creation_telemetry(goal, updated_child_tasks, column)

        {:ok, %{goal: goal, child_tasks: updated_child_tasks}}

      # Reported against the offending child, the same shape a failed child
      # insert returns, so both endpoints render it like any child error.
      {:error, :child_hierarchy, {index, changeset}, _changes} ->
        {:error, {:child_task, index}, changeset}

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
end
