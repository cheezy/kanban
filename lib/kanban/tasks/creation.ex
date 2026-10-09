defmodule Kanban.Tasks.Creation do
  @moduledoc """
  Single-task creation with automatic positioning, identifier generation,
  WIP-limit checks and dependency handling. A task created under an assigned
  goal inherits the goal's assignee.

  Goals created together with their child tasks go through
  `Kanban.Tasks.GoalCreation`; the helpers both share are in
  `Kanban.Tasks.CreationSupport`.
  """

  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.CreationSupport
  alias Kanban.Tasks.DbErrors
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Identifiers
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Tasks.TaskType

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

  `opts` takes `:before_broadcast`, a function called with the saved task
  before `:task_created` is broadcast. The API writes the task's labels there,
  so an open board never renders the new card without its label chips.
  """
  def api_create_task(column, attrs \\ %{}, opts \\ []) do
    do_create_task(column, attrs, &Task.api_create_changeset/2, opts)
  end

  defp do_create_task(column, attrs, changeset_fn, opts \\ []) do
    attrs =
      attrs
      |> TaskType.blank_to_nil()
      |> maybe_inherit_assignment_from_parent(column.board_id)

    task_type = TaskType.from_attrs(attrs)
    should_check_wip = task_type in [:work, :defect]

    if !should_check_wip || Positioning.can_add_task?(column) do
      column
      |> insert_task_with_history(attrs, changeset_fn)
      |> emit_task_creation_telemetry(column, opts)
    else
      {:error, :wip_limit_reached}
    end
  end

  # Looks up the parent task by `parent_id` in attrs (atom or string key) and,
  # when the parent is a goal with a non-nil assigned_to_id AND attrs does not
  # already carry an explicit assigned_to_id key, returns attrs with the
  # parent's assigned_to_id injected, so a new task added under an existing
  # assigned goal inherits that goal's assignee.
  defp maybe_inherit_assignment_from_parent(attrs, board_id) when is_map(attrs) do
    if CreationSupport.assigned_to_id_explicit?(attrs) do
      attrs
    else
      case fetch_parent_id(attrs) do
        nil -> attrs
        parent_id -> apply_inheritance_from_parent_id(attrs, parent_id, board_id)
      end
    end
  end

  defp maybe_inherit_assignment_from_parent(attrs, _board_id), do: attrs

  # The parent lookup is scoped to the creating task's own board. A parent_id
  # that names a task on another board (or does not exist) resolves to nil and
  # yields no inheritance — closing the cross-board assigned_to_id leak a
  # client-supplied parent_id would otherwise trigger (D153).
  defp apply_inheritance_from_parent_id(attrs, parent_id, board_id) do
    case Queries.get_task_for_board(parent_id, board_id) do
      %Task{type: :goal, assigned_to_id: assigned_id} when not is_nil(assigned_id) ->
        CreationSupport.put_assigned_to_id(attrs, assigned_id)

      _ ->
        attrs
    end
  end

  defp fetch_parent_id(attrs) do
    case Map.get(attrs, :parent_id, Map.get(attrs, "parent_id")) do
      nil -> nil
      parent_id -> parent_id
    end
  end

  defp insert_task_with_history(column, attrs, changeset_fn) do
    # As in Kanban.Tasks.GoalCreation: the whole pipe is wrapped so a 22001 on a
    # bounded column without a per-field validator becomes a clean {:error,
    # changeset} (the shape handle_task_creation_result/2 produces) instead of a
    # raised Postgrex.Error / HTTP 500.
    DbErrors.translate_value_too_long(
      fn ->
        column
        |> build_task_creation_multi(attrs, changeset_fn)
        |> Repo.transaction()
        |> handle_task_creation_result(attrs)
      end,
      &{:error, &1}
    )
  end

  defp build_task_creation_multi(column, attrs, changeset_fn) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:lock_and_prepare, task_lock_and_prepare_fun(column, attrs))
    |> Ecto.Multi.insert(:task, task_insert_fun(column, attrs, changeset_fn))
    |> Ecto.Multi.insert(:history, fn %{task: task} ->
      TaskHistory.changeset(%TaskHistory{}, %{task_id: task.id, type: :creation})
    end)
    |> Ecto.Multi.run(:goal_recalc, fn _repo, %{task: task} ->
      # Reposition the parent goal now that it has a new child. Reuses the same
      # recalc entry point as the move (positioning.ex) and status-transition
      # (agent_workflow.ex) paths so a Done goal that gains a non-Done child is
      # pulled back to its leftmost occupied child column. The function no-ops
      # safely for tasks without a goal parent (nil parent_id, or a non-goal
      # parent), so no parent_id guard is needed here. The 2nd/3rd column args
      # are unused by the recalc; passing the task's own column is self-documenting.
      Goals.update_parent_goal_position(task, task.column_id, task.column_id)
      {:ok, :ok}
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
        |> CreationSupport.put_position(prep.position)
        |> put_key("identifier", prep.identifier)

      CreationSupport.new_task(column)
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

  defp emit_task_creation_telemetry({:ok, task} = result, column, opts) do
    :telemetry.execute([:kanban, :task, :creation], %{count: 1}, %{
      task_id: task.id,
      column_id: column.id
    })

    CreationSupport.run_before_broadcast(opts, [task])
    Broadcaster.broadcast_task_change(task, :task_created)

    result
  end

  defp emit_task_creation_telemetry(error, _column, _opts), do: error
end
