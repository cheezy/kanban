defmodule Kanban.Repo.Migrations.AddTypeAndPriorityToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :type, :string, default: "work", null: false
      add :priority, :string, default: "medium", null: false
    end
  end
end
