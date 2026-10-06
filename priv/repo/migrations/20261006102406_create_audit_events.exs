defmodule Kanban.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  # audit_events is append-only. The trigger below is the enforcement point, so
  # the guarantee holds for every database client, not just Kanban.AuditLog:
  #
  #   * UPDATE is rejected, with one exception: the `on_delete: :nilify_all`
  #     foreign-key cascade that nulls actor_user_id when a user is deleted.
  #     That cascade runs from inside Postgres's own RI trigger (so
  #     pg_trigger_depth() > 1) and changes nothing but actor_user_id.
  #   * TRUNCATE is always rejected — the purge deletes row by row, so nothing
  #     legitimate ever needs it.
  #   * DELETE is rejected unless the transaction-local setting
  #     `kanban.audit_purge` is 'on' — the retention purge sets it with
  #     `SELECT set_config('kanban.audit_purge', 'on', true)`. The third
  #     argument (is_local) must be true: a session-level setting would stay on
  #     for every later transaction on that pooled connection.
  #
  # The role that owns the table can disable or drop the trigger, so ownership
  # moves to a separate owner role in 20261006155407_move_audit_events_ownership
  # (statements in Kanban.AuditLog.Hardening).
  def up do
    create table(:audit_events) do
      add :action, :string, null: false
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :ip, :string
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_events, [:inserted_at])
    create index(:audit_events, [:action])
    create index(:audit_events, [:actor_user_id])

    execute """
    CREATE FUNCTION audit_events_append_only() RETURNS trigger AS $$
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

    execute """
    CREATE TRIGGER audit_events_append_only_rows
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_events_append_only()
    """

    execute """
    CREATE TRIGGER audit_events_append_only_truncate
    BEFORE TRUNCATE ON audit_events
    FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only()
    """
  end

  def down do
    drop table(:audit_events)
    execute "DROP FUNCTION IF EXISTS audit_events_append_only()"
  end
end
