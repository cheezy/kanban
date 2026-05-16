defmodule Kanban.Repo.Migrations.AddArchiveMetadataToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :archive_reason, :string
      add :archive_note, :text
      add :archived_by_id, references(:users, on_delete: :nilify_all)
      add :duplicate_of_id, references(:tasks, on_delete: :nilify_all)
    end

    create index(:tasks, [:archived_by_id])

    # Partial index — only a small fraction of tasks (those archived as
    # :duplicate) ever populate :duplicate_of_id, so a full b-tree would
    # bloat the index and slow writes on the hot path. The spec's
    # "do not index duplicate_of_id without nulls_distinct considerations"
    # pitfall lands here.
    create index(:tasks, [:duplicate_of_id], where: "duplicate_of_id IS NOT NULL")

    create constraint(:tasks, :archive_reason_must_be_valid,
             check:
               "archive_reason IS NULL OR " <>
                 "archive_reason IN ('completed', 'duplicate', 'wontdo', 'deferred', 'cancelled')"
           )

    create constraint(:tasks, :duplicate_of_id_not_self,
             check: "duplicate_of_id IS NULL OR duplicate_of_id <> id"
           )
  end
end
