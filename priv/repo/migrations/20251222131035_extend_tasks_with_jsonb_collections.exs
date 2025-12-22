defmodule Kanban.Repo.Migrations.ExtendTasksWithJsonbCollections do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :key_files, :jsonb
      add :verification_steps, :jsonb
      add :technology_requirements, :jsonb
      add :pitfalls, :jsonb
      add :out_of_scope, :jsonb
    end

    # GIN indexes for fast JSONB querying
    # These enable O(log n) lookups instead of O(n) sequential scans
    create index(:tasks, [:key_files], using: :gin)
    create index(:tasks, [:verification_steps], using: :gin)
    create index(:tasks, [:technology_requirements], using: :gin)
  end
end
