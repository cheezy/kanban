defmodule Kanban.AuditLog.OrganizationPurgeTest do
  # async: false for the same reason as Kanban.AuditLog.PurgeTest: replacing
  # functions and switching roles take locks held until the sandbox rolls back.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.OrganizationPurge
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.AuditLogRoleHelper

  @function "audit_events_purge_organization(bigint, timestamp with time zone, integer)"
  @purge "audit_events_purge(timestamp with time zone)"

  defp runner, do: AuditLogRoleHelper.runner()

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp connected_as, do: scalar("SELECT current_user")

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp insert_at(%DateTime{} = at, organization_id \\ nil) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        AuditEvent,
        [
          %{action: "backdated", metadata: %{}, inserted_at: at, organization_id: organization_id}
        ],
        returning: [:id]
      )

    id
  end

  defp ids, do: AuditEvent |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  defp function_owner do
    scalar(
      "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = to_regprocedure('#{@function}')"
    )
  end

  defp attempt(sql), do: Repo.transact(fn -> Repo.query(sql) end)

  defp purge(org_id, days, batch \\ 1_000),
    do: AuditLog.purge_organization_before(org_id, days_ago(days), batch)

  describe "the migrated test database" do
    test "has the hardened Organization purge function beside the unchanged one" do
      assert Purge.organization_status(runner(), app_role: connected_as()) == :hardened
      assert function_owner() == Hardening.owner_role()
      assert Purge.status(runner(), app_role: connected_as()) == :hardened
      assert scalar("SELECT count(*) FROM pg_proc WHERE proname = 'audit_events_purge'") == 1
    end
  end

  describe "purge_organization_before/3" do
    test "removes only that Organization's rows older than the cutoff" do
      org = organization_fixture()
      other = organization_fixture()
      old = insert_at(days_ago(200), org.id)
      recent = insert_at(days_ago(10), org.id)
      other_old = insert_at(days_ago(200), other.id)
      site_old = insert_at(days_ago(200))

      assert purge(org.id, 120) == {:ok, 1}
      assert ids() == Enum.sort([recent, other_old, site_old])
      refute old in ids()
    end

    test "nil removes only rows with no Organization" do
      org = organization_fixture()
      org_old = insert_at(days_ago(200), org.id)
      site_old = insert_at(days_ago(200))
      site_recent = insert_at(days_ago(5))

      assert purge(nil, 120) == {:ok, 1}
      assert ids() == Enum.sort([org_old, site_recent])
      refute site_old in ids()
    end

    test "removes at most batch_limit rows per call, oldest first" do
      org = organization_fixture()
      oldest = insert_at(days_ago(300), org.id)
      middle = insert_at(days_ago(250), org.id)
      newest = insert_at(days_ago(200), org.id)

      assert purge(org.id, 120, 2) == {:ok, 2}
      assert ids() == [newest]
      refute oldest in ids() or middle in ids()
      assert purge(org.id, 120, 2) == {:ok, 1}
      assert purge(org.id, 120, 2) == {:ok, 0}
    end

    test "refuses a cutoff inside the 90-day floor and removes nothing" do
      org = organization_fixture()
      insert_at(days_ago(200), org.id)

      assert purge(org.id, 89) == {:error, :cutoff_too_recent}
      assert purge(nil, 1) == {:error, :cutoff_too_recent}
      assert length(ids()) == 1

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "KAP01"}}} =
               Repo.query(
                 "SELECT audit_events_purge_organization($1, now() - interval '90 days' + interval '1 microsecond', 10)",
                 [org.id]
               )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "KAP01"}}} =
               Repo.query("SELECT audit_events_purge_organization($1, NULL, 10)", [org.id])
    end

    test "the database refuses a batch limit below 1" do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023"}}} =
               attempt(
                 "SELECT audit_events_purge_organization(1, now() - interval '200 days', 0)"
               )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023"}}} =
               attempt(
                 "SELECT audit_events_purge_organization(1, now() - interval '200 days', NULL)"
               )
    end

    test "rejects arguments of the wrong shape at the function head" do
      purge_fun = &AuditLog.purge_organization_before/3
      cutoff = days_ago(200)

      for {org_id, at, batch} <- [
            {1, ~N[2020-01-01 00:00:00], 10},
            {0, cutoff, 10},
            {-1, cutoff, 10},
            {"1", cutoff, 10},
            {1, cutoff, 0},
            {1, cutoff, nil}
          ] do
        assert_raise FunctionClauseError, fn -> purge_fun.(org_id, at, batch) end
      end
    end

    test "a refusal inside a caller's transaction does not abort it" do
      org = organization_fixture()
      insert_at(days_ago(200), org.id)

      assert {:ok, :done} =
               Repo.transact(fn ->
                 assert purge(org.id, 1) == {:error, :cutoff_too_recent}
                 assert purge(org.id, 100) == {:ok, 1}
                 {:ok, :done}
               end)
    end

    test "any other database error raises" do
      Repo.query!("DROP FUNCTION #{@function}")
      assert_raise Postgrex.Error, ~r/audit_events_purge_organization/, fn -> purge(1, 100) end
    end
  end

  describe "the app-like role" do
    test "can run the hardened function but cannot delete rows directly or replace it" do
      org = organization_fixture()
      old = insert_at(days_ago(200), org.id)
      recent = insert_at(days_ago(10), org.id)
      role = AuditLogRoleHelper.create_app_like_role()
      :ok = Purge.apply(runner(), :hardened, app_role: role)
      :ok = Purge.apply_organization(runner(), :hardened, app_role: role)
      AuditLogRoleHelper.switch_role(role)

      assert purge(org.id, 100) == {:ok, 1}
      refute old in ids()

      assert {:error, %Postgrex.Error{}} = attempt("DELETE FROM audit_events")

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               attempt("DROP FUNCTION #{@function}")

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               attempt("ALTER FUNCTION #{@function} SECURITY INVOKER")

      assert ids() == [recent]
    end

    test "a role never given EXECUTE cannot run it" do
      assert OrganizationPurge.revert(runner()) == :reverted
      role = AuditLogRoleHelper.create_app_like_role()
      :ok = Purge.apply_organization(runner(), :hardened, app_role: role)
      outsider = AuditLogRoleHelper.create_app_like_role()
      AuditLogRoleHelper.switch_role(outsider)

      error = assert_raise Postgrex.Error, fn -> purge(nil, 100) end
      assert error.postgres.code == :insufficient_privilege
    end
  end

  describe "apply/3 and status/2" do
    test "applying twice leaves one owner-owned function only the app role can execute" do
      role = AuditLogRoleHelper.create_app_like_role()
      assert OrganizationPurge.revert(runner()) == :reverted
      :ok = Purge.apply_organization(runner(), :hardened, app_role: role)
      :ok = Purge.apply_organization(runner(), :hardened, app_role: role)

      assert scalar(
               "SELECT count(*) FROM pg_proc WHERE proname = 'audit_events_purge_organization'"
             ) == 1

      assert function_owner() == Hardening.owner_role()
      refute scalar("SELECT has_function_privilege('public', '#{@function}', 'EXECUTE')")
      assert scalar("SELECT has_function_privilege('#{role}', '#{@function}', 'EXECUTE')")
      assert Purge.organization_status(runner(), app_role: role) == :hardened
    end

    test "the degraded function works through the flag-based trigger" do
      org = organization_fixture()
      old = insert_at(days_ago(200), org.id)
      recent = insert_at(days_ago(5), org.id)
      role = AuditLogRoleHelper.create_app_like_role()

      assert Purge.revert(runner()) == :reverted
      assert OrganizationPurge.revert(runner()) == :reverted
      :ok = Purge.apply(runner(), :degraded, app_role: role)
      :ok = Purge.apply_organization(runner(), :degraded, app_role: role)
      assert function_owner() == role

      Repo.query!("GRANT DELETE ON audit_events TO #{Hardening.quote_ident(role)}")
      AuditLogRoleHelper.switch_role(role)

      assert purge(org.id, 100) == {:ok, 1}
      assert purge(org.id, 1) == {:error, :cutoff_too_recent}
      assert ids() == [recent]
      refute old in ids()

      assert Purge.organization_status(runner(), app_role: role) ==
               {:degraded, [:organization_purge_function_not_owned_by_owner_role]}
    end

    test "reports a missing function and each weakened right" do
      role = AuditLogRoleHelper.create_app_like_role()
      :ok = Purge.apply_organization(runner(), :hardened, app_role: role)
      assert Purge.organization_status(runner(), app_role: role) == :hardened

      Repo.query!("GRANT EXECUTE ON FUNCTION #{@function} TO PUBLIC")

      assert Purge.organization_status(runner(), app_role: role) ==
               {:degraded, [:organization_purge_function_executable_by_public]}

      Repo.query!("REVOKE EXECUTE ON FUNCTION #{@function} FROM PUBLIC")
      Repo.query!("ALTER FUNCTION #{@function} SECURITY INVOKER")
      Repo.query!("ALTER FUNCTION #{@function} RESET search_path")
      Repo.query!("REVOKE EXECUTE ON FUNCTION #{@function} FROM #{Hardening.quote_ident(role)}")

      assert Purge.organization_status(runner(), app_role: role) ==
               {:degraded,
                [
                  :organization_purge_function_not_security_definer,
                  :organization_purge_function_search_path_not_pinned,
                  :app_role_cannot_execute_organization_purge_function
                ]}

      assert OrganizationPurge.revert(runner()) == :reverted

      assert Purge.organization_status(runner(), app_role: role) ==
               {:degraded, [:organization_purge_function_missing]}

      # The existing purge's status is unaffected by the new function.
      assert Purge.status(runner(), app_role: connected_as()) == :hardened
    end
  end

  describe "migrate_or_degrade/2 and revert/1" do
    test "hardens as a superuser on a hardened table, without a degraded notice" do
      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade_organization(runner(), app_role: connected_as()) ==
                   :hardened
        end)

      refute log =~ "security_audit_organization_purge_degraded"
    end

    test "a non-superuser cannot replace the owner's function: degrades, logs and changes nothing" do
      role = AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade_organization(runner(), app_role: role) ==
                   {:degraded, [:not_superuser, :organization_purge_function_not_replaceable]}
        end)

      assert log =~
               "security_audit_organization_purge_degraded reason=not_superuser,organization_purge_function_not_replaceable"

      AuditLogRoleHelper.reset_role()
      assert function_owner() == Hardening.owner_role()
    end

    test "a non-superuser installs the degraded function when none exists" do
      role = AuditLogRoleHelper.create_app_like_role()
      assert OrganizationPurge.revert(runner()) == :reverted
      AuditLogRoleHelper.switch_role(role)

      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade_organization(runner(), app_role: role) ==
                   {:degraded, [:not_superuser]}
        end)

      assert log =~ "security_audit_organization_purge_degraded reason=not_superuser"
      AuditLogRoleHelper.reset_role()
      assert function_owner() == role
    end

    test "revert leaves a function it cannot drop and names it" do
      role = AuditLogRoleHelper.switch_to_app_like_role()
      assert is_binary(role)

      log =
        capture_log(fn ->
          assert Purge.revert_organization(runner()) ==
                   {:degraded, [:organization_purge_function_not_droppable]}
        end)

      assert log =~ "organization_purge_function_not_droppable"
      AuditLogRoleHelper.reset_role()
      assert function_owner() == Hardening.owner_role()
      assert Purge.revert_organization(runner()) == :reverted
      assert Purge.revert_organization(runner()) == :reverted
      assert scalar("SELECT to_regprocedure('#{@purge}') IS NOT NULL")
    end
  end
end
