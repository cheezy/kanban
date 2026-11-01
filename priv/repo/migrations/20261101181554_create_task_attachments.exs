defmodule Kanban.Repo.Migrations.CreateTaskAttachments do
  use Ecto.Migration

  # task_attachments ties a stored blob to a task, and optionally to one of the
  # task's comments. Rows disappear by many paths: Repo.delete of the row,
  # Lifecycle.delete_task/1, Boards.delete_board/2, Comments.delete_comment/2,
  # the archived-task retention purge (Repo.delete_all) and account deletion,
  # most of them through ON DELETE CASCADE. Hooking each path in Elixir would
  # miss some, so the AFTER DELETE trigger below is the single point that
  # queues a removed row's blob: it copies OLD.storage_key into
  # attachment_blob_deletions, which the cleanup worker drains.
  #
  # The trigger is row-level, so it fires for every DELETE, cascaded or bulk.
  # TRUNCATE does not fire row-level triggers; never TRUNCATE task_attachments.
  #
  # Times are stored as UTC timestamps without a zone, so every default and the
  # trigger write `now() AT TIME ZONE 'UTC'` rather than a bare now(), whose
  # value would follow the session's TimeZone setting.
  #
  # attachment_blob_deletions.delete_after defaults to now. The context can
  # also park a tombstone for a pending upload with a later delete_after, so a
  # blob stored before its row is inserted is still reclaimed after a crash.
  def up do
    create table(:task_attachments) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :comment_id, references(:task_comments, on_delete: :delete_all)
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :uploaded_by_id, references(:users, on_delete: :nilify_all)
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :string, size: 64, null: false
      add :storage_key, :string, size: 512, null: false

      timestamps()
    end

    create index(:task_attachments, [:task_id])
    create index(:task_attachments, [:comment_id])
    create index(:task_attachments, [:board_id])
    create index(:task_attachments, [:uploaded_by_id])
    create unique_index(:task_attachments, [:storage_key])

    create constraint(:task_attachments, :byte_size_positive, check: "byte_size > 0")

    create table(:attachment_blob_deletions) do
      add :storage_key, :string, size: 512, null: false

      add :delete_after, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'UTC')")

      add :attempts, :integer, null: false, default: 0
      add :last_error, :string, size: 64

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'UTC')")
    end

    create index(:attachment_blob_deletions, [:delete_after])

    execute """
    CREATE FUNCTION task_attachments_queue_blob_deletion() RETURNS trigger AS $$
    BEGIN
      INSERT INTO attachment_blob_deletions (storage_key, delete_after)
      VALUES (OLD.storage_key, now() AT TIME ZONE 'UTC');

      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER task_attachments_queue_blob_deletion_rows
    AFTER DELETE ON task_attachments
    FOR EACH ROW EXECUTE FUNCTION task_attachments_queue_blob_deletion()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS task_attachments_queue_blob_deletion_rows ON task_attachments"
    execute "DROP FUNCTION IF EXISTS task_attachments_queue_blob_deletion()"

    drop table(:attachment_blob_deletions)
    drop table(:task_attachments)
  end
end
