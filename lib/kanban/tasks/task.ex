defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, :string
    field :position, :integer
    field :type, Ecto.Enum, values: [:work, :defect], default: :work
    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium
    field :identifier, :string

    # Planning & Context (01A)
    field :complexity, Ecto.Enum, values: [:small, :medium, :large], default: :small
    field :estimated_files, :string
    field :why, :string
    field :what, :string
    field :where_context, :string

    # Implementation Guidance (01A)
    field :patterns_to_follow, :string
    field :database_changes, :string
    field :validation_rules, :string

    # Observability (01A)
    field :telemetry_event, :string
    field :metrics_to_track, :string
    field :logging_requirements, :string

    # Error Handling (01A)
    field :error_user_message, :string
    field :error_on_failure, :string

    belongs_to :column, Kanban.Columns.Column
    belongs_to :assigned_to, Kanban.Accounts.User
    has_many :task_histories, Kanban.Tasks.TaskHistory
    has_many :comments, Kanban.Tasks.TaskComment

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      # Existing
      :title,
      :description,
      :acceptance_criteria,
      :position,
      :column_id,
      :type,
      :priority,
      :identifier,
      :assigned_to_id,
      # Planning & Context
      :complexity,
      :estimated_files,
      :why,
      :what,
      :where_context,
      # Implementation Guidance
      :patterns_to_follow,
      :database_changes,
      :validation_rules,
      # Observability
      :telemetry_event,
      :metrics_to_track,
      :logging_requirements,
      # Error Handling
      :error_user_message,
      :error_on_failure
    ])
    |> validate_required([:title, :position, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> validate_inclusion(:complexity, [:small, :medium, :large])
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:assigned_to_id)
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end
end
