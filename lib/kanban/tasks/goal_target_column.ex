defmodule Kanban.Tasks.GoalTargetColumn do
  @moduledoc """
  Decides which column a goal belongs in, given where its child tasks are.

  Extracted from `Kanban.Tasks.Goals` (W2349) to keep that module under the
  size cap. `Kanban.Tasks.Goals.update_parent_goal_position/4` asks this
  module *where* a goal belongs and `Kanban.Tasks.GoalPlacement` performs the
  move. Everything here is a read: no row is written.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task

  @doc """
  Resolves the parent goal of `moving_task` and the column that goal belongs
  in, given where its non-archived children are.

  Returns `{:ok, parent_goal, target_column}`, or `:error` when the task has no
  parent, its parent is not a goal, or the goal has no non-archived children.
  The target may be the goal's current column; deciding whether to move is the
  caller's job.
  """
  def resolve(moving_task) do
    with {:ok, parent_goal} <- get_parent_goal(moving_task),
         {:ok, goal_context} <- build_goal_context(parent_goal),
         {:ok, target_column} <- determine_target_column(goal_context, parent_goal) do
      {:ok, parent_goal, target_column}
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
        where: t.parent_id == ^parent_goal.id and is_nil(t.archived_at),
        select: {t.id, t.column_id, t.status}
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
         child_ids: Enum.map(children_data, fn {id, _, _} -> id end)
       }}
    end
  end

  # Goal target column rules:
  #
  # 1. All children in Done AND the goal's after_goal hook reported
  #    success (or no after_goal lifecycle has started for this goal) →
  #    promote to Done.
  # 2. All children in Done BUT after_goal_status is `:pending` —
  #    the agent has not yet reported and the Oban grace-window worker
  #    has not yet fired (W493). Hold the goal in its current column so
  #    it remains visible as In Progress (using pick_leftmost_child_column
  #    here would pick Done since that's where all the kids are).
  #    build_goal_context/1 loads every column of the goal's own board, so
  #    column_map always holds the goal's column; Map.fetch!/2 raises only
  #    if that invariant breaks.
  # 3. Children spread across columns → pick the leftmost child column.
  defp determine_target_column(goal_context, parent_goal) do
    done_column = find_done_column(goal_context.all_columns)

    target_column =
      cond do
        all_children_in_done?(goal_context, done_column) and
            after_goal_blocks_done?(parent_goal) ->
          Map.fetch!(goal_context.column_map, parent_goal.column_id)

        all_children_in_done?(goal_context, done_column) ->
          done_column

        true ->
          pick_leftmost_child_column(goal_context)
      end

    {:ok, target_column}
  end

  # A `:pending` after_goal_status blocks the Done promotion;
  # `nil` (never had an after_goal lifecycle) and `:succeeded` both
  # allow the promotion. The Oban grace worker and the
  # `/api/tasks/:goal_id/after_goal` endpoint are the two paths that
  # flip `:pending` → `:succeeded`.
  defp after_goal_blocks_done?(%Task{after_goal_status: :pending}), do: true
  defp after_goal_blocks_done?(_), do: false

  defp all_children_in_done?(_goal_context, nil), do: false

  # A child counts as "done" when it physically sits in the Done column OR
  # its status is :completed. The status branch covers tasks completed outside
  # the normal claim -> complete -> auto_move_to_done pipeline (e.g. a manually
  # verified task that was never claimed), which would otherwise strand the
  # goal out of Done forever. This is safe for the AI review workflow because a
  # task awaiting human review sits in Review as :in_progress (see
  # Positioning.determine_status_for_column/2) — only genuinely finished work
  # carries status :completed.
  defp all_children_in_done?(goal_context, done_column) do
    Enum.all?(goal_context.children_data, fn {_id, column_id, status} ->
      column_id == done_column.id or status == :completed
    end)
  end

  defp pick_leftmost_child_column(goal_context) do
    valid_columns =
      goal_context.children_data
      |> Enum.map(fn {_id, column_id, _status} -> goal_context.column_map[column_id] end)
      |> Enum.reject(&is_nil/1)

    case valid_columns do
      [] -> List.first(goal_context.all_columns)
      columns -> Enum.min_by(columns, & &1.position)
    end
  end

  @doc """
  Returns the column named "Done" (matched case-insensitively) from
  `columns`, or `nil` when there is none.
  """
  def find_done_column(columns) do
    Enum.find(columns, fn col -> String.downcase(col.name) == "done" end)
  end
end
