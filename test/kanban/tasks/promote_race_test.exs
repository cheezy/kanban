defmodule Kanban.Tasks.PromoteRaceTest do
  @moduledoc """
  Shows that `Kanban.Tasks.promote_to_ready/4` waits for a concurrent move of
  the same task and then sees it, using real, separate Postgres sessions: a
  second session takes the board's column locks and the task's row lock, as
  a move (or another promote) does, and moves the task to Ready; the promote
  started meanwhile waits on the column locks, then reads the task under its
  own row lock, finds it already in Ready and reports it in `already_ready`
  instead of moving it again or failing with a conflict.

  The test sandbox never commits, so a second session cannot see sandboxed
  rows. This module therefore checks out unsandboxed connections and commits
  its fixtures for real, which is why it is not async. The fixtures are
  inserted straight through `Repo`, so they write no audit row, and `on_exit`
  deletes them. The concurrent move is raw SQL that takes the move's locks
  and commits; the promote runs inside a transaction that is always rolled
  back, so it commits nothing.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Workspaces.Workspace

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    uniq = System.unique_integer([:positive])
    # Registered before the first insert, so a setup that fails part-way
    # still deletes whatever it committed.
    on_exit(fn -> delete_committed(uniq) end)
    user = Repo.insert!(%User{email: "promote-race-#{uniq}@example.com"})

    workspace =
      Repo.insert!(%Workspace{
        name: "Promote race #{uniq}",
        slug: "promote-race-#{uniq}",
        personal: true
      })

    board = Repo.insert!(%Board{name: "Promote race #{uniq}", workspace_id: workspace.id})
    Repo.insert!(%BoardUser{board_id: board.id, user_id: user.id, access: :owner})
    backlog = Repo.insert!(%Column{board_id: board.id, name: "Backlog", position: 0})
    ready = Repo.insert!(%Column{board_id: board.id, name: "Ready", position: 1})

    task =
      Repo.insert!(%Tasks.Task{
        title: "Promote race",
        column_id: backlog.id,
        position: 0,
        type: :work
      })

    %{user: user, board: board, backlog: backlog, ready: ready, task: task}
  end

  test "a promote waiting on a concurrent move of the same task reports it already in Ready",
       ctx do
    mover = hold_move_locks(ctx)
    await_lock_waiters(0)

    promote = start_promote(ctx)
    await_lock_waiters(1)

    send(mover.pid, :proceed)
    assert Task.await(mover) == :moved

    assert {:error, {:ok, %{promoted: [], already_ready: [task_id]}}} = Task.await(promote)
    assert task_id == ctx.task.id
    assert Repo.get!(Tasks.Task, ctx.task.id).column_id == ctx.ready.id
  end

  # A second session that takes the board's column locks in ascending order
  # and the task's row lock, as a move does, holds them until told to proceed,
  # then moves the task to Ready and commits.
  defp hold_move_locks(ctx) do
    test_pid = self()
    conn = second_session()

    mover =
      Task.async(fn ->
        guard(fn ->
          {:ok, result} = Postgrex.transaction(conn, &lock_then_move(&1, ctx, test_pid))
          result
        end)
      end)

    assert_receive :holding, 5_000
    mover
  end

  defp lock_then_move(c, ctx, test_pid) do
    Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])

    for id <- Enum.sort([ctx.backlog.id, ctx.ready.id]) do
      Postgrex.query!(c, "SELECT pg_advisory_xact_lock($1)", [id])
    end

    Postgrex.query!(c, "SELECT id FROM tasks WHERE id = $1 FOR UPDATE", [ctx.task.id])
    send(test_pid, :holding)
    receive do: (:proceed -> move_to_ready(c, ctx))
  end

  defp move_to_ready(c, ctx) do
    Postgrex.query!(c, "UPDATE tasks SET column_id = $1, position = 0 WHERE id = $2", [
      ctx.ready.id,
      ctx.task.id
    ])

    :moved
  end

  # The real promote, in a transaction that is always rolled back, returning
  # its result as {:error, result}.
  defp start_promote(ctx) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")

          ctx.user
          |> Scope.for_user()
          |> Tasks.promote_to_ready(ctx.board, [ctx.task.id])
          |> Repo.rollback()
        end)
      end)
    end)
  end

  # A lock timeout surfaces as a Postgrex.Error from the waiting session; it is
  # returned so the assertions show it.
  defp guard(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:raised, error.postgres && error.postgres.code}
  end

  defp await_lock_waiters(expected, attempts \\ 500)

  defp await_lock_waiters(expected, 0),
    do: flunk("expected #{expected} sessions waiting on a lock, saw #{lock_waiters()}")

  defp await_lock_waiters(expected, attempts) do
    if lock_waiters() == expected do
      :ok
    else
      Process.sleep(10)
      await_lock_waiters(expected, attempts - 1)
    end
  end

  defp lock_waiters do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    count
  end

  # A raw connection outside the sandbox: another Postgres session whose locks
  # really contend with the promote's. Linked to the test process, so it closes
  # when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  # on_exit runs in its own process, which needs its own connection. Every
  # fixture is found by this test's unique name, so nothing it did not commit
  # is touched.
  defp delete_committed(uniq) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    board_ids = from(b in Board, where: b.name == ^"Promote race #{uniq}", select: b.id)
    column_ids = from(c in Column, where: c.board_id in subquery(board_ids), select: c.id)
    from(t in Tasks.Task, where: t.column_id in subquery(column_ids)) |> Repo.delete_all()
    from(c in Column, where: c.board_id in subquery(board_ids)) |> Repo.delete_all()
    from(b in BoardUser, where: b.board_id in subquery(board_ids)) |> Repo.delete_all()
    from(b in Board, where: b.name == ^"Promote race #{uniq}") |> Repo.delete_all()
    from(w in Workspace, where: w.slug == ^"promote-race-#{uniq}") |> Repo.delete_all()
    from(u in User, where: u.email == ^"promote-race-#{uniq}@example.com") |> Repo.delete_all()
  end
end
