defmodule Kanban.Tasks.Goals do
  @moduledoc """
  Goal hierarchy, promotion, parent tracking, and tree queries.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.GoalPlacement
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task

  @doc """
  Gets a task with hierarchical tree structure, scoped to a board.

  Returns a map with the task, children, and counts. Returns `nil` if the
  task does not exist on the supplied board — closes the cross-board IDOR
  that the previous 1-arity variant left open (W397).
  """
  def get_task_tree(task_id, board_id) when is_integer(task_id) and is_integer(board_id) do
    case Queries.get_task_for_board(task_id, board_id) do
      nil ->
        nil

      task ->
        task =
          Repo.preload(task, [
            :column,
            :assigned_to,
            :created_by,
            :completed_by,
            :reviewed_by,
            :labels
          ])

        children =
          if task.type == :goal,
            do: fetch_scoped_children(task_id, board_id, preload: true),
            else: []

        build_task_tree_result(task, children)
    end
  end

  defp fetch_scoped_children(parent_task_id, board_id, opts) do
    preload? = Keyword.get(opts, :preload, false)
    include_archived? = Keyword.get(opts, :include_archived, false)

    base =
      from(t in Task,
        join: c in assoc(t, :column),
        where: t.parent_id == ^parent_task_id and c.board_id == ^board_id,
        order_by: [asc: t.position]
      )
      |> exclude_archived_unless(include_archived?)

    if preload? do
      base
      |> preload([:column, :assigned_to, :created_by, :completed_by, :reviewed_by, :labels])
      |> Repo.all()
    else
      Repo.all(base)
    end
  end

  # Board/flow views exclude archived children (the default); only the target
  # progress path opts in to archived children so it can credit archived-
  # completed work. See D124.
  defp exclude_archived_unless(query, true), do: query

  defp exclude_archived_unless(query, false),
    do: from(t in query, where: is_nil(t.archived_at))

  defp build_task_tree_result(task, children) do
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
  Gets all child tasks for a given parent task (goal), scoped to a board.

  Returns `[]` for children on other boards — closes the cross-board IDOR that
  the previous 1-arity variant left open (W397).
  """
  def get_task_children(parent_task_id, board_id) do
    fetch_scoped_children(parent_task_id, board_id, preload: false)
  end

  @doc """
  Like `get_task_children/2` but INCLUDES archived children, board-scoped.

  Used only by the target progress path (`Kanban.Targets`), which must credit
  archived-but-completed work toward a goal's completion instead of silently
  dropping it. Board columns and flow views keep using `get_task_children/2`
  (archived excluded), so this does not resurface archived tasks there. See D124.
  """
  def get_task_children_including_archived(parent_task_id, board_id) do
    fetch_scoped_children(parent_task_id, board_id, preload: false, include_archived: true)
  end

  @doc """
  Batched form of `get_task_children_including_archived/2`.

  Given a list of `{goal_id, board_id}` pairs (typically a delivery target's
  member goals, each with its own board), returns a map of
  `goal_id => [child Task]` (archived children included, per D124), fetching all
  children with **one query per distinct board** instead of one per goal. Each
  child is board-scoped to its goal's board exactly as the per-goal variant, so
  the W397 cross-board IDOR closure is preserved. A goal with no children is
  simply absent from the map — callers use `Map.get(map, goal_id, [])`.

  This bounds the per-goal N+1 the target rollup (`Kanban.Targets.DeliveryRollup`)
  used to fire on every /agents refresh (D125): query count is now O(boards),
  not O(goals).
  """
  def get_children_including_archived_by_parent(goal_board_pairs) do
    goal_board_pairs
    |> Enum.group_by(fn {_goal_id, board_id} -> board_id end, fn {goal_id, _board_id} ->
      goal_id
    end)
    |> Enum.flat_map(fn {board_id, goal_ids} ->
      from(t in Task,
        join: c in assoc(t, :column),
        where: t.parent_id in ^goal_ids and c.board_id == ^board_id,
        order_by: [asc: t.position]
      )
      |> Repo.all()
    end)
    |> Enum.group_by(& &1.parent_id)
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
  Returns the goal awaiting its `after_goal` for a completing task on `board_id`,
  or `nil` when no after_goal is armed. Read-only — performs no state transition.

  An after_goal is "armed" when the relevant goal's `after_goal_status` is
  `:pending`: its last child has completed and the agent-run `## after_goal`
  section is awaited (the `/after_goal` PATCH or the grace worker later flips it
  to `:succeeded`, after which this returns `nil`). Accepts either the completing
  child task — resolving its parent goal — or a goal task directly. The `board_id`
  scopes the derived-parent lookup exactly like the sibling `get_task_tree/2`, so
  a goal on another board can never be surfaced.

  Backs `GET /api/tasks/:id/after_goal_status` so the Stride hook can decide
  whether to run `## after_goal` without parsing the large, truncatable
  `/complete` response.
  """
  def after_goal_armed_goal(%Task{type: :goal, after_goal_status: :pending} = goal, _board_id),
    do: goal

  def after_goal_armed_goal(%Task{parent_id: parent_id}, board_id) when is_integer(parent_id) do
    case Queries.get_task_for_board(parent_id, board_id) do
      %Task{type: :goal, after_goal_status: :pending} = goal -> goal
      _ -> nil
    end
  end

  def after_goal_armed_goal(%Task{}, _board_id), do: nil

  @doc """
  Marks a goal's after_goal lifecycle as `:succeeded` and promotes the
  goal to its Done column. Called by:

    * `PATCH /api/tasks/:goal_id/after_goal` when the agent reports
      `exit_code: 0`.
    * `Kanban.AfterGoal.GraceWorker` when the configured grace window
      expires and the agent never reported (back-compat for older
      plugins that don't speak after_goal).

  Idempotent — calling against an already-`:succeeded` goal is a no-op
  with `{:ok, goal}` so duplicate reports and report-after-Done
  scenarios both succeed cleanly per W493's acceptance criteria.
  """
  def mark_after_goal_succeeded_and_promote(%Task{type: :goal} = goal, attempt) do
    result =
      Repo.transaction(fn ->
        goal = Repo.get!(Task, goal.id)

        if goal.after_goal_status == :succeeded do
          # Idempotent: status already succeeded. Append the attempt to
          # the audit log but do not re-promote (the goal is already in
          # its Done column).
          {:idempotent, append_after_goal_attempt(goal, attempt)}
        else
          {:promoted, flip_to_succeeded_and_promote(goal, attempt)}
        end
      end)

    case result do
      {:ok, {:promoted, updated_goal}} ->
        # Broadcast the column move so subscribed LiveViews (the board)
        # animate the goal to Done without requiring a page reload.
        # Fired post-commit so subscribers always observe the persisted
        # state on re-query.
        done_goal = Queries.get_task!(updated_goal.id)
        Broadcaster.broadcast_task_change(done_goal, :task_moved)
        Events.goal_completed(done_goal)

        {:ok, updated_goal}

      {:ok, {:idempotent, updated_goal}} ->
        {:ok, updated_goal}

      {:error, _} = err ->
        err
    end
  end

  defp flip_to_succeeded_and_promote(goal, attempt) do
    attrs = %{
      after_goal_status: :succeeded,
      after_goal_result: attempt,
      after_goal_attempts: (goal.after_goal_attempts || []) ++ [attempt]
    }

    {:ok, updated_goal} =
      goal
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()

    # Promote to Done. The goal's column is computed from its
    # children's columns; with after_goal_status now :succeeded
    # the gate in determine_target_column allows the Done move.
    promote_goal_to_done_column(updated_goal)
    updated_goal
  end

  @doc """
  Appends a non-successful after_goal report (exit_code != 0) to the
  goal's audit log without flipping status. Goal stays In Progress and
  the agent can retry.
  """
  def record_after_goal_failure(%Task{type: :goal} = goal, attempt) do
    goal = Repo.get!(Task, goal.id)
    updated = append_after_goal_attempt(goal, attempt)
    Events.after_goal_failed(updated, attempt)
    {:ok, updated}
  end

  defp append_after_goal_attempt(goal, attempt) do
    {:ok, updated} =
      goal
      |> Ecto.Changeset.change(%{
        after_goal_result: attempt,
        after_goal_attempts: (goal.after_goal_attempts || []) ++ [attempt]
      })
      |> Repo.update()

    updated
  end

  defp promote_goal_to_done_column(goal) do
    parent_column = Columns.get_column!(goal.column_id)

    all_columns =
      from(c in Column,
        where: c.board_id == ^parent_column.board_id,
        order_by: [asc: c.position]
      )
      |> Repo.all()

    case find_done_column(all_columns) do
      nil ->
        :ok

      done_column when done_column.id == goal.column_id ->
        :ok

      done_column ->
        move_task_to_column(goal, done_column, DateTime.utc_now(:second))
        :ok
    end
  end

  @doc """
  Updates the parent goal's column position based on where its children are.

  `now` is the whole-second UTC `updated_at` stamped on the goal and on any
  sibling shifted to make room; a caller inside a larger move passes its own
  so every row touched by one operation shares one value.
  """
  def update_parent_goal_position(
        moving_task,
        _task_old_column_id,
        _task_new_column_id,
        now \\ DateTime.utc_now(:second)
      ) do
    with {:ok, parent_goal} <- get_parent_goal(moving_task),
         {:ok, goal_context} <- build_goal_context(parent_goal),
         {:ok, target_column} <- determine_target_column(goal_context, parent_goal),
         {:ok, _} <- move_goal_if_needed(parent_goal, target_column, now) do
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
        now = DateTime.utc_now(:second)
        Enum.each(tasks_to_move, &move_task_to_column(&1, ready_column, now))
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

  # Bulk writes bypass autogenerated timestamps, so updated_at is set here
  # (D357; see Kanban.Tasks.Positioning).
  defp move_task_to_column(task, target_column, now) do
    next_pos = Positioning.get_next_position_locked(target_column)
    status_updates = Positioning.determine_status_for_column(target_column, task)

    updates =
      Map.merge(
        %{column_id: target_column.id, position: next_pos, updated_at: now},
        status_updates
      )

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
  # 3. Children spread across columns → pick the leftmost child column.
  defp determine_target_column(goal_context, parent_goal) do
    done_column = find_done_column(goal_context.all_columns)

    target_column =
      cond do
        all_children_in_done?(goal_context, done_column) and
            after_goal_blocks_done?(parent_goal) ->
          goal_context.column_map[parent_goal.column_id] ||
            pick_leftmost_non_done_column(goal_context, done_column)

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

  # Fallback when the parent goal's current column is no longer in the
  # board's column set (e.g., archived). Picks the leftmost column that
  # is not Done so the goal stays visibly In Progress while after_goal
  # is pending.
  defp pick_leftmost_non_done_column(goal_context, done_column) do
    goal_context.all_columns
    |> Enum.reject(fn col -> done_column && col.id == done_column.id end)
    |> List.first() || List.first(goal_context.all_columns)
  end

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

  defp find_done_column(columns) do
    Enum.find(columns, fn col -> String.downcase(col.name) == "done" end)
  end

  defp move_goal_if_needed(parent_goal, target_column, now) do
    if target_column.id != parent_goal.column_id do
      GoalPlacement.move_goal_to_top_with_other_goals(parent_goal, target_column, now)
    else
      {:ok, :no_change}
    end
  end
end
