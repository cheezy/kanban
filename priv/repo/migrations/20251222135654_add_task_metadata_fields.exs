defmodule Kanban.Repo.Migrations.AddTaskMetadataFields do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Creator tracking
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :created_by_agent, :string

      # Completion tracking
      add :completed_at, :utc_datetime
      add :completed_by_id, references(:users, on_delete: :nilify_all)
      add :completed_by_agent, :string
      add :completion_summary, :text

      # Task relationships (array of task IDs)
      add :dependencies, {:array, :bigint}, default: []

      # Status tracking (stored as string, mapped to Ecto.Enum in schema)
      add :status, :string, default: "open", null: false

      # Claim tracking for agent assignment
      add :claimed_at, :utc_datetime
      add :claim_expires_at, :utc_datetime

      # Agent capabilities required
      add :required_capabilities, {:array, :string}, default: []

      # Actual vs estimated tracking
      add :actual_complexity, :string
      add :actual_files_changed, :text
      add :time_spent_minutes, :integer

      # Review queue
      add :needs_review, :boolean, default: false, null: false
      add :review_status, :string
      add :review_notes, :text
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
    end

    # Indexes for common query patterns
    create index(:tasks, [:created_by_id])
    create index(:tasks, [:completed_by_id])
    create index(:tasks, [:status])
    create index(:tasks, [:needs_review])
    create index(:tasks, [:review_status])
    create index(:tasks, [:reviewed_by_id])
    create index(:tasks, [:claimed_at])
    create index(:tasks, [:claim_expires_at])

    # Composite index for finding available tasks to claim
    create index(:tasks, [:status, :claimed_at, :claim_expires_at])

    # Index for dependency queries
    create index(:tasks, [:dependencies], using: :gin)

    # Index for capability-based task assignment
    create index(:tasks, [:required_capabilities], using: :gin)
  end
end
