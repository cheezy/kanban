defmodule Kanban.Repo.Migrations.AddHumanTaskToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :human_task, :boolean, default: false, null: false
    end
  end
end
