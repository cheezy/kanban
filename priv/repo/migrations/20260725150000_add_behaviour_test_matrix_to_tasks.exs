defmodule Kanban.Repo.Migrations.AddBehaviourTestMatrixToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :behaviour_test_matrix, :jsonb, default: "[]"
    end

    # GIN index matching the other jsonb collection columns on :tasks
    # (key_files, verification_steps) for containment queries.
    create index(:tasks, [:behaviour_test_matrix], using: :gin)
  end
end
