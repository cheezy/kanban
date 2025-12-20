# Feature 1: Database Schema Foundation

**Epic:** [EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
**Type:** Feature
**Identifier:** F1 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Medium (7-8 hours estimated)

## Description

Extend the database schema to store all task metadata required by the TASKS.md format. This includes 18 categories of task information: complexity, key files, verification steps, observability requirements, error handling, and lifecycle tracking (who created/completed tasks, when, and how).

**Implementation Approach:** Uses PostgreSQL JSONB for collections (key_files, verification_steps) with embedded Ecto schemas for type safety, instead of text parsing. Includes GIN indexes for efficient querying.

## Goal

By the end of this feature, the tasks table will have all necessary columns to store rich task data, and the application will be able to track task creators (human vs AI), completion status, dependencies, and completion summaries.

## Business Value

**Why This Matters:**
- Foundation for all other features in the epic
- Enables structured storage of task metadata beyond title/description
- Allows tracking of AI vs human task creation/completion
- Provides audit trail through completion summaries
- Supports task dependencies and blocking relationships

**What Changes:**
- Tasks table extended with 18+ new columns
- JSONB fields store collections (key files, verification steps, etc.) with embedded schemas
- Simple arrays for technology requirements, pitfalls, and out-of-scope items
- Foreign keys link tasks to users who created/completed them
- Task status and dependencies tracked in database
- GIN indexes enable fast JSONB querying

## Tasks

- [ ] **01A** - [01A-extend-task-schema-scalar-fields.md](01A-extend-task-schema-scalar-fields.md) - **Medium** (2-3 hours)
  - Add scalar fields for task metadata (complexity, why, what, where, patterns, etc.)
  - Simple migration with validation
  - No parsing logic needed

- [ ] **01B** - [01B-extend-task-schema-jsonb-collections.md](01B-extend-task-schema-jsonb-collections.md) - **Medium** (2-3 hours)
  - Add JSONB collections with embedded schemas
  - Create KeyFile and VerificationStep embedded schemas
  - Add GIN indexes for efficient querying
  - Query helpers for finding tasks by file or technology

- [ ] **02** - [02-add-task-metadata-fields.md](02-add-task-metadata-fields.md) - **Medium** (2-3 hours)
  - Add creator tracking (user ID + AI agent name)
  - Add completion tracking (timestamps + summaries)
  - Add status, dependencies, and capability matching
  - PubSub broadcasts for all lifecycle events
  - Comprehensive API integration tests

## Dependencies

**Requires:** None (foundational feature)
**Blocks:** All other features (02, 03, 04)

## Acceptance Criteria

- [ ] Migrations add all new columns to tasks table (01A: scalars, 01B: JSONB)
- [ ] Schema includes fields for all 18 TASKS.md categories
- [ ] JSONB fields use embedded schemas (KeyFile, VerificationStep) for type safety
- [ ] GIN indexes enable O(log n) JSONB queries
- [ ] Foreign keys link to users table for created_by/completed_by/reviewed_by
- [ ] Dependencies stored as array of task IDs
- [ ] Status field supports: open, in_progress, completed, blocked
- [ ] All columns are nullable (backward compatibility)
- [ ] PubSub broadcasts on all lifecycle events (created, claimed, completed, reviewed, deleted)
- [ ] All existing tests still pass
- [ ] New tests cover JSONB operations, PubSub broadcasts, and API integration

## Technical Approach

**Database Design:**
- Keep flat table structure (no normalized child tables)
- Use JSONB for structured collections (key_files, verification_steps)
- Use PostgreSQL arrays for simple lists (technology_requirements, pitfalls)
- Add GIN indexes on JSONB columns for fast querying
- Example: `SELECT * FROM tasks WHERE key_files @> '[{"file_path": "lib/tasks.ex"}]'`

**Schema Design:**
- All new fields nullable for backward compatibility
- Separate fields for user ID and AI agent name (created_by_id + created_by_agent)
- Use Ecto.Enum for status and review_status fields
- Array column for dependencies and required_capabilities
- Embedded schemas for type safety: KeyFile, VerificationStep

**JSONB Querying:**
- Use `embeds_many` for structured collections
- Use `{:array, :string}` for simple string arrays
- GIN indexes enable containment queries (@>, ?)
- Query helpers: get_tasks_modifying_file/1, get_tasks_requiring_technology/1

**PubSub Integration:**
- Broadcast 7 events: :task_created, :task_updated, :task_deleted, :task_status_changed, :task_claimed, :task_completed, :task_reviewed
- Enhanced broadcast function with logging and telemetry
- LiveView subscriptions in mount/3 with connected?/1 guard

## Success Metrics

- [ ] Both migrations (01A and 01B) run without errors on existing database
- [ ] Can create tasks with all rich fields via IEx
- [ ] JSONB fields correctly store and retrieve structured data
- [ ] GIN indexes improve query performance for JSONB lookups
- [ ] Existing tasks (with nil new fields) still display correctly
- [ ] All 510+ tests still pass
- [ ] PubSub broadcasts reach all connected LiveView clients
- [ ] API integration tests cover authentication, lifecycle events, and capability matching
- [ ] No performance degradation on task queries

## Verification Steps

```bash
# Run migrations
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.{Tasks, Repo}

# Create task with rich fields (scalar)
{:ok, task} = Tasks.create_task(%{
  title: "Test task",
  complexity: :medium,
  why: "Testing new schema",
  what: "Create test task with metadata",
  created_by_id: 1,
  status: "open"
})

# Create task with JSONB collections
{:ok, task2} = Tasks.create_task(%{
  title: "Test JSONB task",
  position: 1,
  column_id: 1,
  key_files: [
    %{file_path: "lib/kanban/tasks.ex", note: "Main context", position: 0}
  ],
  verification_steps: [
    %{step_type: "command", step_text: "mix test", expected_result: "Pass", position: 0}
  ],
  technology_requirements: ["ecto", "phoenix"]
})

# Verify JSONB storage
task2 = Repo.preload(task2, [:key_files, :verification_steps])
IO.inspect(task2.key_files)

# Test JSONB querying
Tasks.get_tasks_modifying_file("lib/kanban/tasks.ex")
Tasks.get_tasks_requiring_technology("ecto")

# Run tests
mix test
mix precommit
```

## Out of Scope

- UI for displaying new fields (Feature 2)
- API endpoints beyond basic CRUD (Feature 3)
- Advanced task completion workflow (Feature 4)
- Migration of existing task descriptions to new format (handled via data migration in task 02)
- Rich text editing
- Full-text search on JSONB content (future enhancement)
- Normalized child tables for collections (using JSONB instead)
