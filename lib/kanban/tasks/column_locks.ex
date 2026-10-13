defmodule Kanban.Tasks.ColumnLocks do
  @moduledoc """
  Takes several column advisory locks at once, for every writer that needs
  more than one: `Kanban.Tasks.Positioning` (a board move),
  `Kanban.Tasks.BulkActions` (a bulk move), `Kanban.Tasks.Creation` (a task
  created under a goal) and `Kanban.Tasks.LockedGoalPlacement` (a goal
  re-placement, D373). A writer that needs a single column still locks it
  directly, as `Kanban.Tasks.Positioning.get_next_position_locked/1` does.

  Every writer that renumbers a column's positions holds that column's
  transaction-level advisory lock (`pg_advisory_xact_lock(column_id)`). A
  writer that needs several columns takes them in ONE ascending pass, so two
  writers can never each hold a column the other is waiting for (D368).

  The locks are released when the surrounding transaction ends, so these
  functions must run inside a `Repo.transaction`. They are re-entrant within
  a session, so a caller that already holds a column can take it again
  without blocking.
  """

  alias Kanban.Repo

  @doc """
  Takes the advisory lock of every column in `column_ids`, in ascending id
  order, waiting for any that another session holds, and returns the ids it
  locked (deduplicated and sorted). `nil` ids are skipped.
  """
  def lock(column_ids) do
    locked = normalize(column_ids)
    Enum.each(locked, &Repo.query!("SELECT pg_advisory_xact_lock($1)", [&1]))
    locked
  end

  @doc """
  Like `lock/1`, but never waits: each lock is tried
  (`pg_try_advisory_xact_lock`), and the first one another session holds
  stops the pass. Returns `true` when every column is locked, `false`
  otherwise. Locks already taken by a failed pass stay held until the
  transaction ends; they never make anything wait on this session's behalf.

  For a caller inside a transaction that may already hold a column lock, where
  waiting for a lower-numbered column would break the ascending order and
  could deadlock against a board drag (D373).
  """
  def try_lock(column_ids) do
    column_ids
    |> normalize()
    |> Enum.all?(fn column_id ->
      %{rows: [[locked?]]} =
        Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [column_id])

      locked?
    end)
  end

  defp normalize(column_ids) do
    column_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
