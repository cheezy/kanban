defmodule Kanban.Boards.MemberCapLockTest do
  @moduledoc """
  Shows that `Kanban.Boards.add_user_to_board/4` counts a free board's members
  under a row lock that a concurrent add really contends with, using a second,
  real Postgres session (W2400).

  The test sandbox never commits, so a second session cannot see sandboxed
  rows. This module therefore checks out an unsandboxed connection and commits
  its fixtures for real, which is why it is not async. The fixtures are
  inserted straight through `Repo`, so they emit no telemetry, and `on_exit`
  deletes them. The add under test runs inside a transaction the test rolls
  back, so it commits nothing even if a regression let it through.

  It also switches the global `:plans_enforced` application env on.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.PlansHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @hold_ms 300

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    enforce_plans()

    owner = committed_user()
    member = committed_user()
    competitor_user = committed_user()
    newcomer = committed_user()
    {:ok, workspace} = Workspaces.ensure_personal_workspace(owner)

    board =
      Repo.insert!(%Board{
        name: "Cap lock #{System.unique_integer([:positive])}",
        workspace_id: workspace.id
      })

    Repo.insert!(%BoardUser{board_id: board.id, user_id: owner.id, access: :owner})
    Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})

    user_ids = Enum.map([owner, member, competitor_user, newcomer], & &1.id)
    on_exit(fn -> delete_committed(board.id, workspace.id, user_ids) end)

    %{owner: owner, board: board, competitor_user: competitor_user, newcomer: newcomer}
  end

  test "an add racing another add at 2 members leaves the board at 3", ctx do
    # The competing add locks the board row the way add_user_to_board/4 does,
    # inserts the third member and holds its transaction open.
    competitor = hold_third_member(ctx)

    {elapsed_ms, result} = add_and_roll_back(ctx)

    assert {:ok, :committed} = Task.await(competitor)

    # Without the board lock the count would read 2, because the competitor's
    # insert had not committed yet, and the newcomer would become the fourth.
    assert result == {:error, {:error, :member_cap_reached}}
    assert elapsed_ms >= @hold_ms - 50
    assert member_ids(ctx.board.id) |> length() == 3
  end

  defp hold_third_member(ctx) do
    test_pid = self()
    conn = second_session()

    competitor =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM boards WHERE id = $1 FOR UPDATE", [ctx.board.id])

          Postgrex.query!(
            c,
            "INSERT INTO board_users (board_id, user_id, access, inserted_at, updated_at) " <>
              "VALUES ($1, $2, 'modify', now(), now())",
            [ctx.board.id, ctx.competitor_user.id]
          )

          send(test_pid, :competitor_holding)
          Process.sleep(@hold_ms)
          :committed
        end)
      end)

    assert_receive :competitor_holding, 5_000
    competitor
  end

  # Adds the newcomer inside a transaction that is always rolled back,
  # returning the elapsed time and add_user_to_board/4's result wrapped as
  # {:error, result}.
  defp add_and_roll_back(ctx) do
    started = System.monotonic_time(:millisecond)

    result =
      Repo.transaction(fn ->
        Repo.rollback(Boards.add_user_to_board(ctx.board, ctx.newcomer, :modify, ctx.owner))
      end)

    {System.monotonic_time(:millisecond) - started, result}
  end

  defp committed_user do
    Repo.insert!(%User{email: "cap-lock-#{System.unique_integer([:positive])}@example.com"})
  end

  # A raw connection outside the sandbox: a second Postgres session whose row
  # lock really contends with the add's. Linked to the test process, so it
  # closes when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  defp member_ids(board_id) do
    from(bu in BoardUser, where: bu.board_id == ^board_id, select: bu.user_id)
    |> Repo.all()
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(board_id, workspace_id, user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(bu in BoardUser, where: bu.board_id == ^board_id) |> Repo.delete_all()
    from(b in Board, where: b.id == ^board_id) |> Repo.delete_all()
    from(w in Workspace, where: w.id == ^workspace_id) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
