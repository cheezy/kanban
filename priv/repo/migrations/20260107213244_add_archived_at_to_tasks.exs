defmodule Kanban.Repo.Migrations.AddArchivedAtToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :archived_at, :utc_datetime
    end
  end
end
