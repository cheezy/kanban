defmodule Kanban.Organizations.OrgAdminLockTest do
  @moduledoc """
  Shows that `Kanban.Organizations.remove_org_admin/3` runs its last-org-admin
  check under locks that a concurrent removal, or a user deletion's cascade,
  really contends with, using a second, real Postgres session.

  The test sandbox never commits, so a second session cannot see sandboxed
  rows. This module therefore checks out an unsandboxed connection and commits
  its fixtures for real, which is why it is not async: ExUnit runs it after
  every async module, so no sandboxed test can see its rows. The fixtures are
  inserted straight through `Repo`, so they emit no telemetry and write no
  audit row, and `on_exit` deletes them.

  The removal under test runs inside a transaction the test rolls back, so it
  commits nothing either: not even an audit row, which could never be deleted,
  if a regression let the removal through.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @hold_ms 300

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    admin = committed_user(:admin)
    first = committed_user(:user)
    second = committed_user(:user)
    member = committed_user(:user)
    organization = organization_fixture()

    organization_member_fixture(organization, first, :org_admin)
    organization_member_fixture(organization, second, :org_admin)
    organization_member_fixture(organization, member, :member)

    user_ids = Enum.map([admin, first, second, member], & &1.id)
    on_exit(fn -> delete_committed(organization.id, user_ids) end)

    %{admin: admin, first: first, second: second, organization: organization}
  end

  test "a removal racing another removal of the last two org-admins leaves one in place",
       ctx do
    # The competing removal locks the organization row the way
    # remove_org_admin/3 does before deleting the second org-admin.
    competitor = hold_deleted_membership(ctx, lock_organization: true)

    {elapsed_ms, result} = remove_and_roll_back(ctx)

    assert {:ok, :committed} = Task.await(competitor)

    # Without the organization lock the check would count the second
    # org-admin, whose deletion had not committed yet, and remove the first.
    assert result == {:error, {:error, :last_org_admin}}
    assert elapsed_ms >= @hold_ms - 50
    assert org_admin_ids(ctx.organization.id) == [ctx.first.id]
  end

  test "a removal racing a user deletion's cascade leaves one org-admin in place", ctx do
    # Deleting a user removes their membership through the foreign-key
    # cascade, which takes no organization lock. The competitor deletes the
    # second org-admin's membership the same way.
    competitor = hold_deleted_membership(ctx, lock_organization: false)

    {elapsed_ms, result} = remove_and_roll_back(ctx)

    assert {:ok, :committed} = Task.await(competitor)

    # The check locks the other org-admins' rows, so it waits for the delete
    # and then no longer counts the second org-admin.
    assert result == {:error, {:error, :last_org_admin}}
    assert elapsed_ms >= @hold_ms - 50
    assert org_admin_ids(ctx.organization.id) == [ctx.first.id]
  end

  # Deletes the second org-admin's membership in a second session and holds
  # that transaction open for @hold_ms before committing. Returns once the
  # delete has run, with the task to await.
  defp hold_deleted_membership(ctx, lock_organization: lock?) do
    test_pid = self()
    conn = second_session()

    competitor =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])

          if lock? do
            Postgrex.query!(c, "SELECT id FROM organizations WHERE id = $1 FOR UPDATE", [
              ctx.organization.id
            ])
          end

          Postgrex.query!(
            c,
            "DELETE FROM organization_members WHERE organization_id = $1 AND user_id = $2",
            [ctx.organization.id, ctx.second.id]
          )

          send(test_pid, :competitor_holding)
          Process.sleep(@hold_ms)
          :committed
        end)
      end)

    assert_receive :competitor_holding, 5_000
    competitor
  end

  # Removes the first org-admin inside a transaction that is always rolled
  # back, returning the elapsed time and remove_org_admin/3's result wrapped
  # as {:error, result}.
  defp remove_and_roll_back(ctx) do
    timed(fn ->
      Repo.transaction(fn ->
        Repo.rollback(Organizations.remove_org_admin(ctx.admin, ctx.organization, ctx.first))
      end)
    end)
  end

  defp committed_user(type) do
    Repo.insert!(%User{
      email: "org-lock-#{System.unique_integer([:positive])}@example.com",
      type: type
    })
  end

  # A raw connection outside the sandbox: a second Postgres session whose row
  # lock really contends with the removal's. Linked to the test process, so it
  # closes when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp org_admin_ids(organization_id) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.role == ^:org_admin,
      select: m.user_id
    )
    |> Repo.all()
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(organization_id, user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(m in OrganizationMember, where: m.organization_id == ^organization_id)
    |> Repo.delete_all()

    from(o in Organization, where: o.id == ^organization_id) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
