defmodule Kanban.Accounts.AccountDeletionMintLockTest do
  @moduledoc """
  Shows that an org-admin deleting their own account
  (`Kanban.Accounts.delete_own_account/3`) and a token being minted for them
  at the same moment take their locks in the same order (the Organization
  row, then the user row), so the mint waits for the deletion instead of
  deadlocking, using real, separate Postgres sessions.

  A mint locks the Organization row and then, through the new token's
  foreign key, takes `FOR KEY SHARE` on the user row. The deletion used to
  lock the user row first and the Organization row last (its last-org-admin
  check), so a mint that held the Organization lock while waiting for the
  user row deadlocked against it, and Postgres aborted one with `40P01`.

  The interleaving is made deterministic by a third session that holds the
  personal board the deletion locks after the user row. The deletion starts
  and blocks there, then the mint starts and blocks, and `pg_stat_activity`
  confirms each is waiting before the board is released.

  The test sandbox never commits, so these sessions cannot see sandboxed rows.
  This module therefore checks out unsandboxed connections and commits its
  fixtures for real, which is why it is not async. The fixtures are inserted
  straight through `Repo`, so they emit no telemetry and write no audit row,
  and `on_exit` deletes them. The deletion and the mint each run inside a
  transaction that is always rolled back, so neither commits an audit row,
  which could never be deleted.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @password "hello world!"

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    user = committed_user(Bcrypt.hash_pwd_salt(@password))
    other_admin = committed_user(nil)
    owner = committed_user(nil)
    organization = organization_fixture()
    organization_member_fixture(organization, user, :org_admin)
    organization_member_fixture(organization, other_admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    {:ok, personal} = Workspaces.ensure_personal_workspace(user)

    personal_board = committed_board(personal, user)
    org_board = committed_board(workspace, owner)

    user_ids = Enum.map([user, other_admin, owner], & &1.id)
    board_ids = [personal_board.id, org_board.id]
    workspace_ids = [personal.id, workspace.id]

    on_exit(fn -> delete_committed(organization.id, workspace_ids, board_ids, user_ids) end)

    %{
      user: user,
      workspace: workspace,
      personal_board: personal_board,
      org_board: org_board
    }
  end

  test "a board token minted while the org-admin deletes their account waits, without a deadlock",
       ctx do
    assert_mint_waits(ctx, fn ->
      ApiTokens.create_api_token_for_member(ctx.user, ctx.org_board, %{name: "Agent"})
    end)
  end

  test "a workspace token minted while the org-admin deletes their account waits, without a deadlock",
       ctx do
    assert_mint_waits(ctx, fn ->
      ApiTokens.create_workspace_api_token(ctx.user, ctx.workspace, %{name: "Agent"})
    end)
  end

  defp assert_mint_waits(ctx, mint_fun) do
    holder = hold_personal_board(ctx)
    await_lock_waiters(0)

    deletion = start_deletion(ctx)
    await_lock_waiters(1)
    mint = start_rolled_back(mint_fun)
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert Task.await(holder) == {:ok, :released}

    # The deletion ran to the end while the mint kept waiting for the
    # Organization lock, so the mint held nothing the deletion needed.
    assert_receive {:deletion_done, {:ok, %{user: %User{}}}}, 5_000
    await_lock_waiters(1)

    send(deletion.pid, :finish)
    assert Task.await(deletion) == {:error, :rolled_back}

    # The deletion was rolled back, so the user could still mint; the mint's
    # own transaction was rolled back as well.
    assert {:error, {:ok, {%ApiToken{}, _plain}}} = Task.await(mint)
    assert live_tokens(ctx.user) == []
  end

  # A second session that locks the user's personal board FOR UPDATE, which
  # the deletion locks after the user row, and holds it until told to proceed.
  defp hold_personal_board(ctx) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        guard(fn ->
          Postgrex.transaction(conn, fn c ->
            Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])

            Postgrex.query!(c, "SELECT id FROM boards WHERE id = $1 FOR UPDATE", [
              ctx.personal_board.id
            ])

            send(test_pid, :holding)
            receive do: (:proceed -> :released)
          end)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  # The real deletion, in a transaction that waits for :finish and is then
  # rolled back, so it commits nothing.
  defp start_deletion(ctx) do
    test_pid = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")

          result =
            ctx.user
            |> Scope.for_user()
            |> Accounts.delete_own_account(@password, "delete my account")

          send(test_pid, {:deletion_done, result})
          receive do: (:finish -> Repo.rollback(:rolled_back))
        end)
      end)
    end)
  end

  # Runs `fun` in a transaction that is always rolled back, returning its
  # result as {:error, result}.
  defp start_rolled_back(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          Repo.rollback(fun.())
        end)
      end)
    end)
  end

  # A deadlock surfaces as a Postgrex.Error (40P01) from whichever session
  # Postgres aborts; it is returned so the assertions show it.
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

  defp live_tokens(user) do
    from(t in ApiToken, where: t.user_id == ^user.id and is_nil(t.revoked_at)) |> Repo.all()
  end

  defp committed_user(hashed_password) do
    Repo.insert!(%User{
      email: "deletion-lock-#{System.unique_integer([:positive])}@example.com",
      hashed_password: hashed_password
    })
  end

  defp committed_board(workspace, owner) do
    board =
      Repo.insert!(%Board{
        name: "Deletion lock #{System.unique_integer([:positive])}",
        workspace_id: workspace.id
      })

    Repo.insert!(%BoardUser{board_id: board.id, user_id: owner.id, access: :owner})
    board
  end

  # A raw connection outside the sandbox: another Postgres session whose row
  # locks really contend with the others'. Linked to the test process, so it
  # closes when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(organization_id, workspace_ids, board_ids, user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(t in ApiToken, where: t.user_id in ^user_ids) |> Repo.delete_all()
    from(bu in BoardUser, where: bu.board_id in ^board_ids) |> Repo.delete_all()
    from(b in Board, where: b.id in ^board_ids) |> Repo.delete_all()
    from(m in WorkspaceMember, where: m.workspace_id in ^workspace_ids) |> Repo.delete_all()
    from(w in Workspace, where: w.id in ^workspace_ids) |> Repo.delete_all()

    from(m in OrganizationMember, where: m.organization_id == ^organization_id)
    |> Repo.delete_all()

    from(o in Organization, where: o.id == ^organization_id) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
