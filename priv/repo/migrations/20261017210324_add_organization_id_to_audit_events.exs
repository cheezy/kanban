defmodule Kanban.Repo.Migrations.AddOrganizationIdToAuditEvents do
  @moduledoc """
  Scopes audit events to an Organization for the org-admin audit log at
  `/org/audit` (W2397).

  `organization_id` is nullable and filled only for events recorded from now
  on. No existing row is touched: the append-only trigger rejects every row
  edit, and every Organization event recorded before this migration predates
  launch.

  The foreign key uses `on_delete: :nothing`. A cascading `nilify_all` would
  have to edit audit rows, which the trigger refuses for every column except
  `actor_user_id`. Organizations are never deleted, so the plain constraint
  never blocks anything in practice.

  The composite index serves the org viewer's keyset paging: equality on
  `organization_id`, then newest first by `inserted_at` with `id` breaking ties.

  In a hardened database (see `Kanban.AuditLog.Hardening`) only the owner of
  `audit_events` can alter it, so this migration must run there as that owner
  role or as a superuser. Dev, test and CI migrate as a superuser, and a
  degraded database (the application role owns the table) migrates as usual.
  The foreign key adds only internal triggers backed by built-in functions, and
  the index calls no user function, so the hardening status is unchanged.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_events) do
      add :organization_id, references(:organizations, on_delete: :nothing)
    end

    create index(:audit_events, [:organization_id, :inserted_at, :id])
  end
end
