defmodule Kanban.ApiTokens.MintArchiveLockTest do
  @moduledoc """
  Shows that `Kanban.ApiTokens.create_workspace_api_token/3` and
  `Kanban.Organizations.OrgWorkspaces.archive_workspace/2` contend on the
  workspace row, using real, separate Postgres sessions: the mint reads it
  FOR SHARE and the archive locks it FOR UPDATE. So a mint never commits a
  token the archive's revocation missed: an archive that commits first is seen
  and the mint refused, and an archive that starts while a mint is in flight
  waits for it and then revokes what it inserted. The first case needs the
  mint's share lock; in the second, the token's foreign key to the workspace
  already holds a key-share lock that the archive's FOR UPDATE waits for.

  The test sandbox never commits, so these sessions cannot see sandboxed rows.
  This module therefore checks out unsandboxed connections and commits its
  fixtures for real, which is why it is not async. The fixtures are inserted
  straight through `Repo`, so they write no audit row, and `on_exit` deletes
  them. The real mint and the real archive each run inside a transaction that
  is always rolled back, so neither commits an audit row, which could never be
  deleted. The committed archive is written as raw SQL that takes the
  archive's lock and makes its writes.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrgWorkspaces
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    uniq = System.unique_integer([:positive])
    org_admin = Repo.insert!(%User{email: "mint-archive-#{uniq}@example.com"})

    organization =
      Repo.insert!(%Organization{
        name: "Mint archive #{uniq}",
        contact_name: "Contact",
        contact_email: "mint-archive-contact-#{uniq}@example.com"
      })

    Repo.insert!(%OrganizationMember{
      organization_id: organization.id,
      user_id: org_admin.id,
      role: :org_admin
    })

    workspace =
      Repo.insert!(%Workspace{
        name: "Mint archive #{uniq}",
        slug: "mint-archive-#{uniq}",
        personal: false,
        organization_id: organization.id
      })

    on_exit(fn -> delete_committed(organization.id, workspace.id, org_admin.id) end)

    %{org_admin: org_admin, organization: organization, workspace: workspace}
  end

  test "a mint waiting on an archive that commits is refused and leaves no token", ctx do
    holder = hold_workspace_lock(ctx, &archive_rows(&1, ctx))
    await_lock_waiters(0)

    mint = start_mint(ctx, fn result -> result end)
    await_lock_waiters(1)

    send(holder.pid, :proceed)
    assert Task.await(holder) == {:ok, :archived}

    assert {:error, {:error, :archived}} = Task.await(mint)
    assert live_tokens(ctx) == []
  end

  test "an archive started while a mint is in flight waits for the mint", ctx do
    test_pid = self()

    mint =
      start_mint(ctx, fn result ->
        send(test_pid, {:minted, result})
        receive do: (:finish -> result)
      end)

    assert_receive {:minted, {:ok, {%ApiToken{}, _plain}}}, 5_000
    await_lock_waiters(0)

    archive = start_archive(ctx)
    await_lock_waiters(1)

    send(mint.pid, :finish)
    assert {:error, {:ok, {%ApiToken{}, _plain}}} = Task.await(mint)
    assert {:error, {:ok, %Workspace{archived_at: %DateTime{}}}} = Task.await(archive)
  end

  # A second session that locks the workspace row FOR UPDATE, as the archive
  # does first, and holds it until told to proceed; then runs `then_fun` in the
  # same transaction and commits.
  defp hold_workspace_lock(ctx, then_fun) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        guard(fn ->
          Postgrex.transaction(conn, fn c ->
            Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])

            Postgrex.query!(c, "SELECT id FROM workspaces WHERE id = $1 FOR UPDATE", [
              ctx.workspace.id
            ])

            send(test_pid, :holding)
            receive do: (:proceed -> then_fun.(c))
          end)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  # The archive's writes after its lock: archived_at, then the revocation.
  defp archive_rows(c, ctx) do
    Postgrex.query!(c, "UPDATE workspaces SET archived_at = now() WHERE id = $1", [
      ctx.workspace.id
    ])

    Postgrex.query!(
      c,
      "UPDATE api_tokens SET revoked_at = now() WHERE workspace_id = $1 AND revoked_at IS NULL",
      [ctx.workspace.id]
    )

    :archived
  end

  # The mint, in a transaction that is always rolled back after `then_fun`
  # has seen its result, returning that result as {:error, result}.
  defp start_mint(ctx, then_fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")

          ctx.org_admin
          |> ApiTokens.create_workspace_api_token(ctx.workspace, %{name: "Fleet"})
          |> then_fun.()
          |> Repo.rollback()
        end)
      end)
    end)
  end

  # The real archive, in a transaction that is always rolled back, returning
  # its result as {:error, result}.
  defp start_archive(ctx) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      guard(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          Repo.rollback(OrgWorkspaces.archive_workspace(ctx.org_admin, ctx.workspace.id))
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

  defp live_tokens(ctx) do
    from(t in ApiToken, where: t.workspace_id == ^ctx.workspace.id and is_nil(t.revoked_at))
    |> Repo.all()
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
  defp delete_committed(organization_id, workspace_id, user_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(t in ApiToken, where: t.workspace_id == ^workspace_id) |> Repo.delete_all()
    from(w in Workspace, where: w.id == ^workspace_id) |> Repo.delete_all()

    from(m in OrganizationMember, where: m.organization_id == ^organization_id)
    |> Repo.delete_all()

    from(o in Organization, where: o.id == ^organization_id) |> Repo.delete_all()
    from(u in User, where: u.id == ^user_id) |> Repo.delete_all()
  end
end
