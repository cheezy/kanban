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

  describe "wip_count/1 and move_task_unchecked/3 (W2238 bulk move)" do
    test "wip_count counts live work and defect tasks only", %{board: board} do
      col = column_fixture(board, %{name: "Counted"})
      task_fixture(col)
      task_fixture(col, %{type: :defect})
      task_fixture(col, %{type: :goal, title: "Goal"})
      col |> task_fixture() |> archive!()

      assert Positioning.wip_count(col) == 2
    end

    test "move_task_unchecked ignores the WIP limit and does not broadcast", %{board: board} do
      src = column_fixture(board, %{name: "From"})
      dst = column_fixture(board, %{name: "Full", wip_limit: 1})
      occupant = task_fixture(dst)
      mover = task_fixture(src)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      assert {:ok, moved} = Positioning.move_task_unchecked(mover, dst, 1)
      assert moved.column_id == dst.id
      assert moved.position == 1
      assert Repo.get!(Kanban.Tasks.Task, occupant.id).position == 0
      refute_receive {Kanban.Tasks, _event, _task}, 50
    end
  end

  describe "a move with a stale task struct (W2238)" do
    test "renumbers the column the task is in now, not the one it was loaded from", %{
      board: board
    } do
      from_col = column_fixture(board, %{name: "Loaded in"})
      moved_to = column_fixture(board, %{name: "Moved to"})
      dropped_on = column_fixture(board, %{name: "Dropped on"})
      task = task_fixture(from_col)
      _sibling = task_fixture(from_col)
      resident = task_fixture(moved_to)
      stale = Repo.get!(Kanban.Tasks.Task, task.id)

      # Another move commits first (as a bulk move does while a drag waits on
      # the column locks), then the drag applies with the struct it loaded.
      assert {:ok, _} = Kanban.Tasks.move_task(task, moved_to, 0)
      assert {:ok, moved} = Kanban.Tasks.move_task(stale, dropped_on, 0)

      assert moved.column_id == dropped_on.id
      assert positions_of(moved_to) == [{resident.id, 0}]
      assert from_col |> positions_of() |> Enum.map(&elem(&1, 1)) == [0]
    end

    defp positions_of(column) do
      Kanban.Tasks.Task
      |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
      |> order_by([t], asc: t.position)
      |> select([t], {t.id, t.position})
      |> Repo.all()
    end
  end

  describe "lock order and concurrent column changes (D368)" do
    setup do
      original = Application.get_env(:kanban, Positioning)
      on_exit(fn -> restore_env(original) end)
    end

    defp restore_env(nil), do: Application.delete_env(:kanban, Positioning)
    defp restore_env(original), do: Application.put_env(:kanban, Positioning, original)

    # Moves the task the way a concurrent mover would, without taking any
    # advisory lock. Position 90 + n keeps clear of the column's own tasks.
    defp relocate!(task_id, column_id, position \\ 90) do
      Kanban.Tasks.Task
      |> where([t], t.id == ^task_id)
      |> Repo.update_all(set: [column_id: column_id, position: position])
    end

    # A raw connection outside the test sandbox: a second Postgres session,
    # so its advisory locks really contend with the move's.
    defp second_session do
      config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
      # Linked to the test process, so it closes when the test ends.
      {:ok, conn} = Postgrex.start_link(config)
      conn
    end

    test "perform_move locks stale, current and target columns in one ascending pass when the task moved meanwhile",
         %{board: board} do
      # The fixture's insert locks the column it creates the task in for the
      # rest of the test (the sandbox never commits), so it gets a column of
      # its own that the second session never touches.
      created_in = column_fixture(board, %{name: "Created in"})
      current = column_fixture(board, %{name: "Current"})
      stale_col = column_fixture(board, %{name: "Stale"})
      target = column_fixture(board, %{name: "Target"})
      assert current.id < stale_col.id and stale_col.id < target.id

      task = task_fixture(created_in)
      relocate!(task.id, current.id, 0)
      # The mover's struct says Stale; the task really sits in Current.
      stale = %{Repo.get!(Kanban.Tasks.Task, task.id) | column_id: stale_col.id}

      conn = second_session()
      test_pid = self()

      # Like a bulk move: hold the lowest column, then (once the move has had
      # time to take whatever it takes first) ask for a higher one. A move
      # that locks Stale and Target before Current deadlocks with this.
      locker =
        Task.async(fn ->
          Postgrex.transaction(conn, fn c ->
            Postgrex.query!(c, "SELECT pg_advisory_xact_lock($1)", [current.id])
            send(test_pid, :current_locked)
            Process.sleep(300)
            Postgrex.query(c, "SELECT pg_advisory_xact_lock($1)", [stale_col.id])
          end)
        end)

      assert_receive :current_locked, 5_000

      assert {:ok, moved} = Positioning.move_task(stale, target, 0)
      assert {:ok, {:ok, %Postgrex.Result{}}} = Task.await(locker, 10_000)

      assert moved.column_id == target.id
      assert moved.position == 0
      assert live_order(current) == []
    end

    test "a child move also locks its parent goal's columns, in the same ascending pass",
         %{board: board} do
      # As in the test above, everything is created in a column the second
      # session never touches, then placed without locks.
      created_in = column_fixture(board, %{name: "Goal created in"})
      leftmost = column_fixture(board, %{name: "Leftmost child"})
      from_col = column_fixture(board, %{name: "Mover from"})
      to_col = column_fixture(board, %{name: "Mover to"})

      goal = task_fixture(created_in, %{title: "Goal", type: :goal})
      child = task_fixture(created_in, %{title: "Child", parent_id: goal.id})
      mover = task_fixture(created_in, %{title: "Mover", parent_id: goal.id})
      relocate!(goal.id, to_col.id, 0)
      relocate!(child.id, leftmost.id, 0)
      relocate!(mover.id, from_col.id, 0)
      mover = Repo.get!(Kanban.Tasks.Task, mover.id)

      # The goal is re-placed into its leftmost child column, which is none of
      # the mover's own columns: a drag holding it must make the move wait
      # rather than have the goal's rows written under it.
      conn = second_session()
      test_pid = self()

      holder =
        Task.async(fn ->
          Postgrex.transaction(conn, fn c ->
            Postgrex.query!(c, "SELECT pg_advisory_xact_lock($1)", [leftmost.id])
            send(test_pid, :leftmost_locked)
            Process.sleep(400)
          end)
        end)

      assert_receive :leftmost_locked, 5_000
      started = System.monotonic_time(:millisecond)
      assert {:ok, moved} = Positioning.move_task(mover, to_col, 0)
      waited = System.monotonic_time(:millisecond) - started
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert waited >= 300
      assert moved.column_id == to_col.id
      assert Repo.get!(Kanban.Tasks.Task, goal.id).column_id == leftmost.id
    end

    test "a move whose parent goal gains a child column meanwhile is retried",
         %{board: board} do
      col_a = column_fixture(board, %{name: "Goal A"})
      col_b = column_fixture(board, %{name: "Goal B"})
      col_new = column_fixture(board, %{name: "New child column"})
      goal = task_fixture(col_a, %{title: "Goal", type: :goal})
      mover = task_fixture(col_a, %{title: "Mover", parent_id: goal.id})
      sibling = task_fixture(col_a, %{title: "Sibling", parent_id: goal.id})
      calls = :counters.new(1, [])

      Application.put_env(:kanban, Positioning,
        after_column_read: fn _task_id ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: relocate!(sibling.id, col_new.id)
        end
      )

      assert {:ok, moved} = Positioning.move_task(mover, col_b, 0)
      assert :counters.get(calls, 1) == 2
      assert moved.column_id == col_b.id
    end

    test "a task moved once between the read and the locks is retried and lands where it was dropped",
         %{board: board} do
      src = column_fixture(board, %{name: "Src"})
      other = column_fixture(board, %{name: "Other"})
      dst = column_fixture(board, %{name: "Dst"})
      task = task_fixture(src)
      _left_behind = task_fixture(src)
      resident = task_fixture(dst)
      calls = :counters.new(1, [])

      Application.put_env(:kanban, Positioning,
        after_column_read: fn task_id ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: relocate!(task_id, other.id)
        end
      )

      assert {:ok, moved} = Positioning.move_task(task, dst, 0)
      assert :counters.get(calls, 1) == 2

      assert moved.column_id == dst.id
      assert live_order(dst) == [task.id, resident.id]
      assert Repo.get!(Kanban.Tasks.Task, resident.id).position == 1
      assert live_order(other) == []
    end

    test "a move whose task keeps changing column returns {:error, :conflict} after the retry cap",
         %{board: board} do
      a = column_fixture(board, %{name: "A"})
      b = column_fixture(board, %{name: "B"})
      dst = column_fixture(board, %{name: "Dst"})
      task = task_fixture(a)
      calls = :counters.new(1, [])

      Application.put_env(:kanban, Positioning,
        after_column_read: fn task_id ->
          :counters.add(calls, 1, 1)
          n = :counters.get(calls, 1)
          relocate!(task_id, if(rem(n, 2) == 1, do: b.id, else: a.id), 90 + n)
        end
      )

      assert {:error, :conflict} = Positioning.move_task(task, dst, 0)
      assert :counters.get(calls, 1) == 3
      assert live_order(dst) == []
      assert Repo.get!(Kanban.Tasks.Task, task.id).column_id == b.id
    end

    test "max_move_attempts sets the retry cap", %{board: board} do
      a = column_fixture(board, %{name: "A2"})
      b = column_fixture(board, %{name: "B2"})
      dst = column_fixture(board, %{name: "Dst2"})
      task = task_fixture(a)
      calls = :counters.new(1, [])

      Application.put_env(:kanban, Positioning,
        max_move_attempts: 1,
        after_column_read: fn task_id ->
          :counters.add(calls, 1, 1)
          relocate!(task_id, b.id)
        end
      )

      assert {:error, :conflict} = Positioning.move_task(task, dst, 0)
      assert :counters.get(calls, 1) == 1
    end

    test "concurrent BulkActions.move and Positioning.move_task over overlapping columns (sandbox shared mode, Task.async) complete without deadlock_detected and leave contiguous positions",
         %{user: user, board: board} do
      # The shared sandbox serialises the two through one connection, so this
      # guards the outcome (no exception, no position gaps); the
      # second-session test above is the one that exercises the lock order.
      todo = column_fixture(board, %{name: "Todo"})
      doing = column_fixture(board, %{name: "Doing"})
      done = column_fixture(board, %{name: "Done"})
      bulk_ids = for _ <- 1..3, do: task_fixture(todo).id
      dragged = task_fixture(doing)
      _stays = task_fixture(doing)
      scope = user_scope_fixture(user)

      results =
        [
          Task.async(fn -> Kanban.Tasks.BulkActions.move(scope, board, bulk_ids, done.id) end),
          Task.async(fn -> Positioning.move_task(dragged, todo, 0) end)
        ]
        |> Task.await_many(10_000)

      assert [{:ok, %{count: 3}}, {:ok, _moved}] = results

      for column <- [todo, doing, done] do
        count = length(live_order(column))

        assert column |> positions_of() |> Enum.map(&elem(&1, 1)) ==
                 Enum.to_list(0..(count - 1)//1)
      end

      assert hd(live_order(todo)) == dragged.id
    end

    test "a task deleted while the move waits on the locks raises Ecto.NoResultsError, as before D368",
         %{board: board} do
      src = column_fixture(board, %{name: "Del src"})
      dst = column_fixture(board, %{name: "Del dst"})
      task = task_fixture(src)

      Application.put_env(:kanban, Positioning,
        after_column_read: fn task_id ->
          Repo.delete_all(where(Kanban.Tasks.Task, [t], t.id == ^task_id))
        end
      )

      assert_raise Ecto.NoResultsError, fn -> Positioning.move_task(task, dst, 0) end
      assert live_order(dst) == []
    end

    test "a task archived while the move waits on the locks is still moved, as before D368",
         %{board: board} do
      src = column_fixture(board, %{name: "Arch src"})
      dst = column_fixture(board, %{name: "Arch dst"})
      task = task_fixture(src)

      Application.put_env(:kanban, Positioning,
        after_column_read: fn task_id -> archive!(%{id: task_id}) end
      )

      # Archiving does not change the column, so the re-read under the locks
      # matches and the move goes ahead on the archived task.
      assert {:ok, moved} = Positioning.move_task(task, dst, 0)
      assert moved.column_id == dst.id
      refute is_nil(moved.archived_at)
    end

    test "a move whose stale, current and target column are the same reorders in place",
         %{board: board} do
      col = column_fixture(board, %{name: "Same"})
      first = task_fixture(col)
      second = task_fixture(col)

      assert {:ok, moved} = Positioning.move_task(second, col, 0)
      assert moved.position == 0
      assert live_order(col) == [second.id, first.id]
    end
  end

  describe "a child move that re-places its parent goal (D372)" do
    # Everything is created in one column, so creating the child (which
    # re-places its goal) cannot disturb the layout, then placed directly.
    defp place!(task, column, position) do
      Kanban.Tasks.Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [column_id: column.id, position: position, updated_at: @old])

      Repo.reload!(task)
    end

    defp live_positions(column) do
      Kanban.Tasks.Task
      |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
      |> order_by([t], asc: t.position)
      |> select([t], {t.id, t.position})
      |> Repo.all()
    end

    test "a child move that re-places its parent goal leaves every touched column contiguous",
         %{board: board} do
      created_in = column_fixture(board, %{name: "Created in"})
      goal_col = column_fixture(board, %{name: "Goal column"})
      from_col = column_fixture(board, %{name: "Mover from"})
      to_col = column_fixture(board, %{name: "Mover to"})

      goal = task_fixture(created_in, %{title: "Goal", type: :goal})
      mover = task_fixture(created_in, %{title: "Mover", parent_id: goal.id})
      above = task_fixture(created_in, %{title: "Above goal"})
      below = task_fixture(created_in, %{title: "Below goal"})
      left_behind = task_fixture(created_in, %{title: "Left behind"})
      resident = task_fixture(created_in, %{title: "Resident"})

      above = place!(above, goal_col, 0)
      goal = place!(goal, goal_col, 1)
      below = place!(below, goal_col, 2)
      mover = place!(mover, from_col, 0)
      left_behind = place!(left_behind, from_col, 1)
      resident = place!(resident, to_col, 0)

      assert {:ok, moved} = Positioning.move_task(mover, to_col, 0)

      # The goal follows its only child into the target column, ahead of it.
      assert live_positions(to_col) == [{goal.id, 0}, {moved.id, 1}, {resident.id, 2}]
      assert live_positions(goal_col) == [{above.id, 0}, {below.id, 1}]
      assert live_positions(from_col) == [{left_behind.id, 0}]
      assert live_positions(created_in) == []

      assert Repo.reload!(above).updated_at == @old
      assert Repo.reload!(below).updated_at == Repo.reload!(moved).updated_at
    end

    test "a child move that leaves its parent goal in its column renumbers nothing for the goal",
         %{board: board} do
      created_in = column_fixture(board, %{name: "Created in"})
      goal_col = column_fixture(board, %{name: "Goal column"})
      to_col = column_fixture(board, %{name: "Mover to"})

      goal = task_fixture(created_in, %{title: "Goal", type: :goal})
      staying = task_fixture(created_in, %{title: "Staying child", parent_id: goal.id})
      mover = task_fixture(created_in, %{title: "Mover", parent_id: goal.id})

      goal = place!(goal, goal_col, 0)
      staying = place!(staying, goal_col, 1)
      mover = place!(mover, goal_col, 2)

      assert {:ok, moved} = Positioning.move_task(mover, to_col, 0)

      # The staying child keeps the goal in its leftmost child column.
      assert live_positions(goal_col) == [{goal.id, 0}, {staying.id, 1}]
      assert live_positions(to_col) == [{moved.id, 0}]
      assert Repo.reload!(goal).updated_at == @old
      assert Repo.reload!(staying).updated_at == @old
    end
  end
end
