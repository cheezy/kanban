defmodule Kanban.Tasks.LockedGoalPlacement do
  @moduledoc """
  Re-places a goal while holding the advisory lock of every column the
  re-placement can write to (D373).

  A goal re-placement renumbers the goal's old column and its target column
  (`Kanban.Tasks.GoalPlacement`). A board drag renumbers the same columns
  under their locks (D368), so a re-placement that held none could collide
  with it on the partial unique `(column_id, position)` index. This module
  is the locked entry point, reached through
  `Kanban.Tasks.Goals.update_parent_goal_position_locked/2`, for every caller
  except `Kanban.Tasks.Positioning`, which already holds the locks and calls
  `Kanban.Tasks.Goals.update_parent_goal_position/4` directly.

  Extracted from `Kanban.Tasks.Goals` to keep that module under the size cap.
  `Kanban.Tasks.GoalTargetColumn` decides where the goal belongs, this module
  decides which locks that needs, and `Kanban.Tasks.GoalPlacement` performs
  the move.
  """

  alias Kanban.Repo
  alias Kanban.Tasks.ColumnLocks
  alias Kanban.Tasks.GoalPlacement
  alias Kanban.Tasks.GoalTargetColumn

  require Logger

  @default_max_placement_attempts 3

  @doc """
  Re-places `moving_task`'s parent goal, as
  `Kanban.Tasks.Goals.update_parent_goal_position/4` does, while holding the
  locks of the goal's own column, its live children's columns and its target
  column.

  Those columns are read unlocked, locked in one ascending pass
  (`Kanban.Tasks.ColumnLocks`), then read again under the locks. If they
  changed meanwhile, the attempt writes nothing and is retried, up to
  `:max_placement_attempts` (default 3), after which the goal stays where it
  was. Outside a transaction, a database or connection error is logged
  rather than raised, so a re-placement after a committed claim or
  completion never becomes an API error.

  Inside a caller's transaction (an approval in `Kanban.Reviews` re-places
  the goal inside its own) there is one attempt, and it never waits: the
  caller may already hold a higher-numbered column, and waiting for a lower
  one could deadlock against a board drag. Each lock is tried instead
  (`Kanban.Tasks.ColumnLocks.try_lock/1`), and if another writer holds one,
  the goal stays where it was. Nothing is rolled back either way.

  With `held: column_ids` the caller's transaction already holds those locks
  (task creation): nothing is locked, and the goal is re-placed only if every
  column it needs is among them.

  A task with no parent goal, or whose goal has no live children, takes no
  lock. Always returns `:ok`.
  """
  def place(moving_task, opts \\ [])

  def place(%{parent_id: nil}, _opts), do: :ok

  def place(moving_task, held: held) do
    place_holding(moving_task, held)
    :ok
  end

  def place(moving_task, _opts) do
    config = Application.get_env(:kanban, __MODULE__, [])
    # Test seam, unset outside tests: runs where a concurrent writer would land.
    seam = Keyword.get(config, :after_column_read)

    if Repo.in_transaction?() do
      attempt(moving_task, seam, 1)
    else
      attempts = Keyword.get(config, :max_placement_attempts, @default_max_placement_attempts)
      attempt_outside_transaction(moving_task, seam, attempts)
    end
  end

  defp attempt_outside_transaction(moving_task, seam, attempts) do
    attempt(moving_task, seam, attempts)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "Goal re-placement for task #{moving_task.id} was skipped: #{Exception.message(error)}"
      )

      :ok
  end

  defp attempt(moving_task, seam, attempts_left) do
    case placement(moving_task) do
      :error ->
        :ok

      {:ok, _goal, _target, columns} ->
        if seam, do: seam.(moving_task)

        moving_task
        |> lock_and_place(columns, Repo.in_transaction?())
        |> retry(moving_task, seam, attempts_left)
    end
  end

  # Outside a transaction: wait for the locks, in a transaction of their own.
  defp lock_and_place(moving_task, columns, false),
    do: Repo.transaction(fn -> place_holding(moving_task, ColumnLocks.lock(columns)) end)

  # Inside a caller's transaction: never wait, so the caller's own locks can
  # never be held while this waits out of ascending order (D373).
  defp lock_and_place(moving_task, columns, true) do
    if ColumnLocks.try_lock(columns),
      do: {:ok, place_holding(moving_task, columns)},
      else: {:ok, :busy}
  end

  defp retry({:ok, :column_changed}, moving_task, seam, attempts_left) when attempts_left > 1,
    do: attempt(moving_task, seam, attempts_left - 1)

  defp retry({:ok, :column_changed}, moving_task, _seam, _attempts_left) do
    Logger.warning(
      "Goal re-placement for task #{moving_task.id} gave up: the goal's columns kept changing"
    )

    :ok
  end

  defp retry({:ok, :busy}, moving_task, _seam, _attempts_left) do
    Logger.warning(
      "Goal re-placement for task #{moving_task.id} was skipped: another writer holds one of the goal's columns"
    )

    :ok
  end

  defp retry({:ok, :placed}, _moving_task, _seam, _attempts_left), do: :ok

  # Places the goal only when every column it needs is held. Otherwise it
  # writes nothing, so a caller's transaction never has to roll back.
  defp place_holding(moving_task, held) do
    case placement(moving_task) do
      :error ->
        :placed

      {:ok, goal, target, columns} ->
        if columns -- held == [] do
          move_goal_if_needed(goal, target)
          :placed
        else
          :column_changed
        end
    end
  end

  # The goal, its target column, and every column the re-placement writes to:
  # the target, the goal's own column (closed up when it leaves) and its live
  # children's columns. The target can be the Done column with no child in it
  # (a child counts as done by status), so it is added explicitly.
  defp placement(moving_task) do
    case GoalTargetColumn.resolve(moving_task) do
      {:ok, goal, target} ->
        {:ok, goal, target, Enum.uniq([target.id | GoalPlacement.goal_column_ids(goal.id)])}

      :error ->
        :error
    end
  end

  defp move_goal_if_needed(%{column_id: column_id}, %{id: column_id}), do: :ok

  defp move_goal_if_needed(goal, target) do
    {:ok, _} =
      GoalPlacement.move_goal_to_top_with_other_goals(goal, target, DateTime.utc_now(:second))

    :ok
  end
end
