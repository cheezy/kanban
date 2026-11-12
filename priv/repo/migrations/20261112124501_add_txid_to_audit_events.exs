defmodule Kanban.Repo.Migrations.AddTxidToAuditEvents do
  @moduledoc """
  Records on each audit event the id of the transaction that inserted it, so
  audit streaming can read rows in (`txid`, `id`) order below its snapshot
  horizon and never skip a row that commits late. Neither `id`, which comes
  from a sequence, nor `inserted_at`, which comes from the application, is
  enough for that, because `Kanban.AuditLog.event/2` often runs inside the
  caller's transaction. `txid` is not commit order either: a transaction that
  takes its id early and commits last sorts first, which is why the reader
  stops at the horizon (§7.2) rather than trusting the order alone. See §9.1
  of `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`.

  The column is added with a constant default of `0`, which does not rewrite
  the table, so every row that existed before this migration reads `0`. No
  existing row is updated, because the append-only trigger rejects every row
  edit. The default is then changed to the inserting transaction's id, so
  every new row records it.

  Both `ALTER`s take an `ACCESS EXCLUSIVE` lock. They run under a
  transaction-local `lock_timeout` of 10 seconds, so the lock request never
  waits indefinitely behind a long transaction with every audit insert queued
  behind it. The bound is not zero: while the request waits, for up to 10
  seconds, audit inserts queue behind it and hold their pool connections, so
  under heavy traffic some can time out and be logged as
  `security_audit_persist_failed` instead of stored. Run it when traffic is
  low. A `lock_not_available` failure changes nothing: run the migration again
  when the long transaction has ended. `SET LOCAL` only has an effect inside a
  transaction, so this migration keeps Ecto's DDL transaction.

  In a hardened database (see `Kanban.AuditLog.Hardening`) only the owner of
  `audit_events` can alter it, so this migration must run there as that owner
  role or as a superuser. Dev, test and CI migrate as a superuser, and a
  degraded database (the application role owns the table) migrates as usual.
  The new default calls only `pg_catalog` functions, so the hardening status
  is unchanged. `docs/audit-log-database-roles.md` has both procedures.
  """

  use Ecto.Migration

  @lock_timeout "SET LOCAL lock_timeout = '10s'"

  @doc """
  The statements `up/0` runs, in order, for `table`.

  `table` is always a fixed identifier: `audit_events` here, and a temporary
  table in the migration's test, which rehearses these exact statements.
  Rolling back runs the index migration's `down` first, because its version
  is later, and then `down_statements/1`.
  """
  def column_statements(table) do
    [
      @lock_timeout,
      "ALTER TABLE #{table} ADD COLUMN txid bigint NOT NULL DEFAULT 0",
      "ALTER TABLE #{table} ALTER COLUMN txid SET DEFAULT (pg_current_xact_id()::text::bigint)"
    ]
  end

  def up do
    Enum.each(column_statements("audit_events"), &execute/1)
  end

  @doc """
  The statements `down/0` runs, in order, for `table`; see `column_statements/1`.
  """
  def down_statements(table) do
    [@lock_timeout, "ALTER TABLE #{table} DROP COLUMN txid"]
  end

  def down do
    Enum.each(down_statements("audit_events"), &execute/1)
  end
end
