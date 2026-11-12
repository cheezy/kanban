defmodule Kanban.AuditLog.TxidMigrationTest do
  @moduledoc """
  The `audit_events.txid` column and its concurrent index (W2701,
  §9.1 of docs/plans/AUDIT-LOG-STREAMING-DESIGN.md).

  The whole test runs inside one sandbox transaction, so every row a test
  writes shares that transaction's id. Rows written by different transactions
  are covered by the streaming race tests.
  """
  # async: false because the hardened test switches to the app-like role and
  # takes locks on audit_events that are held until the sandbox rolls back.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLogRoleHelper

  @column_migration "priv/repo/migrations/20261112124501_add_txid_to_audit_events.exs"
  @index_migration "priv/repo/migrations/20261112124502_add_audit_events_org_txid_id_index.exs"
  @index "audit_events_org_txid_id_index"

  setup_all do
    [{column_migration, _}] = Code.require_file(@column_migration)
    [{index_migration, _}] = Code.require_file(@index_migration)
    %{column_migration: column_migration, index_migration: index_migration}
  end

  defp runner, do: AuditLogRoleHelper.runner()

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  defp rows(sql), do: Repo.query!(sql).rows

  # The id of the sandbox transaction every row in a test is inserted by.
  defp own_txid, do: scalar("SELECT pg_current_xact_id()::text::bigint")

  defp stored_txids, do: rows("SELECT txid FROM audit_events ORDER BY id") |> List.flatten()

  defp owner_of_table,
    do:
      scalar(
        "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'audit_events'::regclass"
      )

  # Each attempt runs in its own savepoint, so a refusal does not abort the
  # sandbox transaction for the statements after it.
  defp attempt(sql), do: Repo.transact(fn -> Repo.query(sql) end)

  defp assert_refused(sql) do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = attempt(sql),
           "expected #{inspect(sql)} to be refused for lack of privilege"
  end

  describe "the column migration" do
    test "column default is the transaction-id expression and NOT NULL" do
      assert [["bigint", "NO", default]] =
               rows("""
               SELECT data_type, is_nullable, column_default FROM information_schema.columns
               WHERE table_name = 'audit_events' AND column_name = 'txid'
               """)

      assert default =~ "pg_current_xact_id()"
      assert default =~ "bigint"

      assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
               attempt("""
               INSERT INTO audit_events (action, metadata, inserted_at, txid)
               VALUES ('not_null_probe', '{}', now(), NULL)
               """)
    end

    test "keeps its DDL transaction and sets the 10s lock_timeout before any ALTER",
         %{column_migration: migration} do
      refute Keyword.fetch!(migration.__migration__(), :disable_ddl_transaction)

      assert [lock | alters] = migration.column_statements("audit_events")
      assert lock == "SET LOCAL lock_timeout = '10s'"
      assert Enum.all?(alters, &String.starts_with?(&1, "ALTER TABLE audit_events "))
      refute Enum.any?(alters, &(&1 =~ ~r/\bUPDATE\b/i))
    end

    # Postgres's own record that rows predating ADD COLUMN read 0 without a
    # table rewrite. A later migration that rewrites audit_events (a column
    # type change, say) clears it, and this test with it.
    test "the real table records 0 as the value rows written before the column read" do
      assert rows("""
             SELECT atthasmissing, attmissingval::text FROM pg_attribute
             WHERE attrelid = 'audit_events'::regclass AND attname = 'txid'
             """) == [[true, "{0}"]]
    end

    # Rehearses the migration's own statements on a table holding rows, since
    # the test database's audit_events was migrated empty and its rows cannot
    # be updated to show the before-and-after.
    test "rows written before the migration read 0, are not updated, and sort first",
         %{column_migration: migration} do
      Repo.query!("CREATE TEMP TABLE txid_rehearsal (id bigserial PRIMARY KEY, action text)")
      Repo.query!("INSERT INTO txid_rehearsal (action) VALUES ('before_1'), ('before_2')")

      filenode = scalar("SELECT pg_relation_filenode('txid_rehearsal')")
      ctids = rows("SELECT id, ctid::text FROM txid_rehearsal ORDER BY id")
      refute scalar("SHOW lock_timeout") == "10s"

      "txid_rehearsal" |> migration.column_statements() |> Enum.each(&Repo.query!/1)

      assert scalar("SHOW lock_timeout") == "10s"
      assert rows("SELECT id, ctid::text FROM txid_rehearsal ORDER BY id") == ctids
      assert scalar("SELECT pg_relation_filenode('txid_rehearsal')") == filenode

      Repo.query!("INSERT INTO txid_rehearsal (action) VALUES ('after')")
      txid = own_txid()

      assert rows("SELECT action, txid FROM txid_rehearsal ORDER BY txid, id") == [
               ["before_1", 0],
               ["before_2", 0],
               ["after", txid]
             ]
    end
  end

  describe "rollback" do
    # Ecto rolls migrations back newest first, so the index (the later
    # version) is dropped before the column it covers.
    test "removes the index first, then the column" do
      versions =
        for {:up, version, name} <- Ecto.Migrator.migrations(Repo),
            name in ["add_txid_to_audit_events", "add_audit_events_org_txid_id_index"],
            into: %{},
            do: {name, version}

      assert %{
               "add_txid_to_audit_events" => column_version,
               "add_audit_events_org_txid_id_index" => index_version
             } = versions

      assert is_integer(column_version) and is_integer(index_version)
      assert index_version > column_version
    end

    test "the column migration's down drops the column the up added",
         %{column_migration: migration} do
      Repo.query!("CREATE TEMP TABLE txid_rollback (id bigserial PRIMARY KEY)")
      "txid_rollback" |> migration.column_statements() |> Enum.each(&Repo.query!/1)
      "txid_rollback" |> migration.down_statements() |> Enum.each(&Repo.query!/1)

      assert scalar("""
             SELECT count(*) FROM information_schema.columns
             WHERE table_name = 'txid_rollback' AND column_name = 'txid'
             """) == 0

      assert hd(migration.down_statements("audit_events")) == "SET LOCAL lock_timeout = '10s'"
    end
  end

  describe "the index migration" do
    test "index audit_events_org_txid_id_index exists on organization_id, txid and id, and is valid" do
      assert [[definition, true]] =
               rows("""
               SELECT pg_get_indexdef(indexrelid), indisvalid FROM pg_index
               WHERE indrelid = 'audit_events'::regclass AND indexrelid = '#{@index}'::regclass
               """)

      assert definition =~ "(organization_id, txid, id)"
    end

    test "is built concurrently, in its own migration with no DDL transaction or lock",
         %{index_migration: migration} do
      assert Keyword.fetch!(migration.__migration__(), :disable_ddl_transaction)
      assert Keyword.fetch!(migration.__migration__(), :disable_migration_lock)
      assert File.read!(@index_migration) =~ "concurrently: true"
    end
  end

  describe "new rows" do
    test "a row inserted by AuditLog.event/2 has txid > 0 equal to its transaction's id" do
      organization = organization_fixture()

      assert AuditLog.event(:organization_updated, organization_id: organization.id) == :ok

      assert [txid] = stored_txids()
      assert txid > 0
      assert txid == own_txid()
    end

    test "a site event, with no Organization, also gets a txid" do
      user = user_fixture()

      assert AuditLog.event(:sudo_mode_entered, user_id: user.id) == :ok

      assert [%AuditEvent{organization_id: nil, txid: txid}] = Repo.all(AuditEvent)
      assert txid == own_txid()
    end

    test "two events in one Repo.transaction share one txid" do
      user = user_fixture()

      assert {:ok, txid} =
               Repo.transact(fn ->
                 :ok = AuditLog.event(:sudo_mode_entered, user_id: user.id)
                 :ok = AuditLog.event(:sudo_mode_entered, user_id: user.id)
                 {:ok, own_txid()}
               end)

      assert stored_txids() == [txid, txid]
    end
  end

  describe "application code never writes txid" do
    test "insert_changeset/1 drops a txid in attrs and the stored txid is the database's" do
      changeset = AuditEvent.insert_changeset(%{action: "txid_probe", txid: 5})

      refute Map.has_key?(changeset.changes, :txid)

      assert {:ok, %AuditEvent{txid: nil}} = Repo.insert(changeset)
      assert stored_txids() == [own_txid()]
    end

    test "a struct insert does not write txid either" do
      Repo.insert!(%AuditEvent{action: "txid_probe", metadata: %{}, txid: 5})

      {insertable, _never_written} = AuditEvent.__schema__(:insertable_fields)
      refute :txid in insertable
      assert stored_txids() == [own_txid()]
    end

    test "the INSERT AuditLog.event/2 sends never names the column" do
      attach_telemetry([:kanban, :repo, :query])

      assert AuditLog.event(:sudo_mode_entered, []) == :ok

      assert_received {:telemetry_event, _, _,
                       %{query: "INSERT INTO \"audit_events\"" <> _ = sql}}

      refute sql =~ "txid"
    end
  end

  describe "the hardened end state" do
    test "the app-like role stores a real txid, cannot alter the column or index, and status stays :hardened" do
      organization = organization_fixture()
      role = AuditLogRoleHelper.switch_to_app_like_role()

      log =
        capture_log(fn ->
          assert AuditLog.event(:organization_updated, organization_id: organization.id) == :ok
        end)

      refute log =~ "security_audit_persist_failed"
      assert stored_txids() == [own_txid()]

      assert owner_of_table() == Hardening.owner_role()
      assert_refused("ALTER TABLE audit_events ALTER COLUMN txid SET DEFAULT 0")
      assert_refused("ALTER TABLE audit_events DROP COLUMN txid")
      assert_refused("DROP INDEX #{@index}")

      assert Hardening.status(runner(), app_role: role) == :hardened
    end

    # D10: the database does not stop the application role from naming txid,
    # because its INSERT right covers every column. This pins the accepted
    # risk so nobody reads the schema's `writable: :never` as a database
    # guarantee.
    test "the app-like role can still name txid in a raw INSERT (accepted risk, D10)" do
      AuditLogRoleHelper.switch_to_app_like_role()

      assert {:ok, _} =
               attempt("""
               INSERT INTO audit_events (action, metadata, inserted_at, txid)
               VALUES ('d10_probe', '{}', now(), 5)
               """)

      assert stored_txids() == [5]
    end
  end
end
