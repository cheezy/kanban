# Add Task Metadata and Completion Tracking Fields

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** Need to track who created tasks (human vs AI), when they were completed, and store completion summaries as defined in TASKS.md format.

**WHAT:** Add metadata fields for task lifecycle: created_by_id (user FK), created_by_agent (AI model name), completed_at, completed_by_id, completed_by_agent, completion_summary (text), status, and dependencies.

**WHERE:** Task schema and migration

## Acceptance Criteria

- [ ] Migration adds metadata columns to tasks table
- [ ] Schema updated with new fields
- [ ] Dependencies stored as array of task IDs
- [ ] Completion summary stored as text field
- [ ] created_by_id references users table
- [ ] created_by_agent stores AI model name (if AI-created)
- [ ] Timestamps for completion
- [ ] Tests cover new fields

## Key Files to Read First

- `lib/kanban/schemas/task.ex` - Task schema
- `lib/kanban/tasks.ex` - Task context
- `priv/repo/migrations/XXXXXX_extend_tasks_schema.exs` - Previous migration
- `docs/WIP/TASKS.md` - Completion summary format (lines 323-385)
- `docs/WIP/AI-WORKFLOW.md` - Completion data structure (lines 73-103)
- [docs/WIP/UPDATE-TASKS/TASK-ID-GENERATION.md](TASK-ID-GENERATION.md) - Prefixed ID system (E, F, W, D)

## Technical Notes

**Patterns to Follow:**
- Use foreign key for created_by_id (references users.id)
- Store AI model name in created_by_agent (e.g., "claude-sonnet-4.5")
- Store completion summary as text field (JSON string or formatted text)
- Array of integers for dependencies (other task IDs)
- Use Ecto timestamps for completed_at

**Database/Schema:**
- Tables: tasks (keep flat structure)
- Migrations needed: Yes - add metadata columns
- Fields to add:
  - `created_by_id` (bigint, references users) - User who created task
  - `created_by_agent` (string) - AI model name if AI-created (e.g., "claude-sonnet-4.5")
  - `completed_at` (utc_datetime) - When task was completed
  - `completed_by_id` (bigint, references users) - User who completed task
  - `completed_by_agent` (string) - AI model name if AI-completed
  - `completion_summary` (text) - JSON string or formatted text with completion details
  - `dependencies` (array of bigint) - Other task IDs this task depends on
  - `status` (string) - "open", "in_progress", "completed", "blocked"
  - `claimed_at` (utc_datetime) - When task was claimed by an agent
  - `claim_expires_at` (utc_datetime) - When claim expires (60 minutes from claimed_at)
  - `required_capabilities` (array of string) - Agent capabilities required to work on this task (e.g., `["code_generation", "database_design"]`). Empty array means any agent can claim it.
  - `actual_complexity` (string) - Actual complexity experienced (small, medium, large) - reported by agent on completion
  - `actual_files_changed` (integer) - Actual number of files modified - reported by agent on completion
  - `time_spent_minutes` (integer) - Actual time spent in minutes - reported by agent on completion
  - `needs_review` (boolean, default: false) - Whether task requires human review before being marked as complete
  - `review_status` (string) - Review status (pending, approved, changes_requested, rejected) - set by human reviewer
  - `review_notes` (text) - Human feedback on the completed work
  - `reviewed_by_id` (bigint, references users) - User who reviewed the task
  - `reviewed_at` (utc_datetime) - When the task was reviewed

**Integration Points:**

- [ ] PubSub broadcasts: Broadcast when task fields change (status, column, review status, etc.)
- [ ] Phoenix Channels: Update all connected clients on task changes
- [ ] Broadcast events: task_created, task_updated, task_status_changed, task_moved, task_reviewed
- [ ] External APIs: None

**PubSub Topics:**

- `tasks:board:{board_id}` - All task changes for a board
- `tasks:task:{task_id}` - Specific task changes

**Broadcast Payload:**

```elixir
%{
  event: "task_updated",  # or task_created, task_status_changed, task_moved, task_reviewed
  task: %{
    id: task.id,
    title: task.title,
    status: task.status,
    column_id: task.column_id,
    needs_review: task.needs_review,
    review_status: task.review_status,
    claimed_at: task.claimed_at,
    completed_at: task.completed_at,
    # ... all relevant fields
  },
  changes: %{
    status: {old_value, new_value},
    column_id: {old_value, new_value}
  }
}
```

