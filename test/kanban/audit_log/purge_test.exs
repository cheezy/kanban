defmodule Kanban.AuditLog.PurgeTest do
  # async: false because replacing the trigger and purge functions and moving
  # their ownership take locks held until the sandbox rolls back, which would
  # block every concurrent test writing an audit event. Nothing is restored by
  # hand: the sandbox rollback undoes every statement here.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.AuditLogRoleHelper

  @purge "audit_events_purge(timestamp with time zone)"

  defp runner, do: AuditLogRoleHelper.runner()

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp connected_as, do: scalar("SELECT current_user")

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp purge_older_than(days), do: days |> days_ago() |> AuditLog.purge_before()

  # AuditEvent.insert_changeset/1 does not cast inserted_at, so backdated rows
  # go in through insert_all with an explicit timestamp.
  defp insert_at(%DateTime{} = at) do
    {1, [%{id: id}]} =
      Repo.insert_all(AuditEvent, [%{action: "backdated", metadata: %{}, inserted_at: at}],
        returning: [:id]
      )

    id
  end

  defp ids, do: AuditEvent |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  # Each attempt runs in its own savepoint, so a refusal does not abort the
  # sandbox transaction for the attempts after it.
  defp attempt(statements) do
    Repo.transact(fn ->
      statements
      |> List.wrap()
      |> Enum.reduce_while({:ok, nil}, fn sql, _acc ->
        case Repo.query(sql) do
          {:ok, result} -> {:cont, {:ok, result}}
          error -> {:halt, error}
        end
      end)
    end)
  end

  defp assert_refused(statements) do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             attempt(statements),
           "expected #{inspect(statements)} to be refused for lack of privilege"
  end

  defp function_owner do
    scalar(
      "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = to_regprocedure('#{@purge}')"
    )
  end

  defp trigger_source do
    scalar("SELECT prosrc FROM pg_proc WHERE oid = 'audit_events_append_only()'::regprocedure")
  end

  # An app-like role that may run the hardened purge function.
  defp hardened_app_role do
    role = AuditLogRoleHelper.create_app_like_role()
    :ok = Purge.apply(runner(), :hardened, app_role: role)
    role
  end

  describe "the migrated test database" do
    test "has the hardened purge: owner-owned function and owner-aware trigger" do
      assert Purge.status(runner(), app_role: connected_as()) == :hardened
      assert function_owner() == Hardening.owner_role()
      refute trigger_source() =~ "kanban.audit_purge"
    end
  end

  describe "purge_before/1" do
    test "purge_before removes only rows older than the cutoff and returns the count" do
      old = insert_at(days_ago(200))
      older = insert_at(days_ago(150))
      recent = insert_at(days_ago(10))

      assert purge_older_than(120) == {:ok, 2}
      assert ids() == [recent]
      refute old in ids() or older in ids()
    end

    test "purge keeps a row stamped exactly at the cutoff and refuses a cutoff newer than the retention floor" do
      cutoff = days_ago(120)
      at_cutoff = insert_at(cutoff)
      _just_before = insert_at(DateTime.add(cutoff, -1, :microsecond))

      assert AuditLog.purge_before(cutoff) == {:ok, 1}
      assert ids() == [at_cutoff]

      insert_at(days_ago(200))
      assert purge_older_than(89) == {:error, :cutoff_too_recent}

      tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

      assert AuditLog.purge_before(tomorrow) ==
               {:error, :cutoff_too_recent}

      assert length(ids()) == 2

      # The floor is enforced by the function itself, to the microsecond.
      # now() is fixed for the sandbox transaction, so this is the exact edge.
      assert {:ok, _} = Repo.query("SELECT audit_events_purge(now() - interval '90 days')")

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "KAP01"}}} =
               Repo.query(
                 "SELECT audit_events_purge(now() - interval '90 days' + interval '1 microsecond')"
               )

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "KAP01"}}} =
               Repo.query("SELECT audit_events_purge(NULL)")
    end

    test "purge_before on an empty table returns zero" do
      assert ids() == []
      assert purge_older_than(365) == {:ok, 0}
    end

    test "purge_before given a value that is not a DateTime fails at the function head" do
      # Called through a variable so the compiler's type check does not
      # reject the deliberately wrong argument at compile time.
      purge_before = &AuditLog.purge_before/1

      for value <- [~N[2020-01-01 00:00:00], ~D[2020-01-01], "2020-01-01", nil] do
        assert_raise FunctionClauseError, fn -> purge_before.(value) end
      end
    end

    test "a refusal inside a caller's transaction does not abort it" do
      insert_at(days_ago(200))

      assert {:ok, :done} =
               Repo.transact(fn ->
                 assert purge_older_than(1) == {:error, :cutoff_too_recent}
                 assert purge_older_than(100) == {:ok, 1}
                 {:ok, :done}
               end)
    end

    test "any other database error raises" do
      Repo.query!("DROP FUNCTION #{@purge}")

      assert_raise Postgrex.Error, ~r/audit_events_purge/, fn ->
        purge_older_than(100)
      end
    end

    test "leaves the purge flag as it found it" do
      insert_at(days_ago(200))

      assert {:ok, flag} =
               Repo.transact(fn ->
                 {:ok, 1} = purge_older_than(100)
                 {:ok, scalar("SELECT coalesce(current_setting('kanban.audit_purge', true), '')")}
               end)

      assert flag == ""
    end
  end

  describe "the app-like role" do
    test "the app-like role can run the purge function but cannot delete rows directly or replace the purge function" do
      old = insert_at(days_ago(200))
      recent = insert_at(days_ago(10))
      role = hardened_app_role()
      AuditLogRoleHelper.switch_role(role)

      assert purge_older_than(100) == {:ok, 1}
      assert purge_older_than(1) == {:error, :cutoff_too_recent}
      refute old in ids()

      assert_refused("DELETE FROM audit_events")

      assert_refused([
        "SELECT set_config('kanban.audit_purge', 'on', true)",
        "DELETE FROM audit_events"
      ])

      assert_refused("""
      CREATE OR REPLACE FUNCTION public.audit_events_purge(cutoff timestamp with time zone)
      RETURNS bigint LANGUAGE sql AS $$ SELECT 0::bigint $$
      """)

      assert_refused("ALTER FUNCTION #{@purge} OWNER TO CURRENT_USER")
      assert_refused("ALTER FUNCTION #{@purge} SECURITY INVOKER")
      assert_refused("DROP FUNCTION #{@purge}")
      assert ids() == [recent]
    end

    test "a role that was never given EXECUTE cannot run the purge function" do
      # Start from no purge function, so the install itself must revoke the
      # EXECUTE right a new function gives PUBLIC.
      assert Purge.revert(runner()) == :reverted
      hardened_app_role()
      outsider = AuditLogRoleHelper.create_app_like_role()
      insert_at(days_ago(200))
      AuditLogRoleHelper.switch_role(outsider)

      error = assert_raise Postgrex.Error, fn -> purge_older_than(100) end
      assert error.postgres.code == :insufficient_privilege
    end

    test "deleting a user still nulls actor_user_id under the owner-aware trigger" do
      user = user_fixture()
      AuditLog.event(:sudo_mode_entered, user_id: user.id)
      assert [event] = Repo.all(AuditEvent)
      refute trigger_source() =~ "kanban.audit_purge"

      AuditLogRoleHelper.switch_to_app_like_role()
      Repo.delete!(user)

      reloaded = Repo.get!(AuditEvent, event.id)
      assert reloaded.actor_user_id == nil
      assert reloaded.action == event.action
      assert reloaded.inserted_at == event.inserted_at
    end

    test "the owner of audit_events may delete, a superuser may not" do
      id = insert_at(days_ago(1))

      assert {:error, %Postgrex.Error{} = error} = attempt("DELETE FROM audit_events")
      assert Exception.message(error) =~ "append-only: DELETE is not permitted"

      # SET ROLE is checked against the session user, the suite's superuser.
      AuditLogRoleHelper.switch_role(Hardening.owner_role())
      assert {:ok, %{num_rows: 1}} = Repo.query("DELETE FROM audit_events WHERE id = #{id}")
      AuditLogRoleHelper.reset_role()
      assert ids() == []
    end
  end

  describe "apply/3" do
    test "applying the purge hardening twice leaves one owner-owned purge function that only the app role can execute" do
      role = AuditLogRoleHelper.create_app_like_role()
      # Start from no purge function, so the first apply is a fresh install
      # and the second replaces it.
      assert Purge.revert(runner()) == :reverted
      :ok = Purge.apply(runner(), :hardened, app_role: role)
      :ok = Purge.apply(runner(), :hardened, app_role: role)

      assert scalar("SELECT count(*) FROM pg_proc WHERE proname = 'audit_events_purge'") == 1
      assert function_owner() == Hardening.owner_role()
      assert scalar("SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('#{@purge}')")
      refute scalar("SELECT has_function_privilege('public', '#{@purge}', 'EXECUTE')")
      assert scalar("SELECT has_function_privilege('#{role}', '#{@purge}', 'EXECUTE')")

      assert Purge.status(runner(), app_role: role) == :hardened
      # Replacing the trigger body kept the search_path pin hardening relies on.
      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    test "the degraded variant keeps the flag behaviour for a flagged delete and rejects an unflagged one" do
      old = insert_at(days_ago(200))
      flagged = insert_at(days_ago(5))
      unflagged = insert_at(days_ago(4))
      role = AuditLogRoleHelper.create_app_like_role()

      assert Purge.revert(runner()) == :reverted
      :ok = Purge.apply(runner(), :degraded, app_role: role)
      assert function_owner() == role
      assert trigger_source() =~ "kanban.audit_purge"

      # A degraded application role still owns the table, so it holds DELETE.
      Repo.query!("GRANT DELETE ON audit_events TO #{Hardening.quote_ident(role)}")
      AuditLogRoleHelper.switch_role(role)

      assert {:error, error} = attempt("DELETE FROM audit_events WHERE id = #{unflagged}")

      assert Exception.message(error) =~
               ~r/append-only: DELETE is not permitted outside the retention purge/

      assert {:ok, %{num_rows: 1}} =
               attempt([
                 "SELECT set_config('kanban.audit_purge', 'on', true)",
                 "DELETE FROM audit_events WHERE id = #{flagged}"
               ])

      assert purge_older_than(100) == {:ok, 1}
      assert purge_older_than(1) == {:error, :cutoff_too_recent}
      assert ids() == [unflagged]
      refute old in ids()
    end
  end

  describe "status/2" do
    test "purge status reports degraded when the purge function is missing or owned by the app role" do
      role = AuditLogRoleHelper.create_app_like_role()

      assert Purge.revert(runner()) == :reverted

      assert Purge.status(runner(), app_role: role) ==
               {:degraded, [:purge_function_missing, :trigger_function_honors_flag]}

      :ok = Purge.apply(runner(), :degraded, app_role: role)

      assert Purge.status(runner(), app_role: role) ==
               {:degraded,
                [:purge_function_not_owned_by_owner_role, :trigger_function_honors_flag]}
    end

    test "reports each weakened right of a hardened purge function" do
      role = hardened_app_role()
      assert Purge.status(runner(), app_role: role) == :hardened

      Repo.query!("GRANT EXECUTE ON FUNCTION #{@purge} TO PUBLIC")

      assert Purge.status(runner(), app_role: role) ==
               {:degraded, [:purge_function_executable_by_public]}

      Repo.query!("REVOKE EXECUTE ON FUNCTION #{@purge} FROM PUBLIC")
      Repo.query!("ALTER FUNCTION #{@purge} SECURITY INVOKER")
      Repo.query!("ALTER FUNCTION #{@purge} RESET search_path")

      assert Purge.status(runner(), app_role: role) ==
               {:degraded,
                [:purge_function_not_security_definer, :purge_function_search_path_not_pinned]}
    end

    test "reports an app role that cannot execute the purge function, or does not exist" do
      hardened_app_role()
      outsider = AuditLogRoleHelper.create_app_like_role()
      absent = AuditLogRoleHelper.unique_role_name("kanban_audit_absent_")

      for role <- [outsider, absent] do
        assert Purge.status(runner(), app_role: role) ==
                 {:degraded, [:app_role_cannot_execute_purge_function]}
      end
    end

    test "reports a purge function owned by another role than the named owner role" do
      role = hardened_app_role()
      other_owner = AuditLogRoleHelper.unique_role_name("kanban_audit_absent_")

      assert Purge.status(runner(), app_role: role, owner_role: other_owner) ==
               {:degraded, [:purge_function_not_owned_by_owner_role]}
    end
  end

  describe "migrate_or_degrade/2" do
    test "hardens as a superuser on a hardened table, without a degraded notice" do
      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade(runner(), app_role: connected_as()) == :hardened
        end)

      refute log =~ "security_audit_purge_degraded"
    end

    test "a non-superuser cannot replace the owner's function: degrades, logs and changes nothing" do
      role = AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade(runner(), app_role: role) ==
                   {:degraded, [:not_superuser, :purge_function_not_replaceable]}
        end)

      assert log =~
               "security_audit_purge_degraded reason=not_superuser,purge_function_not_replaceable"

      AuditLogRoleHelper.reset_role()
      assert function_owner() == Hardening.owner_role()
    end

    test "a non-superuser installs the degraded purge when no purge function exists" do
      role = AuditLogRoleHelper.create_app_like_role()
      assert Purge.revert(runner()) == :reverted
      AuditLogRoleHelper.switch_role(role)

      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade(runner(), app_role: role) ==
                   {:degraded, [:not_superuser]}
        end)

      assert log =~ "security_audit_purge_degraded reason=not_superuser"
      AuditLogRoleHelper.reset_role()
      assert function_owner() == role
      assert trigger_source() =~ "kanban.audit_purge"
    end

    test "a non-superuser that cannot create in the schema degrades, logs why and changes nothing" do
      role = AuditLogRoleHelper.create_app_like_role()
      assert Purge.revert(runner()) == :reverted
      quoted = Hardening.quote_ident(role)
      Repo.query!("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
      Repo.query!("REVOKE CREATE ON SCHEMA public FROM #{quoted}")
      AuditLogRoleHelper.switch_role(role)

      log =
        capture_log(fn ->
          assert Purge.migrate_or_degrade(runner(), app_role: role) ==
                   {:degraded, [:not_superuser, :schema_create_denied]}
        end)

      assert log =~ "security_audit_purge_degraded reason=not_superuser,schema_create_denied"
      AuditLogRoleHelper.reset_role()
      assert scalar("SELECT to_regprocedure('#{@purge}') IS NULL")
    end

    test "a superuser installs the degraded purge when the table is not the owner role's" do
      assert Hardening.revert(runner()) == :reverted

      capture_log(fn ->
        assert Purge.migrate_or_degrade(runner(), app_role: connected_as()) ==
                 {:degraded, [:table_not_owned_by_owner_role]}
      end)

      assert function_owner() == connected_as()
    end
  end

  describe "revert/1" do
    test "drops the purge function and restores the flag-based trigger body with its pin" do
      assert Purge.revert(runner()) == :reverted

      assert scalar("SELECT to_regprocedure('#{@purge}') IS NULL")
      source = trigger_source()
      assert source =~ "current_setting('kanban.audit_purge', true)"
      assert source =~ "append-only: TRUNCATE is not permitted"

      assert scalar(
               "SELECT proconfig FROM pg_proc WHERE oid = 'audit_events_append_only()'::regprocedure"
             ) == ["search_path=pg_catalog, pg_temp"]

      # Idempotent: nothing left to drop or restore.
      assert Purge.revert(runner()) == :reverted

      # The restored body admits a flagged delete again.
      id = insert_at(days_ago(1))

      assert {:ok, %{num_rows: 1}} =
               attempt([
                 "SELECT set_config('kanban.audit_purge', 'on', true)",
                 "DELETE FROM audit_events WHERE id = #{id}"
               ])
    end

    test "degrades without raising for a role that owns neither function" do
      AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn ->
          assert Purge.revert(runner()) ==
                   {:degraded, [:purge_function_not_droppable, :trigger_function_not_replaceable]}
        end)

      assert log =~ "security_audit_purge_degraded"
      AuditLogRoleHelper.reset_role()
      assert function_owner() == Hardening.owner_role()
    end
  end

  describe "Hardening helpers shared with Purge" do
    test "scalar/2 returns the single value, or nil for no row" do
      assert Hardening.scalar(runner(), "SELECT 42") == 42
      assert Hardening.scalar(runner(), "SELECT 1 WHERE false") == nil
    end

    test "quote_literal/1 quotes a role name and doubles embedded single quotes" do
      assert Hardening.quote_literal("app") == "'app'"
      assert Hardening.quote_literal("o'brien") == "'o''brien'"
      assert_raise ArgumentError, fn -> Hardening.quote_literal("a$b") end
    end
  end

  test "retention_floor_days/0 and cutoff_too_recent_code/0 name the floor and the refusal" do
    assert Purge.retention_floor_days() == 90
    assert Purge.cutoff_too_recent_code() == "KAP01"
  end
end
