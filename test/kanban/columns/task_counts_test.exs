defmodule Kanban.Columns.TaskCountsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Columns.TaskCounts

  setup do
    owner = user_fixture()
    %{owner: owner, board: board_fixture(owner)}
  end

  describe "by_board/1" do
    test "lists every column by position with its live work and defect count", ctx do
      # Created first, so the lower id, but moved right of the others.
      right = column_fixture(ctx.board, %{name: "Done"})
      left = column_fixture(ctx.board, %{name: "Ready"})
      empty = column_fixture(ctx.board, %{name: "Doing"})
      :ok = Columns.reorder_columns(ctx.board, [left.id, empty.id, right.id], ctx.owner)
      left |> Ecto.Changeset.change(wip_limit: 3) |> Repo.update!()

      task_fixture(left)
      task_fixture(left, %{type: :defect})
      task_fixture(left, %{type: :goal})

      left
      |> task_fixture()
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update!()

      task_fixture(right)

      assert TaskCounts.by_board([ctx.board.id]) == %{
               ctx.board.id => [
                 %{id: left.id, name: "Ready", wip_limit: 3, count: 2},
                 %{id: empty.id, name: "Doing", wip_limit: 0, count: 0},
                 %{id: right.id, name: "Done", wip_limit: 0, count: 1}
               ]
             }
    end

    test "keys each board apart, leaves out a board with no columns, and makes no query for none",
         ctx do
      other = board_fixture(ctx.owner)
      bare = board_fixture(ctx.owner)
      column = column_fixture(other, %{name: "Ready"})
      task_fixture(column)

      counts = TaskCounts.by_board([ctx.board.id, other.id, bare.id])
      assert Map.keys(counts) == [other.id]
      assert [%{id: id, count: 1}] = counts[other.id]
      assert id == column.id
      assert TaskCounts.by_board([]) == %{}
    end
  end

  describe "column/2 and count/2" do
    test "read the leftmost column of a name, ignoring case and spaces" do
      columns = [
        %{id: 1, name: " READY ", wip_limit: nil, count: 0},
        %{id: 2, name: "Doing", wip_limit: nil, count: 4},
        %{id: 3, name: "ready", wip_limit: nil, count: 7}
      ]

      assert %{id: 1} = TaskCounts.column(columns, "Ready")
      assert TaskCounts.count(columns, "Ready") == 0
      assert TaskCounts.count(columns, "doing") == 4
    end

    test "answer nil for a name the board has no column for" do
      assert TaskCounts.column([%{id: 1, name: "Doing", count: 2}], "Backlog") == nil
      assert TaskCounts.count([%{id: 1, name: "Doing", count: 2}], "Backlog") == nil
      assert TaskCounts.count([], "Backlog") == nil
    end
  end
end