## Verification

**Commands to Run:**
```bash
# Create and run migration
mix ecto.gen.migration add_task_metadata
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.{Repo, Schemas.Task, Tasks}

# Create task with metadata (by human user)
{:ok, task} = Tasks.create_task(%{
  title: "Test task",
  created_by_id: 1,  # User ID
  created_by_agent: nil,  # Not AI-created
  status: "in_progress",
  dependencies: []
})

# Create task by AI agent
{:ok, ai_task} = Tasks.create_task(%{
  title: "AI-created task",
  created_by_id: 1,  # User who authorized the AI
  created_by_agent: "claude-sonnet-4.5",
  status: "open"
})

# Complete task (by AI agent)
{:ok, completed} = Tasks.complete_task(task, %{
  completed_by_id: 1,
  completed_by_agent: "claude-sonnet-4.5",
  completion_summary: """
  Files Changed:
  - lib/kanban_web/live/board_live.ex: Added priority filter dropdown
  - lib/kanban_web/live/board_live.html.heex: Added filter UI

  Tests Added:
  - test/kanban_web/live/board_live_test.exs

  Verification Results:
  - Commands: mix test, mix precommit
  - Status: passed
  - Output: All tests passed

  Implementation Notes:
  - Deviations: Added nil handling
  - Discoveries: Existing pattern worked well
  - Edge Cases: Tasks without priority show in All filter

  Telemetry Added: [:kanban, :filter, :used]
  Known Limitations: Sorting not implemented
  """
})

# Run tests
mix test test/kanban/tasks_test.exs
mix precommit
```

**Manual Testing:**
1. Create task via iex with created_by_id field
2. Create task with created_by_agent field (AI-created)
3. Update task status to "in_progress"
4. Complete task with completion_summary text
5. Verify timestamps set correctly
6. Create tasks with dependencies
7. Verify PubSub broadcasts status changes
8. Query tasks created by AI vs human

**Success Looks Like:**
- New metadata columns in database
- Can track task creator (user ID + optional AI model)
- Completion summary stored as text
- Dependencies work
- Status transitions tracked
- All tests pass

## Data Examples

**Migration:**
```elixir
defmodule Kanban.Repo.Migrations.AddTaskMetadata do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Creator tracking
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :created_by_agent, :string  # AI model name if AI-created

      # Completion tracking
      add :completed_at, :utc_datetime
      add :completed_by_id, references(:users, on_delete: :nilify_all)
      add :completed_by_agent, :string  # AI model name if AI-completed
      add :completion_summary, :text  # Formatted text or JSON string

      # Task relationships and status
      add :dependencies, {:array, :bigint}, default: []
      add :status, :string, default: "open"

      # Claim tracking (for task 08 - auto-release after 60 minutes)
      add :claimed_at, :utc_datetime
      add :claim_expires_at, :utc_datetime

      # Agent capability matching (for task 08 - filter by agent capabilities)
      add :required_capabilities, {:array, :string}, default: []

      # Estimation feedback loop (for task 09 - track actual vs estimated)
      add :actual_complexity, :string
      add :actual_files_changed, :integer
      add :time_spent_minutes, :integer

      # Human review queue (for human feedback on completed work)
      add :needs_review, :boolean, default: false  # Whether task requires human review
      add :review_status, :string  # pending, approved, changes_requested, rejected
      add :review_notes, :text
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
    end

    create index(:tasks, [:created_by_id])
    create index(:tasks, [:completed_by_id])
    create index(:tasks, [:status])
    create index(:tasks, [:created_by_agent])
    create index(:tasks, [:claim_expires_at])
    create index(:tasks, [:status, :claim_expires_at])
    create index(:tasks, [:actual_complexity])
    create index(:tasks, [:needs_review])
    create index(:tasks, [:review_status])
    create index(:tasks, [:reviewed_by_id])
  end
end
```

