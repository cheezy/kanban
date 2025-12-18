# Feature 1: Database Schema Foundation

**Epic:** [EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
**Type:** Feature
**Identifier:** F1 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Large (8.5 hours estimated)

## Description

Extend the database schema to store all task metadata required by the TASKS.md format. This includes 18 categories of task information: complexity, key files, verification steps, observability requirements, error handling, and lifecycle tracking (who created/completed tasks, when, and how).

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
- Tasks table extended with 20+ new columns
- Text fields store collections (key files, pitfalls, etc.) in simple format
- Foreign keys link tasks to users who created/completed them
- Task status and dependencies tracked in database

## Tasks

- [ ] **01** - [01-extend-task-schema.md](01-extend-task-schema.md) - **Large** (5 hours)
  - Add database columns for all TASKS.md fields
  - Create TextFieldParser module for parsing text collections
  - Update Task schema and changeset

- [ ] **02** - [02-add-task-metadata-fields.md](02-add-task-metadata-fields.md) - **Medium** (1.5 hours)
  - Add creator tracking (user ID + AI agent name)
  - Add completion tracking (timestamps + summaries)
  - Add status and dependencies fields

## Dependencies

**Requires:** None (foundational feature)
**Blocks:** All other features (02, 03, 04)

## Acceptance Criteria

- [ ] Migration adds all new columns to tasks table
- [ ] Schema includes fields for all 18 TASKS.md categories
- [ ] Text fields store collections using simple line-based format
- [ ] TextFieldParser can parse/format text fields to/from structured data
- [ ] Foreign keys link to users table for created_by/completed_by
- [ ] Dependencies stored as array of task IDs
- [ ] Status field supports: open, in_progress, completed, blocked
- [ ] All columns are nullable (backward compatibility)
- [ ] All existing tests still pass
- [ ] New tests cover schema changes and parsing logic

## Technical Approach

**Database Design:**
- Keep flat table structure (no normalized child tables)
- Use text fields with simple formatting for collections
- Format: "field1 | field2 | field3" per line
- Example key_files: "lib/kanban/tasks.ex | Task context module"

**Schema Design:**
- All new fields nullable for backward compatibility
- Separate fields for user ID and AI agent name
- Use Ecto.Enum for status field
- Array column for dependencies

**Parsing Strategy:**
- TextFieldParser module converts text ↔ structured data
- Simple line-based parsing (split by \n, then by |)
- Return maps with position field for ordering
- Handle nil/empty values gracefully

## Success Metrics

- [ ] Migration runs without errors on existing database
- [ ] Can create tasks with all rich fields via IEx
- [ ] Text fields correctly store and retrieve collection data
- [ ] Existing tasks (with nil new fields) still display correctly
- [ ] All 510+ tests still pass
- [ ] No performance degradation on task queries

## Verification Steps

```bash
# Run migrations
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.Tasks

# Create task with rich fields
{:ok, task} = Tasks.create_task(%{
  title: "Test task",
  complexity: "medium",
  key_files: "lib/kanban/tasks.ex | Main context",
  created_by_id: 1,
  created_by_agent: nil,
  status: "open"
})

# Verify parsing
parsed = Kanban.Tasks.TextFieldParser.parse_key_files(task.key_files)
IO.inspect(parsed)

# Run tests
mix test
mix precommit
```

## Out of Scope

- UI for displaying new fields (Feature 2)
- API endpoints (Feature 3)
- Task completion workflow (Feature 4)
- Migration of existing task descriptions to new format
- Rich text editing
- Separate database tables for collections
