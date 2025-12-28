defmodule Kanban.Repo.Migrations.AddParentIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :parent_id, references(:tasks, on_delete: :nilify_all)
    end

    create index(:tasks, [:parent_id])
  end
end
