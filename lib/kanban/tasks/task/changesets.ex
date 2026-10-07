defmodule Kanban.Tasks.Task.Changesets do
  @moduledoc """
  The full-task changeset and the two strict API changesets for
  `Kanban.Tasks.Task`, together with the API cast allow-lists.

  Split from `Kanban.Tasks.Task` to keep the schema module under the project's
  module-size guideline. `Kanban.Tasks.Task.changeset/2`,
  `Kanban.Tasks.Task.api_create_changeset/2` and
  `Kanban.Tasks.Task.api_update_changeset/2` delegate here, so callers keep
  using the `Kanban.Tasks.Task` entry points. The validation stages each
  pipeline runs live in the sibling `Kanban.Tasks.Task.*` modules; their order
  here is part of the contract (it decides which errors a changeset carries).
  """

  import Ecto.Changeset

  alias Kanban.Tasks.Task.ArchiveChangeset
  alias Kanban.Tasks.Task.Capabilities
  alias Kanban.Tasks.Task.EmbedValidations
  alias Kanban.Tasks.Task.FieldValidations
  alias Kanban.Tasks.Task.HierarchyValidations
  alias Kanban.Tasks.Task.LengthValidations
  alias Kanban.Tasks.Task.MapFieldValidations

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
      :technical_details,
      # Creator tracking (02)
      :created_by_id,
      :created_by_agent,
      # Completion tracking (02)
      :completed_at,
      :completed_by_id,
      :completed_by_agent,
      :completion_summary,
      :completion_notes,
      # Task relationships (02)
      :dependencies,
      :parent_id,
      :target_id,
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
      # Human task flag
      :human_task,
      # Review queue (02)
      :needs_review,
      :review_status,
      :review_notes,
      :review_report,
      :workflow_steps,
      :explorer_result,
      :reviewer_result,
      :changed_files,
      :reviewed_by_id,
      :reviewed_at,
      # Archive tracking
      :archived_at,
      :archive_reason,
      :archive_note,
      :archived_by_id,
      :duplicate_of_id
    ])
    |> EmbedValidations.validate_embed_type(:key_files, attrs)
    |> EmbedValidations.validate_embed_type(:verification_steps, attrs)
    |> EmbedValidations.validate_embed_type(:behaviour_test_matrix, attrs)
    |> cast_embed(:key_files, with: &EmbedValidations.validate_key_file_embed/2)
    |> cast_embed(:verification_steps, with: &EmbedValidations.validate_verification_step_embed/2)
    |> cast_embed(:behaviour_test_matrix,
      with: &EmbedValidations.validate_behaviour_test_row_embed/2
    )
    |> FieldValidations.normalize_ai_context_fields()
    |> validate_required([:title, :position, :type, :priority, :status])
    |> validate_inclusion(:type, [:work, :defect, :goal],
      message: "must be 'work', 'defect', or 'goal'"
    )
    |> HierarchyValidations.validate_goal_has_no_parent()
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
    |> LengthValidations.validate_varchar_255_lengths()
    |> LengthValidations.validate_varchar_255_array_element_lengths()
    # Field-level invariant, not endpoint-level: `completion_notes` is durable
    # and re-rendered into the Review queue, and this changeset is a second
    # writer (the task form) besides the completion endpoint (D188).
    |> validate_length(:completion_notes, max: 65_535)
    |> validate_number(:time_spent_minutes, greater_than_or_equal_to: 0)
    |> FieldValidations.validate_technology_requirements()
    |> Capabilities.validate_required_capabilities()
    |> FieldValidations.validate_dependencies()
    |> FieldValidations.validate_claim_expiration()
    |> FieldValidations.validate_completion_fields()
    |> FieldValidations.validate_review_fields()
    |> ArchiveChangeset.validate_archive_fields()
    |> FieldValidations.validate_target_requires_goal_type()
    |> MapFieldValidations.validate_security_considerations()
    |> MapFieldValidations.validate_testing_strategy()
    |> MapFieldValidations.validate_integration_points()
    |> MapFieldValidations.validate_technical_details()
    |> MapFieldValidations.validate_behaviour_test_matrix_completeness()
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:assigned_to_id)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:completed_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
    |> foreign_key_constraint(:archived_by_id)
    |> foreign_key_constraint(:duplicate_of_id)
    |> foreign_key_constraint(:target_id)
    |> check_constraint(:duplicate_of_id,
      name: :duplicate_of_id_not_self,
      message: "must not reference the task itself"
    )
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end

  # Strict allow-list of fields mutable via the public PATCH /api/tasks/:id endpoint.
  # Workflow/audit/identity fields (status, assigned_to_id, claimed_at, completed_at,
  # completed_by_id, reviewed_by_id, review_status, identifier, parent_id, position,
  # column_id, created_by_id, time_spent_minutes, archived_at, …) are intentionally
  # omitted — those are set only by the dedicated workflow endpoints
  # (claim/complete/mark_reviewed/unclaim), which bypass this changeset entirely.
  #
  # The embeds (key_files, verification_steps, behaviour_test_matrix) are
  # deliberately absent: `cast/3` raises "casting embeds with cast/4 ... is not
  # supported, use cast_embed/3 instead" for any embed in its permitted list.
  # Both API paths cast them through the explicit `cast_embed/3` calls in
  # `api_create_changeset/2` and `api_update_changeset/2`, which read straight
  # from the changeset params and need no entry here.
  @api_update_fields [
    # Descriptive
    :title,
    :description,
    :acceptance_criteria,
    :why,
    :what,
    :where_context,
    :estimated_files,
    :patterns_to_follow,
    :database_changes,
    :validation_rules,
    :pitfalls,
    :out_of_scope,
    # Categorization (non-workflow)
    :type,
    :priority,
    :complexity,
    # JSONB arrays / maps
    :technology_requirements,
    :required_capabilities,
    :security_considerations,
    :testing_strategy,
    :integration_points,
    :technical_details,
    :dependencies,
    # Observability hints
    :telemetry_event,
    :metrics_to_track,
    :logging_requirements,
    # Error-handling hints
    :error_user_message,
    :error_on_failure,
    # Misc
    :human_task,
    :needs_review
  ]

  # Allow-list for the API create path. Mirrors `@api_update_fields` and adds the
  # fields that the server injects during creation (identifier from the locked
  # Multi step, column_id/position from the column lookup + Positioning helpers,
  # created_by_id/created_by_agent from the API-token scope + agent_name header,
  # parent_id when a goal seeds child tasks). Client-supplied values for those
  # injected fields must be stripped at the controller layer — the changeset
  # cannot distinguish "from Multi" vs "from JSON payload" once they land in attrs.
  @api_create_fields @api_update_fields ++
                       [
                         :identifier,
                         :column_id,
                         :position,
                         :created_by_id,
                         :created_by_agent,
                         :parent_id
                       ]

  @doc """
  Strict changeset for API POST /api/tasks (and POST /api/tasks/batch).

  Casts only descriptive fields plus the server-controlled creation fields the
  Multi step injects (identifier, position, column_id, created_by_id,
  created_by_agent, parent_id). The controller is responsible for stripping any
  client-supplied values for those server-controlled fields before the Multi
  runs. Workflow/audit fields (status defaults to :open via the schema,
  claimed_at/completed_*/reviewed_*/archived_at/etc. are not cast at all) can
  never reach a newly-inserted row through this path.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  def api_create_changeset(task, attrs) do
    task
    |> cast(attrs, @api_create_fields)
    |> EmbedValidations.validate_embed_type(:key_files, attrs)
    |> EmbedValidations.validate_embed_type(:verification_steps, attrs)
    |> EmbedValidations.validate_embed_type(:behaviour_test_matrix, attrs)
    |> cast_embed(:key_files, with: &EmbedValidations.validate_key_file_embed/2)
    |> cast_embed(:verification_steps, with: &EmbedValidations.validate_verification_step_embed/2)
    |> cast_embed(:behaviour_test_matrix,
      with: &EmbedValidations.validate_behaviour_test_row_embed/2
    )
    |> FieldValidations.normalize_ai_context_fields()
    |> validate_required([:title, :position, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect, :goal],
      message: "must be 'work', 'defect', or 'goal'"
    )
    |> HierarchyValidations.validate_goal_has_no_parent()
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical],
      message: "must be 'low', 'medium', 'high', or 'critical'"
    )
    |> validate_inclusion(:complexity, [:small, :medium, :large],
      message: "must be 'small', 'medium', or 'large'"
    )
    |> FieldValidations.validate_technology_requirements()
    |> Capabilities.validate_required_capabilities()
    |> FieldValidations.validate_dependencies()
    |> MapFieldValidations.validate_security_considerations()
    |> MapFieldValidations.validate_testing_strategy()
    |> MapFieldValidations.validate_integration_points()
    |> MapFieldValidations.validate_technical_details()
    |> MapFieldValidations.validate_behaviour_test_matrix_completeness()
    |> LengthValidations.validate_varchar_255_lengths()
    |> LengthValidations.validate_varchar_255_array_element_lengths()
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:created_by_id)
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end

  @doc """
  Strict changeset for API PATCH /api/tasks/:id.

  Casts only descriptive fields; workflow/audit fields cannot be mass-assigned
  through this path. See `@api_update_fields` for the authoritative allow-list.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  def api_update_changeset(task, attrs) do
    task
    |> cast(attrs, @api_update_fields)
    |> EmbedValidations.validate_embed_type(:key_files, attrs)
    |> EmbedValidations.validate_embed_type(:verification_steps, attrs)
    |> EmbedValidations.validate_embed_type(:behaviour_test_matrix, attrs)
    |> cast_embed(:key_files, with: &EmbedValidations.validate_key_file_embed/2)
    |> cast_embed(:verification_steps, with: &EmbedValidations.validate_verification_step_embed/2)
    |> cast_embed(:behaviour_test_matrix,
      with: &EmbedValidations.validate_behaviour_test_row_embed/2
    )
    |> FieldValidations.normalize_ai_context_fields()
    |> validate_required([:title, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect, :goal],
      message: "must be 'work', 'defect', or 'goal'"
    )
    |> HierarchyValidations.validate_goal_has_no_parent()
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical],
      message: "must be 'low', 'medium', 'high', or 'critical'"
    )
    |> validate_inclusion(:complexity, [:small, :medium, :large],
      message: "must be 'small', 'medium', or 'large'"
    )
    |> FieldValidations.validate_technology_requirements()
    |> Capabilities.validate_required_capabilities()
    |> FieldValidations.validate_dependencies()
    |> MapFieldValidations.validate_security_considerations()
    |> MapFieldValidations.validate_testing_strategy()
    |> MapFieldValidations.validate_integration_points()
    |> MapFieldValidations.validate_technical_details()
    |> MapFieldValidations.validate_behaviour_test_matrix_completeness()
    |> LengthValidations.validate_varchar_255_lengths()
    |> LengthValidations.validate_varchar_255_array_element_lengths()
  end
end
