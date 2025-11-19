defmodule Kanban.Repo.Migrations.AddAssignedToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :assigned_to_id, references(:users, on_delete: :nilify_all)
    end

    create index(:tasks, [:assigned_to_id])
  end
end
