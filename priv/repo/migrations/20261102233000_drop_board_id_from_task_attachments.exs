defmodule Kanban.Repo.Migrations.DropBoardIdFromTaskAttachments do
  use Ecto.Migration

  # task_attachments.board_id was a copy of the task's board, set at upload
  # and never kept in step with it: nothing in the database tied it to
  # tasks -> columns -> boards, and a task can change columns. The quota
  # summed by it and its ON DELETE CASCADE deleted by it, so a stale or wrong
  # value counted a file against the wrong Organization and let deleting one
  # board remove another board's files (G488 exploratory campaign, decided
  # 2026-11-02). Every reader now derives the board from the task's column,
  # and deleting a board still removes its files through
  # boards -> columns -> tasks -> task_attachments, all ON DELETE CASCADE.
  #
  # Storage keys keep their boards/<id>/ prefix: it names where the blob was
  # stored, not which board the file belongs to now.
  def up do
    drop index(:task_attachments, [:board_id])

    alter table(:task_attachments) do
      remove :board_id
    end
  end

  # Restores the column from each row's task, as the upload used to set it.
  def down do
    alter table(:task_attachments) do
      add :board_id, references(:boards, on_delete: :delete_all)
    end

    execute """
    UPDATE task_attachments AS a
    SET board_id = c.board_id
    FROM tasks AS t
    JOIN columns AS c ON c.id = t.column_id
    WHERE t.id = a.task_id
    """

    execute "ALTER TABLE task_attachments ALTER COLUMN board_id SET NOT NULL"

    create index(:task_attachments, [:board_id])
  end
end
