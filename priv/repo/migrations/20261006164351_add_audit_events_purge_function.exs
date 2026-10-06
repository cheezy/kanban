defmodule Kanban.Repo.Migrations.AddAuditEventsPurgeFunction do
  use Ecto.Migration

  alias Kanban.AuditLog.Hardening.Purge

  # Gives retention one narrow path for removing old audit rows and, where the
  # table is hardened, stops the append-only trigger trusting the
  # transaction-local purge flag that any role allowed to delete could set.
  # The statements live in Kanban.AuditLog.Hardening.Purge.
  #
  # Up installs the hardened purge (an owner-role-owned SECURITY DEFINER
  # purge function and an owner-aware trigger body) only when it runs as a
  # superuser and 20261006155407_move_audit_events_ownership has already
  # handed the table to the owner role. Otherwise it installs the degraded
  # purge (the function owned by the migrating role, the flag-based trigger
  # left as it is) and logs one degraded notice; it never fails for lack of
  # privilege, which matters because production deploys run migrations as the
  # application role.
  #
  # Down drops the purge function and restores the flag-based trigger body.
  # That is the body from 20261006153642_fix_audit_events_truncate_message, not
  # the one from 20261006102406_create_audit_events: the earlier body gave
  # TRUNCATE the misleading "outside the retention purge" message that
  # 20261006153642 fixed. The search_path pin added by the ownership migration
  # is kept. Anything the migrating role cannot own is left in place with a
  # logged degraded notice.
  def up do
    runner = sql_runner()
    %{rows: [[app_role]]} = runner.("SELECT current_user")

    Purge.migrate_or_degrade(runner, app_role: app_role)
  end

  def down do
    Purge.revert(sql_runner())
  end

  defp sql_runner, do: fn sql -> repo().query!(sql) end
end
