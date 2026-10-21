defmodule Kanban.Repo.Migrations.AddAuditEventsOrganizationPurgeFunction do
  use Ecto.Migration

  alias Kanban.AuditLog.Hardening.Purge

  # Installs audit_events_purge_organization, the Organization-scoped sibling
  # of audit_events_purge that Kanban.Retention.PurgeWorker calls. The
  # statements live in Kanban.AuditLog.Hardening.OrganizationPurge, reached
  # through Purge.
  #
  # Up installs the hardened function (owned by the owner role) only when it
  # runs as a superuser and the owner role already owns audit_events.
  # Otherwise it installs the degraded function (owned by the migrating role)
  # and logs one degraded notice; it never fails for lack of privilege, which
  # matters because production deploys run migrations as the application role.
  # On a database whose trigger is already hardened, the degraded function's
  # delete is refused until an operator re-runs Kanban.Release.harden_audit_log/0
  # (docs/audit-log-database-roles.md).
  #
  # Down drops the function. The trigger is never touched by either step.
  def up do
    runner = sql_runner()
    %{rows: [[app_role]]} = runner.("SELECT current_user")

    Purge.migrate_or_degrade_organization(runner, app_role: app_role)
  end

  def down do
    Purge.revert_organization(sql_runner())
  end

  defp sql_runner, do: fn sql -> repo().query!(sql) end
end
