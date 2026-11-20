defmodule Kanban.Decisions.ColumnCountsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Decisions.ColumnCounts

  setup do
    owner = user_fixture()
    %{owner: owner, board: board_fixture(owner)}
  end

  test "counts unarchived work and defects in Ready and Backlog columns", ctx do
    ready = column_fixture(ctx.board, %{name: "Ready"})
    backlog = column_fixture(ctx.board, %{name: "Backlog"})
    other = column_fixture(ctx.board, %{name: "Doing"})

    task_fixture(ready)
    task_fixture(ready, %{type: :defect})
    task_fixture(ready, %{type: :goal})
    task_fixture(other)

    ready
    |> task_fixture()
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert ColumnCounts.by_board([ctx.board.id]) == %{
             ctx.board.id => %{ready: 2, backlog: 0, backlog_full: false}
           }

    backlog |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()
    task_fixture(backlog)

    assert %{backlog: 1, backlog_full: true} = ColumnCounts.by_board([ctx.board.id])[ctx.board.id]
  end

  test "recognises columns named in another case or padded, and adds up repeats", ctx do
    first = column_fixture(ctx.board, %{name: " READY "})
    second = column_fixture(ctx.board, %{name: "ready"})
    column_fixture(ctx.board, %{name: "\tbacklog\n"})

    task_fixture(first)
    task_fixture(second)

    assert ColumnCounts.by_board([ctx.board.id]) == %{
             ctx.board.id => %{ready: 2, backlog: 0, backlog_full: false}
           }
  end

  test "a board without Ready or Backlog columns has nil counts; no boards, no query", ctx do
    column_fixture(ctx.board, %{name: "Doing"})

    assert ColumnCounts.by_board([ctx.board.id]) == %{
             ctx.board.id => %{ready: nil, backlog: nil, backlog_full: false}
           }

    assert ColumnCounts.by_board([]) == %{}
  end
end
