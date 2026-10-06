defmodule Kanban.Repo.Migrations.MoveAuditEventsOwnership do
  use Ecto.Migration

  alias Kanban.AuditLog.Hardening

  # Closes the limitation noted in 20261006102406_create_audit_events: the role
  # that owns audit_events (or the schema holding it) can disable, drop or
  # replace its append-only trigger. Kanban.AuditLog.Hardening hands the table,
  # its id sequence, the trigger function and their schema to a cluster-wide
  # owner role the application cannot log in as or assume, and leaves the
  # migrating role (the application role) with INSERT and SELECT on the table,
  # USAGE on the sequence, and USAGE and CREATE on the schema.
  #
  # Moving ownership needs a superuser, and production deploys run this
  # migration as the application role (fly.production.toml release_command). So
  # the up step hardens only as a superuser (dev, test, CI); any other role gets
  # one logged degraded notice and the migration still finishes. Granting the
  # application role membership of the owner role instead would hand back the
  # very rights this removes, so it is never done.
  #
  # The migration only knows its own role. After hardening it checks the result
  # with Hardening.status/2 and logs a degraded notice for anything left open:
  # in dev and test that is app_role_is_superuser. Where migrations run as a
  # superuser but the application connects as another role, that role must be
  # hardened separately by calling Hardening.apply/2 with its name.
  #
  # The down step hands ownership back to the migrating role, again only as a
  # superuser. It never removes the owner role: roles are cluster-wide, and
  # other databases on the cluster (test partitions, review apps) may use it.
  def up do
    runner = sql_runner()
    app_role = current_role(runner)

    Hardening.migrate_or_degrade(runner, app_role: app_role)
  end

  def down do
    Hardening.revert(sql_runner())
  end

  defp sql_runner, do: fn sql -> repo().query!(sql) end

  defp current_role(runner) do
    %{rows: [[role]]} = runner.("SELECT current_user")
    role
  end
end
