defmodule Kanban.Repo.Migrations.AddTechnicalDetailsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :technical_details, :map, default: %{}
    end
  end
end
