defmodule Kanban.Workspaces.PersonalWorkspaceLockTest do
  @moduledoc """
  Shows that `Kanban.Workspaces.ensure_personal_workspace/1` serializes a
  user's first workspace create under a per-user lock that a concurrent call
  really contends with, so two first board creates both succeed (D382).

  The test sandbox shares one connection, so the race cannot happen inside it.
  This module therefore checks out unsandboxed connections and commits for
  real, which is why it is not async: ExUnit runs it after every async module,
  so no sandboxed test can see its rows. The users are inserted straight
  through `Repo`, so they start with no personal workspace, and `on_exit`
  deletes everything the tests committed.

  The competitor runs the real code path in its own process and connection,
  then holds its transaction open for `@hold_ms` before it commits or rolls
  back.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @hold_ms 300

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    user = committed_user()
    other = committed_user()

    user_ids = [user.id, other.id]
    on_exit(fn -> delete_committed(user_ids) end)

    %{user: user, other: other}
  end

  describe "ensure_personal_workspace/1" do
    test "concurrent first calls both get the same workspace", %{user: user} do
      competitor = hold_in_transaction(fn -> Workspaces.ensure_personal_workspace(user) end)

      {elapsed_ms, result} = timed(fn -> Workspaces.ensure_personal_workspace(user) end)

      assert {:ok, {:ok, %Workspace{id: held_id}}} = Task.await(competitor)

      # Without the lock this call reads no workspace, because the
      # competitor's had not committed, and its owner row then fails with
      # "already owns a workspace".
      assert {:ok, %Workspace{id: ^held_id, personal: true}} = result
      assert elapsed_ms >= @hold_ms - 50
      assert owned_workspace_ids(user) == [held_id]
    end

    test "a waiting call creates the workspace when the holder rolls back", %{user: user} do
      competitor =
        hold_in_transaction(fn -> Workspaces.ensure_personal_workspace(user) end, :rollback)

      {elapsed_ms, result} = timed(fn -> Workspaces.ensure_personal_workspace(user) end)

      assert {:error, {:ok, %Workspace{id: rolled_back_id}}} = Task.await(competitor)

      # The lock is transaction-scoped: a holder that never commits releases
      # it at rollback, and the waiting call creates the workspace itself.
      assert {:ok, %Workspace{id: id}} = result
      assert id != rolled_back_id
      assert elapsed_ms >= @hold_ms - 50
      assert owned_workspace_ids(user) == [id]
    end

    test "a lock for one user does not block another user", %{user: user, other: other} do
      competitor = hold_in_transaction(fn -> Workspaces.ensure_personal_workspace(user) end)

      # A wait longer than lock_timeout raises instead of returning, so a lock
      # wider than the user's own row fails this test.
      {elapsed_ms, result} =
        timed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL lock_timeout = '100ms'", [])
            Workspaces.ensure_personal_workspace(other)
          end)
        end)

      assert {:ok, {:ok, %Workspace{}}} = Task.await(competitor)
      assert {:ok, {:ok, %Workspace{id: other_id}}} = result
      assert elapsed_ms < @hold_ms
      assert owned_workspace_ids(other) == [other_id]
    end
  end

  describe "Boards.create_board/2" do
    test "concurrent first board creates both succeed", %{user: user} do
      competitor =
        hold_in_transaction(fn -> Boards.create_board(user, %{name: "First tab"}) end)

      {elapsed_ms, result} = timed(fn -> Boards.create_board(user, %{name: "Second tab"}) end)

      assert {:ok, {:ok, %Board{} = first}} = Task.await(competitor)

      # Without the lock this create fails with "already owns a workspace".
      assert {:ok, %Board{} = second} = result
      assert elapsed_ms >= @hold_ms - 50
      assert first.workspace_id == second.workspace_id
      assert owned_workspace_ids(user) == [first.workspace_id]
    end
  end

  # Runs `fun` in a separate process on its own unsandboxed connection, inside
  # a transaction held open for @hold_ms before it commits (or, with
  # :rollback, rolls back). Returns once `fun` has run, with the task to
  # await; the task returns Repo.transaction/1's result.
  defp hold_in_transaction(fun, finish \\ :commit) do
    test_pid = self()

    competitor =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          result = fun.()
          send(test_pid, :competitor_holding)
          Process.sleep(@hold_ms)
          finish_transaction(result, finish)
        end)
      end)

    assert_receive :competitor_holding, 5_000
    competitor
  end

  defp finish_transaction(result, :commit), do: result
  defp finish_transaction(result, :rollback), do: Repo.rollback(result)

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp committed_user do
    Repo.insert!(%User{email: "ws-lock-#{System.unique_integer([:positive])}@example.com"})
  end

  defp owned_workspace_ids(%User{id: user_id}) do
    from(m in WorkspaceMember,
      where: m.user_id == ^user_id and m.role == ^:owner,
      select: m.workspace_id
    )
    |> Repo.all()
  end

  # on_exit runs in its own process, which needs its own connection. Boards
  # go first because they restrict workspace deletes; board_users and
  # workspace_members cascade.
  defp delete_committed(user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    workspace_ids =
      from(m in WorkspaceMember,
        where: m.user_id in ^user_ids and m.role == ^:owner,
        select: m.workspace_id
      )
      |> Repo.all()

    from(b in Board, where: b.workspace_id in ^workspace_ids) |> Repo.delete_all()
    from(w in Workspace, where: w.id in ^workspace_ids) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
