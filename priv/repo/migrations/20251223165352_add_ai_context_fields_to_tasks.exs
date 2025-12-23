defmodule Kanban.Repo.Migrations.AddAiContextFieldsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :security_considerations, {:array, :string}, default: []
      add :testing_strategy, :map, default: %{}
      add :integration_points, :map, default: %{}
    end
  end
end
