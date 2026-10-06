defmodule Kanban.AuditLog.HardeningTest do
  # async: false because hardening takes ACCESS EXCLUSIVE locks on audit_events
  # (ownership moves) that are held until the sandbox rolls back, which would
  # block every concurrent test writing an audit event.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLogRoleHelper

  @extra_rights ~w(UPDATE DELETE TRUNCATE REFERENCES TRIGGER)

  defp runner, do: AuditLogRoleHelper.runner()

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp random_role_name,
    do: AuditLogRoleHelper.unique_role_name("kanban_audit_absent_")

  defp owner_of_table,
    do:
      scalar(
        "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'audit_events'::regclass"
      )

  defp owner_of_function,
    do:
      scalar(
        "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'audit_events_append_only()'::regprocedure"
      )

  defp owner_of_sequence,
    do:
      scalar(
        "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = pg_get_serial_sequence('audit_events', 'id')::regclass"
      )

  defp owner_of_schema,
    do:
      scalar(
        "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE oid = (SELECT relnamespace FROM pg_class WHERE oid = 'audit_events'::regclass)"
      )

  defp schema_of_table,
    do:
      scalar(
        "SELECT quote_ident(nspname) FROM pg_namespace WHERE oid = (SELECT relnamespace FROM pg_class WHERE oid = 'audit_events'::regclass)"
      )

  # Each tamper attempt runs in its own savepoint, so a refusal does not abort
  # the sandbox transaction for the attempts after it.
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

  describe "the migrated test database" do
    test "is hardened: the owner role owns the table, its sequence, the trigger function and their schema" do
      owner = Hardening.owner_role()

      assert owner_of_table() == owner
      assert owner_of_sequence() == owner
      assert owner_of_function() == owner
      assert owner_of_schema() == owner
      refute scalar("SELECT rolcanlogin FROM pg_roles WHERE rolname = '#{owner}'")
    end

    test "status for the superuser the suite connects as reports app_role_is_superuser" do
      assert Hardening.status(runner(), app_role: scalar("SELECT current_user")) ==
               {:degraded, [:app_role_is_superuser]}
    end
  end

  describe "app-like role" do
    test "app-like role can insert and read events but holds no other right on audit_events" do
      role = AuditLogRoleHelper.switch_to_app_like_role()

      assert {:ok, %AuditEvent{id: id}} =
               %{action: "sudo_mode_entered", metadata: %{}}
               |> AuditEvent.insert_changeset()
               |> Repo.insert()

      assert [%AuditEvent{id: ^id}] = Repo.all(AuditEvent)

      quoted = "'#{role}'"

      for right <- @extra_rights do
        refute scalar("SELECT has_table_privilege(#{quoted}, 'audit_events', '#{right}')"),
               "app-like role still holds #{right} on audit_events"
      end

      refute scalar("SELECT pg_has_role(#{quoted}, '#{Hardening.owner_role()}', 'MEMBER')")
      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    test "AuditLog.event stores a row when the connection runs as the app-like role" do
      user = user_fixture()
      AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn -> assert AuditLog.event(:sudo_mode_entered, user_id: user.id) == :ok end)

      refute log =~ "security_audit_persist_failed"

      assert [%AuditEvent{action: "sudo_mode_entered", actor_user_id: actor}] =
               Repo.all(AuditEvent)

      assert actor == user.id
    end

    test "deleting a user as the app-like role still nulls actor_user_id" do
      user = user_fixture()
      AuditLog.event(:sudo_mode_entered, user_id: user.id)
      assert [event] = Repo.all(AuditEvent)

      AuditLogRoleHelper.switch_to_app_like_role()
      Repo.delete!(user)

      reloaded = Repo.get!(AuditEvent, event.id)
      assert reloaded.actor_user_id == nil
      assert reloaded.action == event.action
      assert reloaded.metadata == event.metadata
      assert reloaded.inserted_at == event.inserted_at
    end

    test "a function the app-like role plants to shadow one the trigger calls never runs as the owner" do
      user = user_fixture()
      AuditLog.event(:sudo_mode_entered, user_id: user.id)
      role = AuditLogRoleHelper.switch_to_app_like_role()

      # The trigger calls pg_trigger_depth() during the FK cascade, which runs
      # as the owner role. A planted public.pg_trigger_depth() would take over
      # that call under this search_path if the function's own were not pinned.
      Repo.query!("SET LOCAL search_path = public, pg_catalog")

      Repo.query!("""
      CREATE FUNCTION public.pg_trigger_depth() RETURNS integer AS $$
      BEGIN
        EXECUTE 'GRANT ALL ON TABLE audit_events TO #{Hardening.quote_ident(role)}';
        RETURN 2;
      END;
      $$ LANGUAGE plpgsql
      """)

      Repo.delete!(user)

      assert [%AuditEvent{actor_user_id: nil}] = Repo.all(AuditEvent)

      for right <- @extra_rights do
        refute scalar("SELECT has_table_privilege('#{role}', 'audit_events', '#{right}')"),
               "the planted function ran as the owner and granted #{right}"
      end
    end

    test "app-like role is refused every tamper attempt" do
      AuditLog.event(:sudo_mode_entered, [])
      assert [event] = Repo.all(AuditEvent)
      AuditLogRoleHelper.switch_to_app_like_role()

      assert_refused("ALTER TABLE audit_events DISABLE TRIGGER audit_events_append_only_rows")
      assert_refused("ALTER TABLE audit_events DISABLE TRIGGER audit_events_append_only_truncate")
      assert_refused("DROP TRIGGER audit_events_append_only_rows ON audit_events")
      assert_refused("DROP FUNCTION audit_events_append_only() CASCADE")
      assert_refused("DROP TABLE audit_events CASCADE")

      assert_refused("""
      CREATE OR REPLACE FUNCTION audit_events_append_only() RETURNS trigger AS $$
      BEGIN
        RETURN COALESCE(NEW, OLD);
      END;
      $$ LANGUAGE plpgsql
      """)

      # SET ROLE is not attempted: Postgres checks it against the session user,
      # which in the sandbox is the superuser, so it would succeed here for a
      # reason a real application login does not share. Non-membership of the
      # owner role is asserted with pg_has_role in the test above instead.
      assert_refused("ALTER TABLE audit_events OWNER TO CURRENT_USER")
      assert_refused("UPDATE audit_events SET action = 'rewritten'")
      assert_refused("DELETE FROM audit_events")
      assert_refused("TRUNCATE audit_events")
      # Replica mode skips ordinary triggers; only a superuser may set it.
      assert_refused("SET LOCAL session_replication_role = replica")

      assert_refused([
        "SELECT set_config('kanban.audit_purge', 'on', true)",
        "DELETE FROM audit_events"
      ])

      # Nothing above took effect: the row is intact and the triggers are on.
      assert Repo.get!(AuditEvent, event.id).action == event.action
      AuditLogRoleHelper.reset_role()
      assert owner_of_table() == Hardening.owner_role()

      assert scalar("""
             SELECT count(*) FROM pg_trigger
             WHERE tgrelid = 'audit_events'::regclass AND NOT tgisinternal AND tgenabled = 'O'
             """) == 2
    end
  end

  describe "hardenable?/1 and migrate_or_degrade/2" do
    test "the privilege check passes for a superuser and fails for the app-like role, and migrate_or_degrade then logs the degraded notice without raising" do
      assert Hardening.hardenable?(runner())

      role = AuditLogRoleHelper.switch_to_app_like_role()
      refute Hardening.hardenable?(runner())

      log =
        capture_log(fn ->
          assert Hardening.migrate_or_degrade(runner(), app_role: role) ==
                   {:degraded, [:not_superuser]}
        end)

      assert log =~ "security_audit_hardening_degraded reason=not_superuser"

      AuditLogRoleHelper.reset_role()
      assert owner_of_table() == Hardening.owner_role()
    end

    test "migrate_or_degrade hardens as a superuser" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("GRANT UPDATE ON TABLE audit_events TO #{Hardening.quote_ident(role)}")

      assert Hardening.migrate_or_degrade(runner(), app_role: role) == :hardened
      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    test "migrate_or_degrade reports, rather than claims, a superuser app role after hardening" do
      me = scalar("SELECT current_user")

      log =
        capture_log(fn ->
          assert Hardening.migrate_or_degrade(runner(), app_role: me) ==
                   {:degraded, [:app_role_is_superuser]}
        end)

      assert log =~ "security_audit_hardening_degraded reason=app_role_is_superuser"
      assert owner_of_table() == Hardening.owner_role()
    end
  end

  describe "apply/2" do
    test "hardening applies twice with no error, tolerates an existing owner role and reports hardened status" do
      owner = Hardening.owner_role()
      role = AuditLogRoleHelper.create_app_like_role()

      assert Hardening.apply(runner(), app_role: role) == :ok
      assert Hardening.apply(runner(), app_role: role) == :ok

      assert scalar("SELECT count(*) FROM pg_roles WHERE rolname = '#{owner}'") == 1
      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    test "creates an absent owner role with no login and hands it everything" do
      owner = random_role_name()
      role = AuditLogRoleHelper.create_app_like_role()

      assert Hardening.apply(runner(), app_role: role, owner_role: owner) == :ok

      refute scalar("SELECT rolcanlogin FROM pg_roles WHERE rolname = '#{owner}'")
      assert owner_of_table() == owner
      assert owner_of_sequence() == owner
      assert owner_of_function() == owner
      assert Hardening.status(runner(), app_role: role, owner_role: owner) == :hardened
    end
  end

  describe "status/2" do
    test "status reports degraded when the owner role is absent or the app role lacks the id sequence right" do
      role = AuditLogRoleHelper.create_app_like_role()

      assert {:degraded, reasons} =
               Hardening.status(runner(), app_role: role, owner_role: random_role_name())

      assert :owner_role_missing in reasons
      assert :table_not_owned_by_owner_role in reasons
      assert :trigger_function_not_owned_by_owner_role in reasons
      refute :app_role_member_of_owner_role in reasons

      sequence = scalar("SELECT pg_get_serial_sequence('audit_events', 'id')")
      Repo.query!("REVOKE USAGE ON SEQUENCE #{sequence} FROM #{Hardening.quote_ident(role)}")

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:app_role_missing_sequence_usage]}
    end

    test "reports missing insert and select rights and extra table rights" do
      role = AuditLogRoleHelper.create_app_like_role()
      quoted = Hardening.quote_ident(role)

      Repo.query!("REVOKE INSERT, SELECT ON TABLE audit_events FROM #{quoted}")
      Repo.query!("GRANT TRUNCATE ON TABLE audit_events TO #{quoted}")

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded,
                [
                  :app_role_missing_insert,
                  :app_role_missing_select,
                  :app_role_has_extra_table_rights
                ]}
    end

    test "reports an app role that is a member of the owner role" do
      role = AuditLogRoleHelper.create_app_like_role()

      Repo.query!(
        "GRANT #{Hardening.quote_ident(Hardening.owner_role())} TO #{Hardening.quote_ident(role)}"
      )

      assert {:degraded, reasons} = Hardening.status(runner(), app_role: role)
      assert :app_role_member_of_owner_role in reasons
    end

    test "reports an owner role that can log in" do
      owner = random_role_name()
      Repo.query!("CREATE ROLE #{Hardening.quote_ident(owner)} LOGIN")
      role = AuditLogRoleHelper.create_app_like_role()

      assert {:degraded, reasons} = Hardening.status(runner(), app_role: role, owner_role: owner)
      assert :owner_role_can_login in reasons
      assert :table_not_owned_by_owner_role in reasons
    end

    test "reports an app role that owns the schema, and hardening takes the schema back" do
      role = AuditLogRoleHelper.create_app_like_role()
      quoted = Hardening.quote_ident(role)
      Repo.query!("ALTER SCHEMA #{schema_of_table()} OWNER TO #{quoted}")

      assert {:degraded, [:app_role_owns_schema]} = Hardening.status(runner(), app_role: role)

      assert Hardening.apply(runner(), app_role: role) == :ok
      assert owner_of_schema() == Hardening.owner_role()
      assert Hardening.status(runner(), app_role: role) == :hardened

      # As a former schema owner, the role can no longer drop what it lost.
      AuditLogRoleHelper.switch_role(role)
      assert_refused("DROP TABLE audit_events CASCADE")
      assert_refused("DROP FUNCTION audit_events_append_only() CASCADE")
    end

    test "reports an app role that can create roles" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("ALTER ROLE #{Hardening.quote_ident(role)} CREATEROLE")

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:app_role_can_create_roles]}
    end

    test "reports an unpinned trigger function search_path" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("ALTER FUNCTION audit_events_append_only() RESET search_path")

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:trigger_function_search_path_not_pinned]}
    end

    test "reports a disabled append-only trigger and a rewrite rule on the table" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("ALTER TABLE audit_events ENABLE REPLICA TRIGGER audit_events_append_only_rows")

      Repo.query!(
        "CREATE RULE audit_events_swallow AS ON INSERT TO audit_events DO INSTEAD NOTHING"
      )

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:append_only_triggers_missing_or_disabled, :rewrite_rule_on_table]}
    end

    test "reports an extra trigger running code another role owns" do
      role = AuditLogRoleHelper.create_app_like_role()
      quoted = Hardening.quote_ident(role)

      Repo.query!("""
      CREATE FUNCTION kanban_audit_test_planted() RETURNS trigger AS $$
      BEGIN
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("ALTER FUNCTION kanban_audit_test_planted() OWNER TO #{quoted}")

      Repo.query!(
        "CREATE TRIGGER planted BEFORE UPDATE ON audit_events FOR EACH ROW EXECUTE FUNCTION kanban_audit_test_planted()"
      )

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:unexpected_trigger_on_table, :foreign_code_on_table]}
    end

    test "reports a constraint calling a function another role owns" do
      role = AuditLogRoleHelper.create_app_like_role()

      Repo.query!(
        "CREATE FUNCTION kanban_audit_test_check(text) RETURNS boolean AS 'SELECT true' LANGUAGE sql"
      )

      Repo.query!(
        "ALTER FUNCTION kanban_audit_test_check(text) OWNER TO #{Hardening.quote_ident(role)}"
      )

      Repo.query!(
        "ALTER TABLE audit_events ADD CONSTRAINT planted CHECK (kanban_audit_test_check(action)) NOT VALID"
      )

      assert Hardening.status(runner(), app_role: role) == {:degraded, [:foreign_code_on_table]}
    end

    test "reports row security on the table" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY")

      assert Hardening.status(runner(), app_role: role) == {:degraded, [:row_security_enabled]}
    end

    test "reports a column-level grant left to PUBLIC, and apply removes it" do
      role = AuditLogRoleHelper.create_app_like_role()
      Repo.query!("GRANT REFERENCES (id), UPDATE (action) ON audit_events TO PUBLIC")

      assert Hardening.status(runner(), app_role: role) ==
               {:degraded, [:app_role_has_extra_table_rights]}

      assert Hardening.apply(runner(), app_role: role) == :ok
      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    test "reports an app role that does not exist" do
      assert {:degraded, [:app_role_missing]} =
               Hardening.status(runner(), app_role: random_role_name())
    end
  end

  describe "revert/1" do
    test "hands ownership back to the connected role and keeps the owner role" do
      me = scalar("SELECT current_user")

      assert Hardening.revert(runner()) == :reverted

      assert owner_of_table() == me
      assert owner_of_sequence() == me
      assert owner_of_function() == me
      assert owner_of_schema() == me

      assert scalar("SELECT count(*) FROM pg_roles WHERE rolname = '#{Hardening.owner_role()}'") ==
               1
    end

    test "degrades without raising for a role that is not a superuser" do
      AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn -> assert Hardening.revert(runner()) == {:degraded, [:not_superuser]} end)

      assert log =~ "security_audit_hardening_degraded reason=not_superuser"
      AuditLogRoleHelper.reset_role()
      assert owner_of_table() == Hardening.owner_role()
    end
  end

  describe "quote_ident/1" do
    test "quotes a role name and doubles embedded double quotes" do
      assert Hardening.quote_ident("kanban_audit_owner") == ~s("kanban_audit_owner")
      assert Hardening.quote_ident(~s(odd"name)) == ~s("odd""name")
    end

    test "rejects names Postgres could not hold or that could end the role-creation block" do
      for name <- ["", "has$dollar", "nul\0byte", String.duplicate("a", 64), :not_a_string] do
        assert_raise ArgumentError, fn -> Hardening.quote_ident(name) end
      end
    end

    test "a quote in an owner role name is doubled in the existence check too" do
      owner = AuditLogRoleHelper.unique_role_name("kanban_audit_o'wner_")
      role = AuditLogRoleHelper.create_app_like_role()

      assert Hardening.apply(runner(), app_role: role, owner_role: owner) == :ok
      assert owner_of_table() == owner
    end
  end
end
