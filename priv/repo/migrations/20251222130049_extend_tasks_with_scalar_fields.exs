defmodule Kanban.Repo.Migrations.ExtendTasksWithScalarFields do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Planning & Context
      add :complexity, :string, default: "small"
      add :estimated_files, :string
      add :why, :text
      add :what, :text
      add :where_context, :text

      # Implementation Guidance
      add :patterns_to_follow, :text
      add :database_changes, :text
      add :validation_rules, :text

      # Observability
      add :telemetry_event, :string
      add :metrics_to_track, :text
      add :logging_requirements, :text

      # Error Handling
      add :error_user_message, :text
      add :error_on_failure, :text
    end

    # Add index for common query patterns
    create index(:tasks, [:complexity])

    # Add check constraint for complexity values
    create constraint(:tasks, :complexity_must_be_valid,
      check: "complexity IN ('small', 'medium', 'large')")
  end
end
