defmodule Kanban.Tasks.ColumnRenumbering do
  @moduledoc """
  Renumbers the live tasks of one column for a board move, split from
  `Kanban.Tasks.Positioning` (which sat at the module-size limit in
  `AGENTS.md`). `insert_at_index/4` makes room for a dropped card and
  `close_up_after_removal/3` closes the gap a card leaves.

  The caller must hold the column's advisory lock (`Kanban.Tasks.ColumnLocks`),
  so no task can move INTO the column while it is renumbered. An agent claim,
  completion or unclaim locks only the column it moves a task into, though, and
  can take a task OUT of this one between the read of its positions and the
  writes. Every write therefore names the column as well as the id: a task that
  left is skipped, rather than renumbered inside the column it moved to, where
  its stale position could collide with a live one.

  Every final write stamps `updated_at` with the caller's `now` (D357).
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Places `task` at `index` among the other live cards of `column` and returns
  the position it gets. The task itself must already sit at a temporary
  negative position.

  The board sends the index the card was dropped at among the column's other
  cards, not a stored position. Positions can have gaps (archiving a task does
  not renumber its column), and treating the index as a position then put the
  card one or more places away from where it was dropped. So the column's other
  live cards are laid out 0..n in their current order with the moving card's
  slot at the index, and only rows whose position really changes are written,
  and stamped (D357).
  """
  def insert_at_index(column, task, index, now) do
    others = other_live_positions(column, task.id)
    run_after_positions_read_seam(column.id)
    position = index |> max(0) |> min(length(others))
    {before, rest} = Enum.split(others, position)

    changed =
      (Enum.with_index(before) ++ Enum.with_index(rest, position + 1))
      |> Enum.reject(fn {{_id, old}, new} -> old == new end)

    write_positions(column.id, changed, now)
    position
  end

  @doc """
  Moves every live task below `removed_position` in `column` up by one, closing
  the gap a card moved out of the column left.
  """
  def close_up_after_removal(column, removed_position, now) do
    query =
      from t in Task,
        where: t.column_id == ^column.id,
        where: t.position > ^removed_position,
        where: is_nil(t.archived_at),
        order_by: t.position

    tasks = Repo.all(query)
    run_after_positions_read_seam(column.id)

    Enum.each(tasks, fn task ->
      Task
      |> in_column(task.id, column.id)
      |> Repo.update_all(set: [position: task.position - 1, updated_at: now])
    end)
  end

  # The column's live tasks other than `moving_task_id` (which sits at a
  # temporary negative position), as `{id, position}` in display order.
  defp other_live_positions(column, moving_task_id) do
    Task
    |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
    |> where([t], t.id != ^moving_task_id and t.position >= 0)
    |> order_by([t], asc: t.position, asc: t.id)
    |> select([t], {t.id, t.position})
    |> Repo.all()
  end

  # Parks the changed rows at temporary negative positions first so the partial
  # unique (column_id, position) index never sees a collision, then writes each
  # row's new position once.
  defp write_positions(_column_id, [], _now), do: :ok

  defp write_positions(column_id, changed, now) do
    ids = Enum.map(changed, fn {{id, _old}, _new} -> id end)

    from(t in Task,
      where: t.id in ^ids and t.column_id == ^column_id,
      update: [set: [position: fragment("-1 * ?", t.id)]]
    )
    |> Repo.update_all([])

    Enum.each(changed, fn {{id, _old}, new} ->
      Task
      |> in_column(id, column_id)
      |> Repo.update_all(set: [position: new, updated_at: now])
    end)
  end

  defp in_column(query, id, column_id),
    do: where(query, [t], t.id == ^id and t.column_id == ^column_id)

  # Test seam, unset outside tests: runs once a column's positions are read,
  # where an agent move out of the column would land.
  defp run_after_positions_read_seam(column_id) do
    seam = :kanban |> Application.get_env(__MODULE__, []) |> Keyword.get(:after_positions_read)
    if seam, do: seam.(column_id)
  end
end