**Schema Update:**
```elixir
defmodule Kanban.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    # ... existing fields ...

    # Creator tracking
    belongs_to :created_by, Kanban.Schemas.User
    field :created_by_agent, :string

    # Completion tracking
    field :completed_at, :utc_datetime
    belongs_to :completed_by, Kanban.Schemas.User
    field :completed_by_agent, :string
    field :completion_summary, :string

    # Task relationships and status
    field :dependencies, {:array, :integer}, default: []
    field :status, :string, default: "open"

    # Claim tracking
    field :claimed_at, :utc_datetime
    field :claim_expires_at, :utc_datetime

    # Agent capability matching
    field :required_capabilities, {:array, :string}, default: []

    # Estimation feedback loop
    field :actual_complexity, :string
    field :actual_files_changed, :integer
    field :time_spent_minutes, :integer

    # Human review queue
    field :needs_review, :boolean, default: false
    field :review_status, :string
    field :review_notes, :string
    belongs_to :reviewed_by, Kanban.Schemas.User
    field :reviewed_at, :utc_datetime

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title, :description, :created_by_id, :created_by_agent,
      :completed_at, :completed_by_id, :completed_by_agent,
      :completion_summary, :dependencies, :status,
      :claimed_at, :claim_expires_at, :required_capabilities,
      :actual_complexity, :actual_files_changed, :time_spent_minutes,
      :needs_review, :review_status, :review_notes, :reviewed_by_id, :reviewed_at
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, ["open", "in_progress", "completed", "blocked"])
    |> validate_inclusion(:actual_complexity, ["small", "medium", "large"], allow_nil: true)
    |> validate_inclusion(:review_status, ["pending", "approved", "changes_requested", "rejected"], allow_nil: true)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:completed_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
  end
end
```

**Completion Summary Text Format:**
```
Files Changed:
- lib/kanban_web/live/board_live.ex: Added priority filter dropdown
- lib/kanban_web/live/board_live.html.heex: Added filter UI

Tests Added:
- test/kanban_web/live/board_live_test.exs

Verification Results:
- Commands: mix test, mix precommit
- Status: passed
- Output: All 512 tests passed

Implementation Notes:
- Deviations: Added nil handling for tasks without priority
- Discoveries: Existing filter pattern worked perfectly
- Edge Cases: Tasks with nil priority show in 'All' filter

Telemetry Added: [:kanban, :filter, :used]
Follow-up Tasks: None
Known Limitations: Sorting by priority not implemented yet
```

**Helper Functions:**
```elixir
defmodule Kanban.Tasks do
  # Check if task was created by AI
  def ai_created?(%Task{created_by_agent: agent}) when is_binary(agent), do: true
  def ai_created?(_), do: false

  # Get creator display name
  def creator_name(%Task{created_by_agent: agent, created_by: user}) when is_binary(agent) do
    "AI: #{agent} (authorized by #{user.email})"
  end
  def creator_name(%Task{created_by: user}) do
    user.email
  end

  # Parse completion summary for API
  def parse_completion_summary(nil), do: nil
  def parse_completion_summary(text) when is_binary(text) do
    # Can parse structured text or decode JSON string
    # For now, return as-is for display
    text
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :task, :status_changed]`
- [ ] Telemetry event: `[:kanban, :task, :completed]`
- [ ] Metrics: Counter of tasks completed, by creator type
- [ ] Logging: Log task completion at info level with summary

## Error Handling

- User sees: Validation errors if completion_summary malformed
- On failure: Task status remains unchanged
- Validation: Validate status transitions (can't go from completed to open)

## Common Pitfalls

- [ ] Don't forget to validate status transitions
- [ ] Remember to broadcast status changes via PubSub
- [ ] Don't forget created_by_id must reference existing user
- [ ] Remember dependencies must reference valid task IDs
- [ ] Remember completed_at should be set automatically on completion
- [ ] Avoid circular dependencies in task relationships
- [ ] Don't forget to set created_by_agent for AI-created tasks
- [ ] Remember to handle nil completion_summary gracefully

## Dependencies

**Requires:** 01-extend-task-schema.md
**Blocks:** 04-implement-task-crud-api.md, 06-add-task-completion-tracking.md

## Out of Scope

- Don't implement dependency resolution logic yet
- Don't add UI for dependencies
- Don't implement automatic task unblocking
- Don't add API endpoints yet
