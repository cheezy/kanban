defmodule Kanban.Repo.Migrations.AddAuditEventsOrgTxidIdIndex do
  use Ecto.Migration

  # Audit streaming reads an Organization's events in (txid, id) order, below
  # its snapshot horizon and after the last (txid, id) it delivered (§7.2 and §9.1 of
  # docs/plans/AUDIT-LOG-STREAMING-DESIGN.md), so the index matches that order:
  # organization_id, then txid, then id.
  #
  # audit_events takes an insert for every security event, so the index is
  # built concurrently rather than locking writes while it builds. A concurrent
  # build also waits for every transaction open when it starts. A failed build
  # leaves an INVALID index, and one whose client was interrupted keeps running
  # on the server and can end VALID with the migration unrecorded. Either way
  # the rerun fails with duplicate_table: once no CREATE INDEX for it is still
  # running, drop it with
  #   DROP INDEX CONCURRENTLY IF EXISTS audit_events_org_txid_id_index
  # and run the migration again.
  #
  # In a hardened database only the table's owner can build an index on it;
  # docs/audit-log-database-roles.md has the procedure. The index calls no
  # function, so the hardening status is unchanged.
  def change do
    create index(:audit_events, [:organization_id, :txid, :id],
             name: :audit_events_org_txid_id_index,
             concurrently: true
           )
  end

  # Concurrent index creation cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true
end
