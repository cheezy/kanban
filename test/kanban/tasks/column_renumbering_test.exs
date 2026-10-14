defmodule Kanban.Tasks.ColumnRenumberingTest do
  @moduledoc """
  A board drag renumbers the columns it touches while holding their locks, but
  an agent claim, completion or unclaim locks only the column it moves a task
  INTO, so it can take a task OUT of a column between the drag's read of its
  positions and its writes. The `after_positions_read` seam runs at exactly
  that point; the writes must then skip the task that left, rather than
  renumber it inside the column it moved to.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.ColumnLockHelpers
  alias Kanban.Repo
  alias Kanban.Tasks.ColumnRenumbering
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task

  setup do
    original = Application.get_env(:kanban, ColumnRenumbering)

    on_exit(fn ->
      if original,
        do: Application.put_env(:kanban, ColumnRenumbering, original),
        else: Application.delete_env(:kanban, ColumnRenumbering)
    end)

    board = board_fixture(user_fixture())

    %{
      backlog: column_fixture(board, %{name: "Backlog"}),
      ready: column_fixture(board, %{name: "Ready"}),
      doing: column_fixture(board, %{name: "Doing"})
    }
  end

  # Runs `fun` once, the first time `column_id`'s positions are read.
  defp after_positions_read(column_id, fun) do
    fired = :counters.new(1, [])

    Application.put_env(:kanban, ColumnRenumbering,
      after_positions_read: fn read_column_id ->
        if read_column_id == column_id and :counters.get(fired, 1) == 0 do
          :counters.add(fired, 1, 1)
          fun.()
        end
      end
    )
  end

  defp position(task), do: Repo.get!(Task, task.id) |> Map.take([:column_id, :position])

  defp live_order(column) do
    Task
    |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
    |> order_by([t], asc: t.position)
    |> select([t], {t.id, t.position})
    |> Repo.all()
  end

  test "closing the gap a drag leaves skips a task an agent took out of the column meanwhile",
       %{backlog: backlog, ready: ready, doing: doing} do
    dragged = task_fixture(ready)
    claimed = task_fixture(ready)
    stays = task_fixture(ready)
    # Doing's position 0 is taken, so renumbering `claimed` there (1 - 1 = 0)
    # would collide on the (column_id, position) index.
    in_doing = task_fixture(doing)

    after_positions_read(ready.id, fn ->
      ColumnLockHelpers.relocate!(claimed.id, doing.id, 1)
    end)

    assert {:ok, moved} = Positioning.move_task(dragged, backlog, 0)

    assert moved.column_id == backlog.id
    assert position(claimed) == %{column_id: doing.id, position: 1}
    assert live_order(doing) == [{in_doing.id, 0}, {claimed.id, 1}]
    assert live_order(ready) == [{stays.id, 1}]
  end

  test "making room for a dropped card skips a task an agent took out of the column meanwhile",
       %{backlog: backlog, ready: ready, doing: doing} do
    claimed = task_fixture(ready)
    stays = task_fixture(ready)
    in_doing = task_fixture(doing)
    dropped = task_fixture(backlog)

    after_positions_read(ready.id, fn ->
      ColumnLockHelpers.relocate!(claimed.id, doing.id, 5)
    end)

    # Dropped at the top of Ready, which shifts `claimed` from 0 to 1 and
    # `stays` from 1 to 2. Those writes are by id, so without the column check
    # `claimed` would be moved from 5 to 1 inside Doing.
    assert {:ok, moved} = Positioning.move_task(dropped, ready, 0)

    assert moved.column_id == ready.id
    assert moved.position == 0
    assert live_order(ready) == [{dropped.id, 0}, {stays.id, 2}]
    assert live_order(doing) == [{in_doing.id, 0}, {claimed.id, 5}]
  end

  test "with no task leaving, a cross-column move still leaves both columns contiguous",
       %{backlog: backlog, ready: ready} do
    first = task_fixture(ready)
    second = task_fixture(ready)
    third = task_fixture(ready)
    existing = task_fixture(backlog)

    assert {:ok, _} = Positioning.move_task(first, backlog, 0)

    assert live_order(ready) == [{second.id, 0}, {third.id, 1}]
    assert live_order(backlog) == [{first.id, 0}, {existing.id, 1}]
  end
end
