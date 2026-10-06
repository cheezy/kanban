defmodule Kanban.Repo.Migrations.FixAuditEventsTruncateMessage do
  use Ecto.Migration

  # 20261006102406_create_audit_events gave TRUNCATE and an unflagged DELETE one
  # shared message, "... % is not permitted outside the retention purge". That
  # wording is false for TRUNCATE, which the trigger rejects unconditionally —
  # the `kanban.audit_purge` setting only ever admits DELETE.
  #
  # This replaces the function body so TRUNCATE raises its own message. Every
  # branch is otherwise copied verbatim, so no rule is loosened, and the DELETE
  # and UPDATE messages are unchanged. CREATE OR REPLACE keeps the function's
  # identity, owner and privileges, so both existing triggers keep firing it;
  # the table and the triggers are not touched. The applied migration above is
  # left as history: fresh databases run both and end up identical.
  def up do
    execute """
    CREATE OR REPLACE FUNCTION audit_events_append_only() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF pg_trigger_depth() > 1
           AND OLD.actor_user_id IS NOT NULL
           AND NEW.actor_user_id IS NULL
           AND (to_jsonb(NEW) - 'actor_user_id') = (to_jsonb(OLD) - 'actor_user_id') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'audit_events is append-only: UPDATE is not permitted';
      END IF;

      IF TG_OP = 'DELETE'
         AND coalesce(current_setting('kanban.audit_purge', true), '') = 'on' THEN
        RETURN OLD;
      END IF;

      IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'audit_events is append-only: TRUNCATE is not permitted';
      END IF;

      RAISE EXCEPTION 'audit_events is append-only: % is not permitted outside the retention purge', TG_OP;
    END;
    $$ LANGUAGE plpgsql
    """
  end

  # Restores the previous body rather than dropping the function: both triggers
  # depend on it.
  def down do
    execute """
    CREATE OR REPLACE FUNCTION audit_events_append_only() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF pg_trigger_depth() > 1
           AND OLD.actor_user_id IS NOT NULL
           AND NEW.actor_user_id IS NULL
           AND (to_jsonb(NEW) - 'actor_user_id') = (to_jsonb(OLD) - 'actor_user_id') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'audit_events is append-only: UPDATE is not permitted';
      END IF;

      IF TG_OP = 'DELETE'
         AND coalesce(current_setting('kanban.audit_purge', true), '') = 'on' THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION 'audit_events is append-only: % is not permitted outside the retention purge', TG_OP;
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
