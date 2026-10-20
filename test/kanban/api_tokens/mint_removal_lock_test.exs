defmodule Kanban.ApiTokens.MintRemovalLockTest do
  @moduledoc """
  Shows that `Kanban.ApiTokens.create_api_token_for_member/3` and an
  Organization member's removal take their locks in the same order (the
  Organization row, then the `board_users` row), so a mint that interleaves
  with a removal waits for it instead of deadlocking, using real, separate
  Postgres sessions.

  The interleaving is made deterministic by holding the Organization row lock
  in a third session, starting the removal (which queues behind it), then the
  mint, and waiting in `pg_stat_activity` until each is blocked before going
  on. With the mint locking `board_users` first, the released removal would
  wait for the mint's row lock while the mint waited for the removal's
  Organization lock, and Postgres would abort one of them with `40P01`.

  The test sandbox never commits, so these sessions cannot see sandboxed rows.
  This module therefore checks out unsandboxed connections and commits its
  fixtures for real, which is why it is not async. The fixtures are inserted
  straight through `Repo`, so they emit no telemetry and write no audit row,
  and `on_exit` deletes them. The real removal and the mint each run inside a
  transaction that is always rolled back, so neither commits an audit row,
  which could never be deleted. The committed removal is written as raw SQL
  that takes the removal's locks in the removal's order.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    org_admin = committed_user()
    member = committed_user()
    owner = committed_user()
    organization = organization_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    organization_member_fixture(organization, member, :member)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, member, :member)

    board =
      Repo.insert!(%Board{
        name: "Mint lock #{System.unique_integer([:positive])}",
        workspace_id: workspace.id
      })

    Repo.insert!(%BoardUser{board_id: board.id, user_id: owner.id, access: :owner})
    Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})

    user_ids = Enum.map([org_admin, member, owner], & &1.id)
    on_exit(fn -> delete_committed(organization.id, workspace.id, board.id, user_ids) end)

    %{org_admin: org_admin, member: member, organization: organization, board: board}
  end

  test "a mint started behind a waiting member removal waits for it, without a deadlock",
       ctx do
    holder = hold_organization_lock(ctx, fn _conn -> :released end)
    await_lock_waiters(0)

    removal = start_removal(ctx)
    await_lock_waiters(1)
    mint = start_mint(ctx)
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert Task.await(holder) == {:ok, :released}

    # The removal ran to the end while the mint kept waiting for the
    # Organization lock, so the mint held no board_users lock it needed.
    assert_receive {:removal_done, {:ok, %OrganizationMember{role: :member}}}, 5_000
    await_lock_waiters(1)

    send(removal.pid, :finish)
    assert Task.await(removal) == {:error, :rolled_back}

    # The removal was rolled back, so the member could still mint; the mint's
    # own transaction was rolled back as well.
    assert {:error, {:ok, {%ApiToken{}, _plain}}} = Task.await(mint)
    assert live_tokens(ctx) == []
  end

  test "a mint waiting on a removal that commits is refused and leaves no token", ctx do
    holder = hold_organization_lock(ctx, &remove_member_rows(&1, ctx))
    await_lock_waiters(0)

    mint = start_mint(ctx)
    await_lock_waiters(1)

    send(holder.pid, :proceed)
    assert Task.await(holder) == {:ok, :removed}

    assert {:error, {:error, :unauthorized}} = Task.await(mint)
    assert live_tokens(ctx) == []
  end

  # A second session that locks the Organization row FOR UPDATE, as every
  # membership write does first, and holds it until told to proceed; then runs
  # `then_fun` in the same transaction and commits.
  defp hold_organization_lock(ctx, then_fun) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        guard(fn ->
          Postgrex.transaction(conn, fn c ->
            Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])

            Postgrex.query!(c, "SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
              ctx.organization.id
            ])

            send(test_pid, :holding)
            receive do: (:proceed -> then_fun.(c))
          end)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  # The removal's writes, in its lock order: the board_users row FOR UPDATE
  # after the Organization row, then the deletes and the token revocation.
  defp remove_member_rows(c, ctx) do
    params = [ctx.board.id, ctx.member.id]

    Postgrex.query!(
      c,
      "SELECT id FROM board_users WHERE board_id = $1 AND user_id = $2 FOR UPDATE",
      params
    )

    Postgrex.query!(c, "DELETE FROM board_users WHERE board_id = $1 AND user_id = $2", params)

    Postgrex.query!(
      c,
      "UPDATE api_tokens SET revoked_at = now() " <>
        "WHERE board_id = $1 AND user_id = $2 AND revoked_at IS NULL",
      params
    )

    Postgrex.query!(c, "DELETE FROM workspace_members WHERE user_id = $1 AND role <> 'owner'", [
      ctx.member.id
    ])

    Postgrex.query!(c, "DELETE FROM organization_members WHERE user_id = $1", [ctx.member.id])
    :removed
  end

  # The real removal, in a transaction that waits for :finish and is then
  # rolled back, so it commits nothing.
  defp start_removal(ctx) do
    test_pid = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          result = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, ctx.member.id)
          send(test_pid, {:removal_done, result})
          receive do: (:finish -> Repo.rollback(:rolled_back))
        end)
      end)
    end)
  end

  # The mint, in a transaction that is always rolled back, returning its
  # result as {:error, result}.
  defp start_mint(ctx) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")

          Repo.rollback(
            ApiTokens.create_api_token_for_member(ctx.member, ctx.board, %{name: "Agent"})
          )
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

  defp live_tokens(ctx) do
    from(t in ApiToken,
      where: t.board_id == ^ctx.board.id and t.user_id == ^ctx.member.id and is_nil(t.revoked_at)
    )
    |> Repo.all()
  end

  defp committed_user do
    Repo.insert!(%User{email: "mint-lock-#{System.unique_integer([:positive])}@example.com"})
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
  defp delete_committed(organization_id, workspace_id, board_id, user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(t in ApiToken, where: t.board_id == ^board_id) |> Repo.delete_all()
    from(bu in BoardUser, where: bu.board_id == ^board_id) |> Repo.delete_all()
    from(b in Board, where: b.id == ^board_id) |> Repo.delete_all()
    from(m in WorkspaceMember, where: m.workspace_id == ^workspace_id) |> Repo.delete_all()
    from(w in Workspace, where: w.id == ^workspace_id) |> Repo.delete_all()

    from(m in OrganizationMember, where: m.organization_id == ^organization_id)
    |> Repo.delete_all()

    from(o in Organization, where: o.id == ^organization_id) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
