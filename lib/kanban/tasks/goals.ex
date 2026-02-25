defmodule Kanban.Tasks.Goals do
  @moduledoc """
  Goal hierarchy, promotion, parent tracking, and tree queries.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task

  require Logger

  @doc """
  Gets a task with hierarchical tree structure.

  Returns a map with the task, children, and counts.
  """
  def get_task_tree(task_id) when is_integer(task_id) do
    task = Queries.get_task_for_view!(task_id)

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
  """
  def get_task_children(parent_task_id) do
    from(t in Task,
      where: t.parent_id == ^parent_task_id,
      order_by: [asc: t.position]
    )
    |> Repo.all()
  end

  @doc """
  Moves a goal and all of its children that are in the Backlog column to the Ready column.
  """
  def promote_goal_to_ready(%Task{type: :goal} = goal, board_id) do
    with {:ok, backlog_column} <- find_column_by_name(board_id, "Backlog"),
         {:ok, ready_column} <- find_column_by_name(board_id, "Ready") do
      tasks_to_move = collect_backlog_tasks(goal, backlog_column)
      execute_promotion(tasks_to_move, ready_column)
    end
  end

  def promote_goal_to_ready(%Task{}, _board_id), do: {:error, :not_a_goal}

  @doc """
  Updates the parent goal's column position based on where its children are.
  """
  def update_parent_goal_position(moving_task, _task_old_column_id, _task_new_column_id) do
    with {:ok, parent_goal} <- get_parent_goal(moving_task),
         {:ok, goal_context} <- build_goal_context(parent_goal),
         {:ok, target_column} <- determine_target_column(goal_context),
         {:ok, _} <- move_goal_if_needed(parent_goal, target_column, goal_context, moving_task.id) do
      :ok
    else
      _ -> :ok
    end
  end

  defp collect_backlog_tasks(goal, backlog_column) do
    children =
      from(t in Task,
        where: t.parent_id == ^goal.id and t.column_id == ^backlog_column.id,
        where: is_nil(t.archived_at),
        order_by: [asc: t.position]
      )
      |> Repo.all()

    if goal.column_id == backlog_column.id do
      [goal | children]
    else
      children
    end
  end

  defp execute_promotion(tasks_to_move, ready_column) do
    result =
      Repo.transaction(fn ->
        Enum.each(tasks_to_move, &move_task_to_column(&1, ready_column))
        length(tasks_to_move)
      end)

    case result do
      {:ok, count} ->
        Enum.each(tasks_to_move, fn task ->
          Broadcaster.broadcast_task_change(%{task | column_id: ready_column.id}, :task_moved)
        end)

        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp move_task_to_column(task, target_column) do
    next_pos = Positioning.get_next_position(target_column)
    status_updates = Positioning.determine_status_for_column(target_column.name, task)
    updates = Map.merge(%{column_id: target_column.id, position: next_pos}, status_updates)

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: Map.to_list(updates))

    old_column = Columns.get_column!(task.column_id)

    task.id
    |> Queries.get_task!()
    |> History.create_move_history(old_column.name, target_column.name)
  end

  defp find_column_by_name(board_id, name) do
    from(c in Column, where: c.board_id == ^board_id and c.name == ^name)
    |> Repo.one()
    |> case do
      nil -> {:error, :column_not_found}
      column -> {:ok, column}
    end
  end

  defp get_parent_goal(%{parent_id: nil}), do: :error

  defp get_parent_goal(%{parent_id: parent_id}) do
    parent_goal = Queries.get_task!(parent_id)
    if parent_goal.type == :goal, do: {:ok, parent_goal}, else: :error
  end

  defp build_goal_context(parent_goal) do
    parent_column = Columns.get_column!(parent_goal.column_id)

    all_columns =
      from(c in Column,
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
    if target_column.id != parent_goal.column_id do
      move_goal_to_top_with_other_goals(parent_goal, target_column, moving_task_id)
    else
      {:ok, :no_change}
    end
  end

  defp calculate_goal_target_position(min_child_position, last_goal_position) do
    cond do
      min_child_position != nil && last_goal_position != nil ->
        min(min_child_position, last_goal_position + 1)

      min_child_position != nil ->
        min_child_position

      last_goal_position != nil ->
        last_goal_position + 1

      true ->
        0
    end
  end

  defp move_goal_to_top_with_other_goals(parent_goal, target_column, _moving_task_id) do
    min_child_position =
      from(t in Task,
        where: t.column_id == ^target_column.id and t.parent_id == ^parent_goal.id,
        select: min(t.position)
      )
      |> Repo.one()

    last_goal_position =
      from(t in Task,
        where: t.column_id == ^target_column.id and t.type == :goal and t.id != ^parent_goal.id,
        select: max(t.position)
      )
      |> Repo.one()

    target_position = calculate_goal_target_position(min_child_position, last_goal_position)

    Logger.info(
      "Moving goal #{parent_goal.identifier} to column #{target_column.id} at position #{target_position} (min_child_position: #{inspect(min_child_position)}, last_goal_position: #{inspect(last_goal_position)})"
    )

    Task
    |> where([t], t.id == ^parent_goal.id)
    |> Repo.update_all(set: [column_id: target_column.id, position: -999_999])

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

    Enum.each(tasks_to_shift, fn task ->
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [position: task.position + 1])
    end)

    is_done = String.downcase(target_column.name) == "done"

    updates =
      if is_done do
        [position: target_position, completed_at: DateTime.utc_now(), status: :completed]
      else
        [position: target_position, completed_at: nil, status: :open]
      end

    Task
    |> where([t], t.id == ^parent_goal.id)
    |> Repo.update_all(set: updates)

    Logger.info("Goal #{parent_goal.identifier} placed at position #{target_position}")

    updated_goal = Queries.get_task!(parent_goal.id)
    Broadcaster.broadcast_task_change(updated_goal, :task_moved)
    {:ok, :moved}
  end
end
