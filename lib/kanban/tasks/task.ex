defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Schemas.Task.KeyFile
  alias Kanban.Schemas.Task.VerificationStep

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

    # JSONB collections (01B)
    embeds_many :key_files, KeyFile, on_replace: :delete
    embeds_many :verification_steps, VerificationStep, on_replace: :delete
    field :technology_requirements, {:array, :string}
    field :pitfalls, {:array, :string}
    field :out_of_scope, {:array, :string}

    # Creator tracking (02)
    field :created_by_agent, :string

    # Completion tracking (02)
    field :completed_at, :utc_datetime
    field :completed_by_agent, :string
    field :completion_summary, :string

    # Task relationships (02)
    field :dependencies, {:array, :string}, default: []

    # Status tracking (02)
    field :status, Ecto.Enum, values: [:open, :in_progress, :completed, :blocked], default: :open

    # Claim tracking (02)
    field :claimed_at, :utc_datetime
    field :claim_expires_at, :utc_datetime

    # Agent capabilities (02)
    field :required_capabilities, {:array, :string}, default: []

    # Actual vs estimated (02)
    field :actual_complexity, Ecto.Enum, values: [:small, :medium, :large]
    field :actual_files_changed, :string
    field :time_spent_minutes, :integer

    # Review queue (02)
    field :needs_review, :boolean, default: false
    field :review_status, Ecto.Enum, values: [:pending, :approved, :changes_requested, :rejected]
    field :review_notes, :string
    field :reviewed_at, :utc_datetime

    belongs_to :column, Kanban.Columns.Column
    belongs_to :assigned_to, Kanban.Accounts.User
    belongs_to :created_by, Kanban.Accounts.User
    belongs_to :completed_by, Kanban.Accounts.User
    belongs_to :reviewed_by, Kanban.Accounts.User
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
      :error_on_failure,
      # Simple JSONB arrays (01B)
      :technology_requirements,
      :pitfalls,
      :out_of_scope,
      # Creator tracking (02)
      :created_by_id,
      :created_by_agent,
      # Completion tracking (02)
      :completed_at,
      :completed_by_id,
      :completed_by_agent,
      :completion_summary,
      # Task relationships (02)
      :dependencies,
      # Status tracking (02)
      :status,
      # Claim tracking (02)
      :claimed_at,
      :claim_expires_at,
      # Agent capabilities (02)
      :required_capabilities,
      # Actual vs estimated (02)
      :actual_complexity,
      :actual_files_changed,
      :time_spent_minutes,
      # Review queue (02)
      :needs_review,
      :review_status,
      :review_notes,
      :reviewed_by_id,
      :reviewed_at
    ])
    |> cast_embed(:key_files)
    |> cast_embed(:verification_steps)
    |> validate_required([:title, :position, :type, :priority, :status])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> validate_inclusion(:complexity, [:small, :medium, :large])
    |> validate_inclusion(:status, [:open, :in_progress, :completed, :blocked])
    |> validate_inclusion(:actual_complexity, [:small, :medium, :large])
    |> validate_inclusion(:review_status, [:pending, :approved, :changes_requested, :rejected])
    |> validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)
    |> validate_technology_requirements()
    |> validate_required_capabilities()
    |> validate_dependencies()
    |> validate_claim_expiration()
    |> validate_completion_fields()
    |> validate_review_fields()
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:assigned_to_id)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:completed_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end

  defp validate_technology_requirements(changeset) do
    case get_field(changeset, :technology_requirements) do
      nil ->
        changeset

      [] ->
        changeset

      techs when is_list(techs) ->
        if Enum.all?(techs, &is_binary/1) do
          changeset
        else
          add_error(changeset, :technology_requirements, "must be a list of strings")
        end

      _ ->
        add_error(changeset, :technology_requirements, "must be a list")
    end
  end

  defp validate_required_capabilities(changeset) do
    case get_field(changeset, :required_capabilities) do
      nil ->
        changeset

      [] ->
        changeset

      caps when is_list(caps) ->
        if Enum.all?(caps, &is_binary/1) do
          changeset
        else
          add_error(changeset, :required_capabilities, "must be a list of strings")
        end

      _ ->
        add_error(changeset, :required_capabilities, "must be a list")
    end
  end

  defp validate_dependencies(changeset) do
    case get_field(changeset, :dependencies) do
      nil ->
        changeset

      [] ->
        changeset

      deps when is_list(deps) ->
        if Enum.all?(deps, &is_binary/1) do
          changeset
        else
          add_error(changeset, :dependencies, "must be a list of task identifiers (strings)")
        end

      _ ->
        add_error(changeset, :dependencies, "must be a list")
    end
  end

  defp validate_claim_expiration(changeset) do
    claimed_at = get_field(changeset, :claimed_at)
    claim_expires_at = get_field(changeset, :claim_expires_at)

    case {claimed_at, claim_expires_at} do
      {nil, nil} ->
        changeset

      {%DateTime{}, %DateTime{}} ->
        if DateTime.compare(claim_expires_at, claimed_at) == :gt do
          changeset
        else
          add_error(changeset, :claim_expires_at, "must be after claimed_at")
        end

      {nil, %DateTime{}} ->
        add_error(changeset, :claimed_at, "must be set when claim_expires_at is set")

      {%DateTime{}, nil} ->
        changeset
    end
  end

  defp validate_completion_fields(changeset) do
    status = get_field(changeset, :status)
    completed_at = get_field(changeset, :completed_at)

    if status == :completed and is_nil(completed_at) do
      add_error(changeset, :completed_at, "must be set when status is completed")
    else
      changeset
    end
  end

  defp validate_review_fields(changeset) do
    review_status = get_field(changeset, :review_status)

    if review_status_requires_metadata?(review_status) do
      changeset
      |> validate_reviewed_at(review_status)
      |> validate_reviewed_by_id(review_status)
    else
      changeset
    end
  end

  defp review_status_requires_metadata?(status) do
    not is_nil(status) and status != :pending
  end

  defp validate_reviewed_at(changeset, review_status) do
    if review_status_requires_metadata?(review_status) and
         is_nil(get_field(changeset, :reviewed_at)) do
      add_error(changeset, :reviewed_at, "must be set when review_status is not pending")
    else
      changeset
    end
  end

  defp validate_reviewed_by_id(changeset, review_status) do
    if review_status_requires_metadata?(review_status) and
         is_nil(get_field(changeset, :reviewed_by_id)) do
      add_error(changeset, :reviewed_by_id, "must be set when review_status is not pending")
    else
      changeset
    end
  end
end
