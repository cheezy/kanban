defmodule Kanban.Tasks.PositioningTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Positioning

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  defp archive!(task) do
    Kanban.Tasks.Task
    |> where([x], x.id == ^task.id)
    |> Repo.update_all(set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    task
  end

  describe "moving into Review stamps review_requested_at" do
    setup %{board: board} do
      doing = column_fixture(board, %{name: "Doing", position: 1})
      review = column_fixture(board, %{name: "Review", position: 2})
      %{doing: doing, review: review}
    end

    defp review_requested_at(task), do: Repo.reload!(task).review_requested_at

    test "a drag in from another column stamps the time it entered Review",
         %{doing: doing, review: review} do
      task = task_fixture(doing)

      assert {:ok, _} = Kanban.Tasks.move_task(task, review, 0)

      assert DateTime.diff(DateTime.utc_now(), review_requested_at(task)) in 0..5
    end

    test "a reorder inside Review keeps the original stamp", %{doing: doing, review: review} do
      first = task_fixture(review)
      _second = task_fixture(review)
      entered = ~U[2026-09-01 12:00:00Z]

      Kanban.Tasks.Task
      |> where([t], t.id == ^first.id)
      |> Repo.update_all(set: [review_requested_at: entered])

      assert {:ok, _} = first |> Repo.reload!() |> Kanban.Tasks.move_task(review, 1)
      assert review_requested_at(first) == entered

      other = task_fixture(doing)
      assert {:ok, _} = Kanban.Tasks.move_task(other, doing, 0)
      assert review_requested_at(other) == nil
    end
  end

  describe "get_next_position/1" do
    test "returns 0 for empty column", %{column: column} do
      assert Positioning.get_next_position(column) == 0
    end

    test "returns max position + 1", %{column: column} do
      _task1 = task_fixture(column)
      _task2 = task_fixture(column)

      assert Positioning.get_next_position(column) == 2
    end
  end

  describe "get_next_position_locked/1" do
    test "returns 0 for empty column", %{column: column} do
      result =
        Repo.transaction(fn ->
          Positioning.get_next_position_locked(column)
        end)

      assert {:ok, 0} = result
    end

    test "returns max position + 1", %{column: column} do
      _task1 = task_fixture(column)
      _task2 = task_fixture(column)

      result =
        Repo.transaction(fn ->
          Positioning.get_next_position_locked(column)
        end)

      assert {:ok, 2} = result
    end

    test "serializes concurrent position allocations", %{column: column} do
      # Launch two concurrent tasks that each lock, read, and insert
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Repo.transaction(fn ->
              pos = Positioning.get_next_position_locked(column)

              Repo.insert!(%Kanban.Tasks.Task{
                title: "Concurrent Task",
                column_id: column.id,
                position: pos,
                type: :work,
                priority: :medium
              })

              pos
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Both should succeed with different positions
      positions = Enum.map(results, fn {:ok, pos} -> pos end)
      assert length(Enum.uniq(positions)) == 2
    end
  end

  describe "WIP limit excludes archived tasks" do
    test "can_add_task? does not count archived tasks toward the WIP limit", %{board: board} do
      col = column_fixture(board, %{wip_limit: 2})

      # Two ARCHIVED work tasks occupy the column (raw count == limit).
      for _ <- 1..2, do: col |> task_fixture() |> archive!()

      # Live count is 0, so a new task can still be added.
      assert Positioning.can_add_task?(col)
    end

    test "move_task into a WIP-limited column ignores archived tasks", %{board: board} do
      src = column_fixture(board, %{name: "Src"})
      dst = column_fixture(board, %{name: "Dst", wip_limit: 2})

      # Two ARCHIVED work tasks in the destination (raw count == limit).
      for _ <- 1..2, do: dst |> task_fixture() |> archive!()

      mover = task_fixture(src)

      # Live count in dst is 0, so the move succeeds.
      assert {:ok, _} = Kanban.Tasks.move_task(mover, dst, 0)
    end

    test "move_task is still rejected when the live count is at the WIP limit", %{board: board} do
      src = column_fixture(board, %{name: "Src2"})
      dst = column_fixture(board, %{name: "Dst2", wip_limit: 1})

      _live = task_fixture(dst)
      mover = task_fixture(src)

      assert {:error, :wip_limit_reached} = Kanban.Tasks.move_task(mover, dst, 0)
    end
  end

  # D357: moves and reorders write with update_all, so updated_at must be
  # stamped explicitly or GET /api/tasks?updated_since= never sees them.
  describe "a drop lands where it was dropped, even with position gaps" do
    # The board sends the drop index among the column's other visible cards.
    # Archiving a card leaves a gap in the column's positions, which used to
    # put the card one place away from where it was dropped.
    defp live_order(column) do
      Kanban.Tasks.Task
      |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
      |> order_by([t], asc: t.position)
      |> select([t], t.id)
      |> Repo.all()
    end

    test "a cross-column drop between two cards lands between them", %{board: board} do
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      [a, gone, b, c] = for _ <- 1..4, do: task_fixture(doing)
      archive!(gone)
      moving = task_fixture(ready)

      # Visible order in Doing is a, b, c; drop between b and c (index 2).
      assert {:ok, _} = Kanban.Tasks.move_task(moving, doing, 2)
      assert live_order(doing) == [a.id, b.id, moving.id, c.id]
    end

    test "a same-column drop lands at the dropped index", %{board: board} do
      ready = column_fixture(board, %{name: "Ready"})
      [a, gone, b, c] = for _ <- 1..4, do: task_fixture(ready)
      archive!(gone)

      # Visible order a, b, c; drag a to the end (index 2 among the others).
      assert {:ok, _} = a |> Repo.reload!() |> Kanban.Tasks.move_task(ready, 2)
      assert live_order(ready) == [b.id, c.id, a.id]
    end

    test "an index past the end appends the card", %{board: board} do
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      [a, b] = for _ <- 1..2, do: task_fixture(doing)
      moving = task_fixture(ready)

      assert {:ok, _} = Kanban.Tasks.move_task(moving, doing, 99)
      assert live_order(doing) == [a.id, b.id, moving.id]
    end
  end

  describe "moves and reorders bump updated_at (D357)" do
    @old ~N[2020-01-01 00:00:00]

    defp age!(tasks) do
      ids = Enum.map(tasks, & &1.id)

      Kanban.Tasks.Task
      |> where([t], t.id in ^ids)
      |> Repo.update_all(set: [updated_at: @old])

      Enum.map(tasks, &Repo.reload!/1)
    end

    defp stamp(task), do: Repo.reload!(task).updated_at
    defp bumped?(task), do: task |> stamp() |> NaiveDateTime.compare(@old) == :gt
    defp position(task), do: Repo.reload!(task).position

    test "cross-column move bumps updated_at on moved task and shifted siblings", %{
      board: board
    } do
      src = column_fixture(board, %{name: "Ready"})
      dst = column_fixture(board, %{name: "Doing"})
      [stay_src, mover, closed_up] = for _ <- 1..3, do: task_fixture(src)
      [stay_dst, shifted] = for _ <- 1..2, do: task_fixture(dst)

      [stay_src, mover, closed_up, stay_dst, shifted] =
        age!([stay_src, mover, closed_up, stay_dst, shifted])

      assert {:ok, moved} = Kanban.Tasks.move_task(mover, dst, 1)

      assert moved.column_id == dst.id
      assert bumped?(mover)
      assert bumped?(closed_up)
      assert bumped?(shifted)
      refute bumped?(stay_src)
      refute bumped?(stay_dst)

      # One UTC value per operation, shared by every row it touched. (Whole
      # seconds are guaranteed by the :naive_datetime column, which truncates on
      # load, so asserting on microseconds here could never fail.)
      stamps = Enum.map([mover, closed_up, shifted], &stamp/1)
      assert [single] = Enum.uniq(stamps)
      assert NaiveDateTime.diff(NaiveDateTime.utc_now(), single) in 0..5
    end

    test "no-op move does not bump updated_at", %{board: board} do
      ready = column_fixture(board, %{name: "Ready"})
      tasks = for _ <- 1..3, do: task_fixture(ready)
      [first, middle, last] = age!(tasks)

      assert {:ok, _} = Kanban.Tasks.move_task(middle, ready, middle.position)

      refute Enum.any?([first, middle, last], &bumped?/1)
    end

    test "first and last position moves bump only the moved task and the shifted range", %{
      board: board
    } do
      ready = column_fixture(board, %{name: "Ready"})
      [a, b, c, d] = age!(for _ <- 1..4, do: task_fixture(ready))

      # c (2) -> first: a and b shift down, d is outside the range.
      assert {:ok, _} = Kanban.Tasks.move_task(c, ready, 0)
      assert Enum.map([c, a, b, d], &position/1) == [0, 1, 2, 3]
      assert Enum.all?([c, a, b], &bumped?/1)
      refute bumped?(d)

      [a, b, c, d] = age!([a, b, c, d])

      # a (1) -> last: b and d shift up, c is outside the range.
      assert {:ok, _} = a |> Repo.reload!() |> Kanban.Tasks.move_task(ready, 3)
      assert Enum.map([c, b, d, a], &position/1) == [0, 1, 2, 3]
      assert Enum.all?([a, b, d], &bumped?/1)
      refute bumped?(c)
    end

    test "reorder skips archived tasks and bumps only live rewritten rows", %{board: board} do
      col = column_fixture(board, %{name: "Ready"})
      [a, b, c] = for _ <- 1..3, do: task_fixture(col)
      archived = col |> task_fixture() |> archive!()
      [a, b, c, archived] = age!([a, b, c, archived])
      archived_position = position(archived)

      # c moves to the top and b keeps position 1; a is not named, so the
      # remaining-positions pass renumbers it to 2. The archived id is named
      # too but must be neither renumbered nor stamped.
      assert :ok = Positioning.reorder_tasks(col, [c.id, b.id, archived.id])

      assert Enum.map([c, b, a], &position/1) == [0, 1, 2]
      assert bumped?(c)
      assert bumped?(a)
      refute bumped?(b)
      refute bumped?(archived)
      assert position(archived) == archived_position
    end

    test "reorder of an empty id list or an archived-only column bumps nothing", %{
      board: board
    } do
      col = column_fixture(board, %{name: "Ready"})
      [a, b] = age!(for _ <- 1..2, do: task_fixture(col))

      assert :ok = Positioning.reorder_tasks(col, [])
      assert Enum.map([a, b], &position/1) == [0, 1]
      refute Enum.any?([a, b], &bumped?/1)

      only_archived = column_fixture(board, %{name: "Archive-only"})
      [gone] = age!([only_archived |> task_fixture() |> archive!()])

      assert :ok = Positioning.reorder_tasks(only_archived, [gone.id])
      refute bumped?(gone)
    end

    test "a blocked task keeps its status and is still bumped", %{board: board} do
      src = column_fixture(board, %{name: "Ready"})
      dst = column_fixture(board, %{name: "Doing"})
      task = task_fixture(src)

      Kanban.Tasks.Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [status: :blocked])

      [task] = age!([task])

      assert {:ok, moved} = Kanban.Tasks.move_task(task, dst, 0)
      assert moved.status == :blocked
      assert bumped?(task)
    end

    test "a WIP-limit refusal writes nothing", %{board: board} do
      src = column_fixture(board, %{name: "Ready"})
      dst = column_fixture(board, %{name: "Doing", wip_limit: 1})
      [mover, occupant] = age!([task_fixture(src), task_fixture(dst)])

      assert {:error, :wip_limit_reached} = Kanban.Tasks.move_task(mover, dst, 0)
      refute Enum.any?([mover, occupant], &bumped?/1)
    end
  end
end
