defmodule Kanban.Tasks.Task do
  @moduledoc """
  Schema and validations for tasks in the Stride task management system.

  Tasks represent work items that can be assigned to humans or AI agents.
  They support hierarchical relationships (goals with children), dependency
  tracking, capability matching, and comprehensive metadata for AI-assisted
  development.

  ## Task Types

  - `:work` - Feature implementation, enhancement, or general development work
  - `:defect` - Bug fix or correction
  - `:goal` - Large initiative containing multiple child tasks

  ## Task Lifecycle

  1. Created in Ready column (`:open` status)
  2. Claimed by agent or assigned to human (`:in_progress` status, claim tracking)
  3. Work completed (`:completed` status, completion metadata)
  4. Optional review cycle (`:needs_review`, review tracking)
  5. Finalized as Done or returned for changes

  ## Field Categories

  ### Core Fields
  - `title` - Short description (required)
  - `description` - Detailed explanation
  - `acceptance_criteria` - Definition of done
  - `type` - :work, :defect, or :goal (required)
  - `priority` - :low, :medium, :high, or :critical (required)
  - `complexity` - :small, :medium, or :large
  - `status` - :open, :in_progress, :completed, or :blocked

  ### Planning & Context
  - `why` - Problem/value explanation
  - `what` - Specific change description
  - `where_context` - Location in code/UI
  - `estimated_files` - Files expected to change

  ### Implementation Guidance
  - `patterns_to_follow` - Code patterns to replicate
  - `database_changes` - Schema modifications needed
  - `validation_rules` - Input validation requirements
  - `key_files` - Critical files to modify (embeds)
  - `verification_steps` - How to verify completion (embeds)
  - `pitfalls` - What NOT to do
  - `out_of_scope` - Explicitly excluded functionality

  ### AI Context
  - `required_capabilities` - Agent skills needed (e.g., ["code_generation", "testing"])
  - `security_considerations` - Security implications
  - `testing_strategy` - Comprehensive testing approach
  - `integration_points` - External systems/events involved
  - `technical_details` - Free-form technical implementation notes (any JSON object)
  - `technology_requirements` - Specific tools/libraries needed

  ### Observability
  - `telemetry_event` - Event name to emit
  - `metrics_to_track` - What to measure
  - `logging_requirements` - Logging expectations

  ### Error Handling
  - `error_user_message` - User-facing error message
  - `error_on_failure` - Error to raise on failure

  ### Tracking & Relationships
  - `dependencies` - Task identifiers that must complete first
  - `parent_id` - Parent goal (for hierarchical structure)
  - `created_by` / `created_by_agent` - Creator tracking
  - `completed_by` / `completed_by_agent` - Completer tracking
  - `claimed_at` / `claim_expires_at` - Claim tracking
  - `needs_review` / `review_status` - Review workflow
  - `actual_complexity` / `actual_files_changed` / `time_spent_minutes` - Actuals vs estimates

  ## Examples

  ### Basic Task

      %Task{
        title: "Add user login endpoint",
        description: "Implement POST /api/login with JWT authentication",
        type: :work,
        priority: :high,
        complexity: :medium,
        acceptance_criteria: "Returns JWT token on valid credentials"
      }

  ### Task with AI Context

      %Task{
        title: "Implement OAuth2 authentication",
        type: :work,
        required_capabilities: ["code_generation", "security_analysis"],
        security_considerations: [
          "Store tokens securely",
          "Validate redirect URIs",
          "Use PKCE for mobile apps"
        ],
        testing_strategy: %{
          "unit_tests" => ["Test token generation", "Test token validation"],
          "integration_tests" => ["Full OAuth2 flow"],
          "edge_cases" => ["Expired tokens", "Invalid client IDs"]
        },
        key_files: [
          %{file_path: "lib/auth/oauth.ex", note: "Main OAuth logic", position: 0},
          %{file_path: "test/auth/oauth_test.exs", note: "Test coverage", position: 1}
        ],
        verification_steps: [
          %{step_type: "command", step_text: "mix test test/auth/oauth_test.exs", expected_result: "All OAuth tests pass", position: 0},
          %{step_type: "command", step_text: "mix credo --strict lib/auth/oauth.ex", expected_result: "No code issues", position: 1},
          %{step_type: "manual", step_text: "Test OAuth flow in browser with valid credentials", expected_result: "Successfully authenticate and receive token", position: 2},
          %{step_type: "manual", step_text: "Test OAuth flow with expired token", expected_result: "Proper error message and redirect", position: 3}
        ]
      }

  ### Goal with Children

      %Task{
        title: "User Authentication System",
        type: :goal,
        complexity: :large,
        children: [
          %Task{title: "Database schema for users", type: :work},
          %Task{title: "Login endpoint", type: :work, dependencies: ["W1"]},
          %Task{title: "Password reset flow", type: :work, dependencies: ["W2"]}
        ]
      }

  ## Validations

  The changesets live in `Kanban.Tasks.Task.Changesets` (archive path:
  `Kanban.Tasks.Task.ArchiveChangeset`) and this module delegates to them.
  See the validation modules for details on:
  - `Kanban.Tasks.Task.Capabilities` - Must be valid capability strings
  - `Kanban.Tasks.Task.FieldValidations` - No circular dependencies; claim,
    completion, review and target cross-field rules
  - `Kanban.Tasks.Task.MapFieldValidations` - Proper JSON structure
  - `Kanban.Tasks.Task.EmbedValidations` - key_files / verification_steps
    arrays of objects; behaviour_test_matrix rows with fixed
    category/status/type vocabularies and a test_name-or-na_reason rule
  - `Kanban.Tasks.Task.HierarchyValidations` - A goal never has a parent
  - `Kanban.Tasks.Task.LengthValidations` - varchar(255) length caps
  """

  use Ecto.Schema

  alias Kanban.Schemas.Task.BehaviourTestRow
  alias Kanban.Schemas.Task.KeyFile
  alias Kanban.Schemas.Task.VerificationStep
  alias Kanban.Tasks.Task.ArchiveChangeset
  alias Kanban.Tasks.Task.Capabilities
  alias Kanban.Tasks.Task.Changesets
  alias Kanban.Tasks.Task.LengthValidations

  @typedoc "A task or goal row (the `tasks` table)."
  @type t :: %__MODULE__{}

  @doc "Valid `required_capabilities` strings. See `Kanban.Tasks.Task.Capabilities`."
  defdelegate valid_capabilities, to: Capabilities

  schema "tasks" do
    # Core Fields (Required)
    # Short task description - Example: "Add user login endpoint"
    field :title, :string

    # Detailed explanation of what needs to be done - Example: "Implement POST /api/login with JWT authentication"
    field :description, :string

    # Definition of done - Example: "Returns JWT token on valid credentials, handles invalid passwords gracefully"
    field :acceptance_criteria, :string

    # Order within column (unique per column) - Validated: >= 0, Example: 0, 1, 2
    field :position, :integer

    # Task type - Validated: :work | :defect | :goal, Default: :work
    field :type, Ecto.Enum, values: [:work, :defect, :goal], default: :work

    # Task priority - Validated: :low | :medium | :high | :critical, Default: :medium
    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium

    # Auto-generated unique ID (W42, D12, G5) - Example: "W42", "D12", "G5"
    field :identifier, :string

    # Planning & Context
    # Estimated size - Validated: :small | :medium | :large, Default: :small
    # Example: :small (<4hrs), :medium (4-16hrs), :large (>16hrs)
    field :complexity, Ecto.Enum, values: [:small, :medium, :large], default: :small

    # Files expected to change - Example: "lib/auth/*.ex, test/auth/*.exs"
    field :estimated_files, :string

    # Problem/value explanation - Example: "Users can't reset passwords, support tickets increasing"
    field :why, :string

    # Specific change needed - Example: "Add password reset flow with email verification"
    field :what, :string

    # Location in code/UI - Example: "User settings page, /lib/auth/reset_password.ex"
    field :where_context, :string

    # Implementation Guidance
    # Code patterns to replicate - Example: "Follow existing auth pattern in lib/auth/login.ex"
    field :patterns_to_follow, :string

    # Schema modifications needed - Example: "Add password_reset_tokens table with expires_at column"
    field :database_changes, :string

    # Input validation requirements - Example: "Email must be valid format, token expires after 1 hour"
    field :validation_rules, :string

    # Observability
    # Event name to emit - Example: "user.password_reset"
    field :telemetry_event, :string

    # What to measure - Example: "Reset success rate, time to complete"
    field :metrics_to_track, :string

    # Logging expectations - Example: "Log reset requests with user ID, log token generation"
    field :logging_requirements, :string

    # Error Handling
    # User-facing error message - Example: "Password reset link expired. Please request a new one."
    field :error_user_message, :string

    # Error to raise on failure - Example: "Kanban.Auth.TokenExpiredError"
    field :error_on_failure, :string

    # Critical Files (Embedded Array of Objects)
    # Format: [%{file_path: "lib/auth.ex", note: "Main auth logic", position: 0}, ...]
    # Validates: Array of objects with file_path (string), note (string), position (integer)
    embeds_many :key_files, KeyFile, on_replace: :delete

    # Verification Steps (Embedded Array of Objects)
    # Format: [%{step_type: "command", step_text: "mix test", expected_result: "All pass", position: 0}, ...]
    # Validates: step_type must be "command" or "manual", all fields required
    embeds_many :verification_steps, VerificationStep, on_replace: :delete

    # Behaviour/Test Matrix (Embedded Array of Objects)
    # Format: [%{category: "Happy path", behaviour: "claims an open task",
    #           test_name: "claims an open task", type: "unit",
    #           status: "planned", na_reason: nil, position: 0}, ...]
    # Validates: category from BehaviourTestRow.categories/0, status from
    # BehaviourTestRow.statuses/0, type a '/'-combination of unit/integration/manual,
    # and a real test_name unless the row is waived (then na_reason is required)
    embeds_many :behaviour_test_matrix, BehaviourTestRow, on_replace: :delete

    # Specific tools/libraries - Validated: Array of strings, Example: ["bcrypt", "jason", "ecto"]
    field :technology_requirements, {:array, :string}

    # What NOT to do - Validated: Array of strings
    # Example: ["Don't modify existing login flow", "Avoid storing passwords in plain text"]
    field :pitfalls, {:array, :string}

    # Explicitly excluded - Validated: Array of strings
    # Example: ["Social login", "2FA", "Account recovery via SMS"]
    field :out_of_scope, {:array, :string}

    # AI Context
    # Security implications - Validated: Array of strings
    # Example: ["Store tokens securely", "Use PKCE for mobile", "Rate limit requests"]
    field :security_considerations, {:array, :string}, default: []

    # Comprehensive testing approach - Validated: Map with string or array values
    # Example: %{"unit_tests" => ["Test token gen"], "edge_cases" => ["Expired tokens", "Invalid emails"]}
    field :testing_strategy, :map, default: %{}

    # External systems/events - Validated: Map with string or array values
    # Example: %{"email_service" => "SendGrid", "pubsub" => ["UserPasswordReset", "UserNotified"]}
    field :integration_points, :map, default: %{}

    # Free-form technical implementation notes - Validated: Map only (inner keys/values unvalidated)
    # Example: %{"db_migration" => "Add column", "rollback" => %{"steps" => ["..."]}}
    field :technical_details, :map, default: %{}

    # Creator Tracking
    # Agent model that created task - Example: "claude-sonnet-4-5", "gpt-4"
    field :created_by_agent, :string

    # Completion Tracking
    # When completed - Validated: Must be set when status=:completed
    field :completed_at, :utc_datetime

    # Agent that completed - Example: "claude-sonnet-4-5"
    field :completed_by_agent, :string

    # Work summary - Example: "Implemented JWT auth with refresh tokens. All tests passing."
    field :completion_summary, :string

    # Long-form completion narrative, distinct from the required one-line
    # `completion_summary`. Optional and agent-authored; it is the named channel
    # for findings a human must read (exploratory-testing results, a refused
    # behaviour-matrix row). Rendered to humans on the Review queue, so it is
    # escaped like any other user-supplied string (D188).
    # Example: "Parser rejects UTF-16 input; parked as an off-charter finding."
    field :completion_notes, :string

    # Task Relationships
    # Tasks that must finish first - Validated: Array of identifiers, no circular deps
    # Example: ["W1", "W5", "D3"]
    field :dependencies, {:array, :string}, default: []

    # Status Tracking
    # Current state - Validated: :open | :in_progress | :completed | :blocked, Default: :open
    field :status, Ecto.Enum, values: [:open, :in_progress, :completed, :blocked], default: :open

    # Claim Tracking
    # When claimed - Validated: Must be before claim_expires_at
    field :claimed_at, :utc_datetime

    # When claim expires - Validated: Must be after claimed_at
    field :claim_expires_at, :utc_datetime

    # Agent Capabilities
    # Required skills - Validated: Must be valid capability strings from valid_capabilities/0
    # Example: ["code_generation", "testing", "security_analysis"]
    field :required_capabilities, {:array, :string}, default: []

    # Actuals vs Estimates
    # Actual size after completion - Validated: :small | :medium | :large
    field :actual_complexity, Ecto.Enum, values: [:small, :medium, :large]

    # Files actually changed - Example: "lib/auth/oauth.ex, lib/auth/token.ex, test/auth_test.exs"
    field :actual_files_changed, :string

    # Time spent in minutes - Validated: >= 0, Example: 45, 120, 360
    field :time_spent_minutes, :integer

    # Human Task
    # When true, task is for human workers only and cannot be claimed by agents
    field :human_task, :boolean, default: false

    # Review Workflow
    # Requires human approval - Default: false
    field :needs_review, :boolean, default: false

    # Review state - Validated: :pending | :approved | :changes_requested | :rejected
    # Note: :approved/:changes_requested/:rejected require reviewed_at and reviewed_by_id
    field :review_status, Ecto.Enum, values: [:pending, :approved, :changes_requested, :rejected]

    # Reviewer feedback - Example: "Great work! Minor: add error handling for edge case X"
    field :review_notes, :string

    # Structured review report from task-reviewer agent
    field :review_report, :string

    # Workflow step records from agent hooks (before_doing, after_doing, before_review, after_review)
    field :workflow_steps, {:array, :map}, default: []

    # Per-file diff entries submitted by the agent at completion time.
    # Shape per `docs/diff-contract.md`: `[%{"path" => string, "diff" => string | nil, "diff_url" => string | nil}]`.
    # Pre-validated by `Kanban.Tasks.CompletionValidation.validate_changed_files/1`. Optional; legacy
    # completion payloads without this field continue to validate and persist as `[]`.
    field :changed_files, {:array, :map}, default: []

    # Explorer subagent result submitted at task completion (pre-validated by Kanban.Tasks.CompletionValidation)
    field :explorer_result, :map

    # Reviewer subagent result submitted at task completion (pre-validated by Kanban.Tasks.CompletionValidation)
    field :reviewer_result, :map

    # When reviewed - Validated: Required when review_status != :pending
    field :reviewed_at, :utc_datetime

    # When the task last entered the Review column (agent completion or a drag
    # in from another column). Server-set only: no changeset casts it.
    # Kanban.Reviews.waiting_since/1 ages pending reviews from it (D348).
    field :review_requested_at, :utc_datetime

    # After-Goal Tracking (W493 / G113)
    # Goal-only: set on goals when their last child completes, gating the
    # goal's transition to Done on an agent-reported `after_goal` exit
    # code of 0 (or on the Oban grace-window fallback for plugins that
    # predate after_goal). NULL on work/defect tasks and on goals whose
    # final child has not yet completed.
    field :after_goal_status, Ecto.Enum, values: [:pending, :succeeded]

    # Most-recent agent report payload for after_goal. Shape:
    # `%{"exit_code" => integer, "output" => string, "duration_ms" => integer}`.
    # Latest report wins; full audit log lives in :after_goal_attempts.
    field :after_goal_result, :map

    # Audit log of every after_goal report received for this goal,
    # newest-last. Pitfall: "the latest report wins but must be auditable"
    # — every attempt is appended here even when it does not flip
    # :after_goal_status.
    field :after_goal_attempts, {:array, :map}, default: []

    # Archive Tracking
    # When archived (soft delete)
    field :archived_at, :utc_datetime

    # Why the task was archived. nil for legacy archived rows; the LiveView
    # treats nil as :completed at render time. Drives the per-reason filter
    # and the reason-pill copy on the Archive view.
    field :archive_reason, Ecto.Enum,
      values: [:completed, :duplicate, :wontdo, :deferred, :cancelled]

    # Free-text justification. Required when :archive_reason is :wontdo,
    # :deferred, or :cancelled; optional otherwise.
    field :archive_note, :string

    # Hierarchy
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
    has_many :children, __MODULE__, foreign_key: :parent_id

    belongs_to :column, Kanban.Columns.Column
    belongs_to :assigned_to, Kanban.Accounts.User
    belongs_to :created_by, Kanban.Accounts.User
    belongs_to :completed_by, Kanban.Accounts.User
    belongs_to :reviewed_by, Kanban.Accounts.User
    belongs_to :archived_by, Kanban.Accounts.User
    # Delivery target this task belongs to. Nullable and permitted only on
    # goal-type tasks (enforced in changeset/2); nullifies when the target is
    # removed (on_delete: :nilify_all in the migration).
    belongs_to :target, Kanban.Targets.DeliveryTarget, foreign_key: :target_id
    # Self-FK for :duplicate reason — points at the canonical task this one
    # duplicates. Required when archive_reason is :duplicate, forbidden
    # otherwise. The DB enforces id <> duplicate_of_id via check constraint.
    belongs_to :duplicate_of, __MODULE__, foreign_key: :duplicate_of_id
    has_many :task_histories, Kanban.Tasks.TaskHistory
    has_many :comments, Kanban.Tasks.TaskComment

    timestamps()
  end

  @doc "Length-guarded varchar(255) columns (D81). See `Kanban.Tasks.Task.LengthValidations`."
  defdelegate varchar_255_fields, to: LengthValidations

  @doc "Length-guarded varchar(255)[] columns (D81). See `Kanban.Tasks.Task.LengthValidations`."
  defdelegate varchar_255_array_fields, to: LengthValidations

  @doc """
  The seven fixed behaviour/test-matrix categories.

  Single source of truth for the category vocabulary — matrix-level validations
  and any UI must call this rather than redefining the list. Delegates to
  `Kanban.Schemas.Task.BehaviourTestRow`.
  """
  defdelegate behaviour_test_categories, to: BehaviourTestRow, as: :categories

  @doc false
  defdelegate changeset(task, attrs), to: Changesets

  @doc "Strict API create changeset. See `Kanban.Tasks.Task.Changesets.api_create_changeset/2`."
  defdelegate api_create_changeset(task, attrs), to: Changesets

  @doc "Strict API update changeset. See `Kanban.Tasks.Task.Changesets.api_update_changeset/2`."
  defdelegate api_update_changeset(task, attrs), to: Changesets

  @doc """
  Focused changeset for the archive write path. Delegates to
  `Kanban.Tasks.Task.ArchiveChangeset.changeset/2`, which casts only the
  archive-metadata fields and runs the archive-reason conditional validations
  — skipping the unrelated full-task validations so archiving does not
  retroactively reject pre-existing inconsistent state on other fields.

  See `Kanban.Tasks.Lifecycle.archive_task/2` for the caller.
  """
  defdelegate archive_changeset(task, attrs), to: ArchiveChangeset, as: :changeset
end
