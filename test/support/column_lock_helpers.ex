defmodule Kanban.ColumnLockHelpers do
  @moduledoc """
  Helpers for tests that check which column advisory locks a code path takes
  (D373). The D368 tests in `test/kanban/tasks/positioning_test.exs` predate
  this module and keep their own private `relocate!/3` and `second_session/0`.

  The test sandbox never commits, so a second session cannot see the test's
  rows. It can still contend for the same `pg_advisory_xact_lock` ids, which
  is how these helpers show that a path waits for a column another writer
  holds. A lock the test process takes is held until the test ends, so tasks
  are created in a column the second session never touches.
  """

  import Ecto.Query

  alias Kanban.Repo

  @doc """
  Moves a task to `column_id` the way a concurrent writer would, without
  taking any advisory lock. Position 90 keeps clear of the column's own tasks.
  """
  def relocate!(task_id, column_id, position \\ 90) do
    Kanban.Tasks.Task
    |> where([t], t.id == ^task_id)
    |> Repo.update_all(set: [column_id: column_id, position: position])
  end

  @doc """
  Opens a raw connection outside the sandbox: a second Postgres session whose
  advisory locks really contend with the test's. Linked to the caller, so it
  closes when the test ends.
  """
  def second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  @doc """
  Holds the advisory locks for `column_ids` in a second session for
  `hold_ms`, returning the holder once the locks are taken. `then_lock`
  names a column the holder asks for after the hold, with a two-second
  `lock_timeout`, so a path that took that column first makes the holder
  fail instead of hang. Await the holder with `Task.await/2`: it returns
  `{:ok, result}` from `Postgrex.transaction/2`.
  """
  def hold_columns(column_ids, hold_ms, then_lock \\ nil) do
    conn = second_session()
    test_pid = self()
    ref = make_ref()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          lock_in_session(c, column_ids)
          send(test_pid, {:locked, ref})
          Process.sleep(hold_ms)
          lock_after_hold(c, then_lock)
        end)
      end)

    receive do
      {:locked, ^ref} -> holder
    after
      5_000 -> raise "the second session could not take its column locks"
    end
  end

  defp lock_in_session(conn, column_ids) do
    Postgrex.query!(conn, "SET LOCAL lock_timeout = '2s'", [])

    column_ids
    |> Enum.sort()
    |> Enum.each(&Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [&1]))
  end

  defp lock_after_hold(_conn, nil), do: :held

  defp lock_after_hold(conn, column_id),
    do: Postgrex.query(conn, "SELECT pg_advisory_xact_lock($1)", [column_id])

  @doc """
  The column ids whose advisory lock the test's own connection holds, sorted.
  The sandbox never commits, so every lock a call took is still held when it
  returns: diffing this before and after a call shows exactly what it locked.
  """
  def held_column_locks do
    %{rows: rows} =
      Repo.query!(
        "SELECT objid::bigint FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()",
        []
      )

    rows |> List.flatten() |> Enum.sort()
  end

  @doc """
  Runs `fun` and returns `{elapsed_ms, result}`.
  """
  def timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end
end
