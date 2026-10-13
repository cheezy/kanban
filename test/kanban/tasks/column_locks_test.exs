defmodule Kanban.Tasks.ColumnLocksTest do
  use Kanban.DataCase

  alias Kanban.ColumnLockHelpers
  alias Kanban.Tasks.ColumnLocks

  describe "lock/1 (D373)" do
    test "locks each column once and returns the ids sorted ascending, skipping nil" do
      before = ColumnLockHelpers.held_column_locks()

      assert ColumnLocks.lock([900_003, nil, 900_001, 900_003, 900_002]) ==
               [900_001, 900_002, 900_003]

      assert ColumnLockHelpers.held_column_locks() -- before == [900_001, 900_002, 900_003]
    end

    test "locks nothing for an empty list" do
      before = ColumnLockHelpers.held_column_locks()

      assert ColumnLocks.lock([]) == []
      assert ColumnLockHelpers.held_column_locks() == before
    end

    test "try_lock/1 takes every free column without waiting and returns true" do
      before = ColumnLockHelpers.held_column_locks()

      assert ColumnLocks.try_lock([900_022, nil, 900_021]) == true
      assert ColumnLockHelpers.held_column_locks() -- before == [900_021, 900_022]
    end

    test "try_lock/1 returns false at once when another session holds a column" do
      holder = ColumnLockHelpers.hold_columns([900_031], 400)

      {waited, locked?} =
        ColumnLockHelpers.timed(fn -> ColumnLocks.try_lock([900_032, 900_031]) end)

      assert locked? == false
      assert waited < 250
      assert {:ok, :held} = Task.await(holder, 10_000)
    end

    test "try_lock/1 succeeds on a column this session already holds" do
      ColumnLocks.lock([900_041])
      assert ColumnLocks.try_lock([900_041]) == true
    end

    test "waits for a column another session holds" do
      holder = ColumnLockHelpers.hold_columns([900_010], 400)

      {waited, locked} = ColumnLockHelpers.timed(fn -> ColumnLocks.lock([900_011, 900_010]) end)

      assert {:ok, :held} = Task.await(holder, 10_000)
      assert locked == [900_010, 900_011]
      assert waited >= 300
    end
  end
end
