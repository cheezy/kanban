defmodule Kanban.Repo.Migrations.AddWorkflowStepsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :workflow_steps, :jsonb, default: "[]"
    end

    create index(:tasks, [:workflow_steps], using: :gin)
  end
end
