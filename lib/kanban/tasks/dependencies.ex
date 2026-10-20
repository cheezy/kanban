defmodule Kanban.Tasks.Dependencies do
  @moduledoc """
  Dependency management for tasks.

  Handles blocking status updates, circular dependency validation, the check
  that every dependency names a task on the task's own board, dependency tree
  traversal, and dependent task queries.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.Task

  @doc """
  Updates a task's blocked status based on its dependencies.

  Sets status to :blocked if any dependencies are incomplete,
  or to :open if all dependencies are complete.
  """
  def update_task_blocking_status(task) do
    task = Repo.preload(task, [:column])
    board_id = task.column.board_id

    dependencies = task.dependencies || []

    if Enum.empty?(dependencies) do
      {:ok, task}
    else
      incomplete_deps = get_incomplete_dependencies(dependencies, board_id)

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

  Called after a task is marked as done to unblock dependent tasks. Emits
  `[:kanban, :task, :unblocked]` for each dependent that is no longer blocked;
  a dependent still waiting on another task emits nothing.
  """
  def unblock_dependent_tasks(completed_task_identifier, board_id) do
    dependent_tasks =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: fragment("? && ARRAY[?]::varchar[]", t.dependencies, ^completed_task_identifier),
        where: t.status == :blocked,
        preload: [:column]
      )
      |> Repo.all()

    Enum.each(dependent_tasks, fn task ->
      task
      |> update_task_blocking_status()
      |> GoalTelemetry.unblocked(board_id)
    end)

    :ok
  end

  @doc """
  Validates that every identifier in a changed `dependencies` list names a
  task on the board of the changeset's `column_id`.

  Dependencies resolve only on the task's own board, so an identifier with no
  task there would leave the task blocked until some unrelated task later
  receives that identifier and completes. Such a change gets an error on
  `:dependencies` naming the missing identifiers, the same way an unknown
  label is refused.

  `known` lists identifiers that count as present although their rows are not
  inserted yet: the sibling identifiers of a goal's children, generated before
  any child is. The task's own identifier is skipped, since
  `Kanban.Tasks.Task.FieldValidations` already refuses a self-dependency. The
  check runs only when `dependencies` is among the changes, so a task that
  already holds a dangling dependency can still be edited otherwise, and it
  never adds a second error to a list that failed its format check.
  """
  def validate_dependencies_exist(changeset, known \\ []) do
    deps = Ecto.Changeset.get_change(changeset, :dependencies)

    if is_list(deps) and deps != [] and changeset.errors[:dependencies] == nil do
      own = Ecto.Changeset.get_field(changeset, :identifier)
      column_id = Ecto.Changeset.get_field(changeset, :column_id)
      wanted = deps |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Kernel.--([own | known])

      changeset |> add_missing_dependencies_error(missing_on_board(wanted, column_id))
    else
      changeset
    end
  end

  defp add_missing_dependencies_error(changeset, []), do: changeset

  defp add_missing_dependencies_error(changeset, missing) do
    Ecto.Changeset.add_error(
      changeset,
      :dependencies,
      "lists tasks that are not on this board: %{identifiers}",
      identifiers: Enum.join(missing, ", ")
    )
  end

  defp missing_on_board([], _column_id), do: []

  defp missing_on_board(identifiers, column_id) do
    found =
      from(t in Task,
        join: c in assoc(t, :column),
        join: own in Column,
        on: own.board_id == c.board_id,
        where: own.id == ^column_id and t.identifier in ^identifiers,
        select: t.identifier
      )
      |> Repo.all()

    identifiers -- found
  end

  @doc """
  Validates that new dependencies don't create a circular dependency.

  Adds an error to the changeset if a cycle is detected.
  """
  def validate_circular_dependencies(changeset) do
    import Ecto.Changeset, only: [add_error: 3]

    deps = Ecto.Changeset.get_field(changeset, :dependencies) || []
    task_id = Ecto.Changeset.get_field(changeset, :id)
    deps_changed? = Map.has_key?(changeset.changes, :dependencies)

    if deps_changed? && task_id && deps != [] do
      if has_circular_dependency?(task_id, deps) do
        add_error(changeset, :dependencies, "creates a circular dependency")
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc """
  Gets the full dependency tree for a task.

  Returns a map with the task and all its recursive dependencies.
  """
  def get_dependency_tree(task) do
    task = Repo.preload(task, :column)
    board_id = task.column.board_id
    do_get_dependency_tree(task, board_id, MapSet.new())
  end

  @doc """
  Gets all tasks that depend on the given task.

  Returns tasks that have the given task's identifier in their dependencies array.
  """
  def get_dependent_tasks(task) do
    task = Repo.preload(task, :column)
    board_id = task.column.board_id

    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board_id,
      where: is_nil(t.archived_at),
      where: fragment("? && ARRAY[?]::varchar[]", t.dependencies, ^task.identifier),
      preload: [:column, :assigned_to]
    )
    |> Repo.all()
  end

  defp get_incomplete_dependencies(dependency_identifiers, board_id) do
    completed_tasks =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.identifier in ^dependency_identifiers,
        where: t.status == :completed,
        select: t.identifier
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(dependency_identifiers, &MapSet.member?(completed_tasks, &1))
  end

  defp has_circular_dependency?(task_id, dependency_identifiers) do
    result =
      from(t in Task,
        join: c in assoc(t, :column),
        where: t.id == ^task_id,
        select: {t.identifier, c.board_id}
      )
      |> Repo.one()

    case result do
      nil ->
        false

      {identifier, board_id} ->
        check_circular_dependency(identifier, dependency_identifiers, board_id, MapSet.new())
    end
  end

  defp check_circular_dependency(_current_identifier, [], _board_id, _visited), do: false

  defp check_circular_dependency(current_identifier, dependency_identifiers, board_id, visited) do
    tasks =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.identifier in ^dependency_identifiers,
        select: {t.identifier, t.dependencies}
      )
      |> Repo.all()

    Enum.any?(tasks, fn {identifier, deps} ->
      deps = deps || []

      cond do
        current_identifier in deps ->
          true

        identifier in visited ->
          false

        true ->
          visited = MapSet.put(visited, identifier)
          check_circular_dependency(current_identifier, deps, board_id, visited)
      end
    end)
  end

  defp do_get_dependency_tree(task, board_id, visited) do
    dependencies = task.dependencies || []

    if Enum.empty?(dependencies) do
      %{task: task, dependencies: []}
    else
      visited = MapSet.put(visited, task.identifier)

      dep_tasks =
        from(t in Task,
          join: c in assoc(t, :column),
          where: c.board_id == ^board_id,
          where: t.identifier in ^dependencies,
          where: t.identifier not in ^MapSet.to_list(visited),
          preload: [:column, :assigned_to]
        )
        |> Repo.all()

      dep_trees = Enum.map(dep_tasks, &do_get_dependency_tree(&1, board_id, visited))

      %{task: task, dependencies: dep_trees}
    end
  end
end
