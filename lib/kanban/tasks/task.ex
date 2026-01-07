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
    field :type, Ecto.Enum, values: [:work, :defect, :goal], default: :work
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

    # AI Context Fields (W23)
    field :security_considerations, {:array, :string}, default: []
    field :testing_strategy, :map, default: %{}
    field :integration_points, :map, default: %{}

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

    # Archive tracking
    field :archived_at, :utc_datetime

    # Hierarchy
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
    has_many :children, __MODULE__, foreign_key: :parent_id

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
  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
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
      # AI Context Fields (W23)
      :security_considerations,
      :testing_strategy,
      :integration_points,
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
      :parent_id,
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
      :reviewed_at,
      # Archive tracking
      :archived_at
    ])
    |> validate_embed_type(:key_files, attrs)
    |> validate_embed_type(:verification_steps, attrs)
    |> cast_embed(:key_files, with: &validate_key_file_embed/2)
    |> cast_embed(:verification_steps, with: &validate_verification_step_embed/2)
    |> normalize_ai_context_fields()
    |> validate_required([:title, :position, :type, :priority, :status])
    |> validate_inclusion(:type, [:work, :defect, :goal],
      message: "must be 'work', 'defect', or 'goal'"
    )
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical],
      message: "must be 'low', 'medium', 'high', or 'critical'"
    )
    |> validate_inclusion(:complexity, [:small, :medium, :large],
      message: "must be 'small', 'medium', or 'large'"
    )
    |> validate_inclusion(:status, [:open, :in_progress, :completed, :blocked],
      message: "must be 'open', 'in_progress', 'completed', or 'blocked'"
    )
    |> validate_inclusion(:actual_complexity, [:small, :medium, :large],
      message: "must be 'small', 'medium', or 'large'"
    )
    |> validate_inclusion(:review_status, [:pending, :approved, :changes_requested, :rejected],
      message: "must be 'pending', 'approved', 'changes_requested', or 'rejected'"
    )
    |> validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)
    |> validate_technology_requirements()
    |> validate_required_capabilities()
    |> validate_dependencies()
    |> validate_claim_expiration()
    |> validate_completion_fields()
    |> validate_review_fields()
    |> validate_security_considerations()
    |> validate_testing_strategy()
    |> validate_integration_points()
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:assigned_to_id)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:completed_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end

  # Validate that embed fields are arrays before casting
  defp validate_embed_type(changeset, field, attrs) do
    field_str = to_string(field)

    case Map.get(attrs, field_str) || Map.get(attrs, field) do
      nil ->
        changeset

      [] ->
        # Empty arrays are valid - just means no embedded records
        changeset

      value when is_list(value) ->
        validate_embed_array_items(changeset, field, value)

      _non_list_value ->
        add_error(changeset, field, embed_type_error_message(field, :not_array))
    end
  end

  defp validate_embed_array_items(changeset, field, value) do
    if Enum.all?(value, &is_map/1) do
      changeset
    else
      add_error(changeset, field, embed_type_error_message(field, :not_objects))
    end
  end

  defp embed_type_error_message(field, error_type) do
    case {field, error_type} do
      {:key_files, :not_objects} ->
        "must be an array of objects with file_path, note, and position fields"

      {:verification_steps, :not_objects} ->
        "must be an array of objects with step_type, step_text, expected_result, and position fields"

      {_, :not_objects} ->
        "must be an array of objects"

      {:key_files, :not_array} ->
        "must be an array of objects with file_path, note, and position fields"

      {:verification_steps, :not_array} ->
        "must be an array of objects with step_type, step_text, expected_result, and position fields"

      {_, :not_array} ->
        "must be an array"
    end
  end

  # Custom embed validation with better error messages
  defp validate_key_file_embed(key_file, attrs) do
    KeyFile.changeset(key_file, attrs)
    |> improve_embed_errors(:key_files)
  end

  defp validate_verification_step_embed(step, attrs) do
    VerificationStep.changeset(step, attrs)
    |> improve_embed_errors(:verification_steps)
  end

  defp improve_embed_errors(changeset, field_name) do
    # If the changeset is valid, return it as-is
    if changeset.valid? do
      changeset
    else
      # Otherwise, enhance error messages for better clarity
      case field_name do
        :key_files ->
          enhance_key_file_errors(changeset)

        :verification_steps ->
          enhance_verification_step_errors(changeset)

        _ ->
          changeset
      end
    end
  end

  defp enhance_key_file_errors(changeset) do
    changeset
    |> update_error_message(
      :file_path,
      "can't be blank",
      "is required (relative path from project root)"
    )
    |> update_error_message(:position, "can't be blank", "is required (integer starting from 0)")
  end

  defp enhance_verification_step_errors(changeset) do
    changeset
    |> update_error_message(:step_type, "can't be blank", "is required ('command' or 'manual')")
    |> update_error_message(:step_text, "can't be blank", "is required (command or instruction)")
    |> update_error_message(:position, "can't be blank", "is required (integer starting from 0)")
    |> update_error_message(:step_type, "is invalid", "must be 'command' or 'manual'")
  end

  defp update_error_message(changeset, field, old_msg, new_msg) do
    errors = changeset.errors

    updated_errors =
      Enum.map(errors, fn
        {^field, {^old_msg, opts}} -> {field, {new_msg, opts}}
        error -> error
      end)

    %{changeset | errors: updated_errors}
  end

  defp normalize_ai_context_fields(changeset) do
    changeset
    |> normalize_field(:security_considerations, [])
    |> normalize_field(:testing_strategy, %{})
    |> normalize_field(:integration_points, %{})
  end

  defp normalize_field(changeset, field, default) do
    case get_change(changeset, field) do
      nil ->
        if is_nil(get_field(changeset, field)) do
          put_change(changeset, field, default)
        else
          changeset
        end

      _value ->
        changeset
    end
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
        changeset
        |> validate_dependencies_format(deps)
        |> validate_no_circular_dependencies(deps)

      _ ->
        add_error(changeset, :dependencies, "must be a list")
    end
  end

  defp validate_dependencies_format(changeset, deps) do
    if Enum.all?(deps, &is_binary/1) do
      changeset
    else
      add_error(changeset, :dependencies, "must be a list of task identifiers (strings)")
    end
  end

  defp validate_no_circular_dependencies(changeset, deps) do
    task_id = get_field(changeset, :id)
    task_identifier = get_field(changeset, :identifier)

    cond do
      is_nil(task_id) && is_nil(task_identifier) ->
        changeset

      task_identifier && task_identifier in deps ->
        add_error(changeset, :dependencies, "cannot depend on itself")

      task_id ->
        if has_circular_dependency?(task_id, deps) do
          add_error(changeset, :dependencies, "creates a circular dependency")
        else
          changeset
        end

      true ->
        changeset
    end
  end

  defp has_circular_dependency?(task_id, dependency_identifiers) do
    alias Kanban.Repo

    task = Repo.get(__MODULE__, task_id)

    if is_nil(task) do
      false
    else
      visited = MapSet.new()
      check_circular_dependency(task.identifier, dependency_identifiers, visited)
    end
  end

  defp check_circular_dependency(_current_identifier, [], _visited), do: false

  defp check_circular_dependency(current_identifier, dependency_identifiers, visited) do
    alias Kanban.Repo
    import Ecto.Query

    tasks =
      from(t in __MODULE__,
        where: t.identifier in ^dependency_identifiers,
        select: {t.identifier, t.dependencies}
      )
      |> Repo.all()

    Enum.any?(tasks, fn {identifier, deps} ->
      deps = deps || []

      cond do
        current_identifier in deps ->
          true

        identifier in visited ->
          false

        true ->
          visited = MapSet.put(visited, identifier)
          check_circular_dependency(current_identifier, deps, visited)
      end
    end)
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

  defp validate_security_considerations(changeset) do
    case get_field(changeset, :security_considerations) do
      nil ->
        changeset

      [] ->
        changeset

      items when is_list(items) ->
        if Enum.all?(items, &is_binary/1) do
          changeset
        else
          add_error(changeset, :security_considerations, "must be a list of strings")
        end

      _ ->
        add_error(changeset, :security_considerations, "must be a list")
    end
  end

  defp validate_testing_strategy(changeset) do
    case get_field(changeset, :testing_strategy) do
      nil ->
        changeset

      %{} = strategy when map_size(strategy) == 0 ->
        changeset

      %{} = strategy ->
        # Validate that all values are strings or arrays of strings
        validate_testing_strategy_values(changeset, strategy)

      _ ->
        add_error(
          changeset,
          :testing_strategy,
          "must be a JSON object with string or array values describing testing approach (e.g., {\"unit_tests\": \"Test each function\", \"edge_cases\": [\"Empty input\", \"Invalid data\"]})"
        )
    end
  end

  defp validate_testing_strategy_values(changeset, strategy) do
    invalid_values =
      Enum.reject(strategy, fn {_key, value} ->
        is_binary(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
      end)

    if Enum.empty?(invalid_values) do
      changeset
    else
      invalid_keys = Enum.map(invalid_values, fn {key, _value} -> key end)

      add_error(
        changeset,
        :testing_strategy,
        "all values must be strings or arrays of strings. Invalid keys: #{Enum.join(invalid_keys, ", ")}"
      )
    end
  end

  defp validate_integration_points(changeset) do
    case get_field(changeset, :integration_points) do
      nil ->
        changeset

      %{} = points when map_size(points) == 0 ->
        changeset

      %{} = points ->
        # Validate that all values are strings or arrays of strings
        validate_integration_points_values(changeset, points)

      _ ->
        add_error(
          changeset,
          :integration_points,
          "must be a JSON object with string or array values describing integration points (e.g., {\"external_api\": \"Stripe API\", \"pubsub\": [\"TaskUpdated\", \"BoardUpdated\"]})"
        )
    end
  end

  defp validate_integration_points_values(changeset, points) do
    invalid_values =
      Enum.reject(points, fn {_key, value} ->
        is_binary(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
      end)

    if Enum.empty?(invalid_values) do
      changeset
    else
      invalid_keys = Enum.map(invalid_values, fn {key, _value} -> key end)

      add_error(
        changeset,
        :integration_points,
        "all values must be strings or arrays of strings. Invalid keys: #{Enum.join(invalid_keys, ", ")}"
      )
    end
  end
end
