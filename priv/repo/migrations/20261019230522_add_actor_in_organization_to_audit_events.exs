defmodule Kanban.Repo.Migrations.AddActorInOrganizationToAuditEvents do
  @moduledoc """
  Records, on each Organization event, whether its actor was a member of that
  Organization when the event was written, so the org-admin audit log redacts
  from that fact rather than from who is a member now.

  `actor_in_organization` is nullable: it is set only when an event has both an
  actor and an Organization, and only for events recorded from now on. No
  existing row is touched, because the append-only trigger rejects every row
  edit; `Kanban.AuditLog.OrganizationScope` falls back to current membership
  for those older rows, all of which predate launch.

  In a hardened database (see `Kanban.AuditLog.Hardening`) only the owner of
  `audit_events` can alter it, so this migration must run there as that owner
  role or as a superuser. Dev, test and CI migrate as a superuser, and a
  degraded database (the application role owns the table) migrates as usual.
  A plain boolean column with no default calls no function, so the hardening
  status is unchanged.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_events) do
      add :actor_in_organization, :boolean
    end
  end
end
