defmodule Kanban.Repo.Migrations.AddChangedFilesToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :changed_files, :jsonb, default: "[]"
    end

    create index(:tasks, [:changed_files], using: :gin)
  end
end
