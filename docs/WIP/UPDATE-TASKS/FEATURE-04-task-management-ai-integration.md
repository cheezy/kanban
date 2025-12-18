# Feature 4: Task Management & AI Integration

**Epic:** [EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
**Type:** Feature
**Status:** Planning
**Complexity:** Medium (6.5 hours estimated)

## Description

Implement advanced task management features including completion tracking with summaries, dependency graphs with automatic unblocking, and AI agent metadata tracking with visual badges. This feature brings together all previous work to enable full task lifecycle management with AI integration.

## Goal

By the end of this feature, tasks can be marked complete with structured summaries, dependencies prevent work on blocked tasks, the system auto-unblocks tasks when dependencies complete, and AI-created tasks are clearly identified in the UI.

## Business Value

**Why This Matters:**
- Completion summaries provide audit trail and learning for future tasks
- Dependencies prevent wasted work on tasks that aren't ready
- Auto-unblocking reduces manual overhead when dependencies complete
- AI badges make it clear which tasks were created/completed by AI
- Statistics show human vs AI productivity

**What Changes:**
- Tasks can be marked complete with structured summary
- Dependency graph prevents circular dependencies
- Blocked tasks auto-unblock when dependencies complete
- UI shows AI badges on AI-created/completed tasks
- Statistics endpoint shows human vs AI task metrics

## Tasks

- [ ] **09** - [09-add-task-completion-tracking.md](09-add-task-completion-tracking.md) - **Medium** (1.5 hours)
  - Complete task endpoint stores completion summary
  - Validation ensures required fields in summary
  - PubSub broadcasts completion to all clients
  - UI shows completion summary in task detail

- [ ] **10** - [10-implement-task-dependencies.md](10-implement-task-dependencies.md) - **Large** (4 hours)
  - Dependency graph validation (no circular deps)
  - Auto-update task status when dependencies change
  - Query functions for ready/blocked tasks
  - UI shows dependency links in task detail
  - PubSub broadcasts when task unblocks

- [ ] **11** - [11-add-ai-created-metadata.md](11-add-ai-created-metadata.md) - **Small** (1 hour)
  - UI badges for AI-created tasks
  - Extract AI model name from created_by_agent field
  - Statistics endpoint for human vs AI metrics
  - API auto-sets created_by_agent from token metadata

## Dependencies

**Requires:** Feature 2 (Rich Task UI), Feature 3 (AI Agent API)
**Blocks:** None (final feature)

## Acceptance Criteria

- [ ] Tasks can be marked complete with summary via API and UI
- [ ] Completion summary includes files changed, verification results
- [ ] Dependencies validated on task creation/update
- [ ] Circular dependency detection prevents invalid graphs
- [ ] Task status auto-updates to "blocked" if dependency added
- [ ] Task status auto-updates to "open" when last dependency completes
- [ ] GET /api/tasks/ready returns only unblocked tasks
- [ ] UI shows dependency links with task status badges
- [ ] AI-created tasks show badge with model name
- [ ] Statistics endpoint returns human vs AI counts
- [ ] PubSub broadcasts completion and unblocking events
- [ ] All tests cover dependency logic and edge cases

## Technical Approach

**Completion Tracking:**
- Completion summary stored as text field
- Validation ensures summary includes required sections
- Status changes to "completed" atomically
- Broadcast completion event via PubSub

**Dependency Graph:**
- Store as array of task IDs in dependencies field
- Validate no circular dependencies using graph traversal
- Index on dependencies for fast lookups
- Query functions: get_blocked_tasks, get_ready_tasks

**Auto-Unblocking:**
- On task completion, find dependents
- Check if all their dependencies are completed
- Update status from "blocked" to "open"
- Broadcast unblocking event

**AI Metadata:**
- created_by_agent format: "claude-sonnet-4.5"
- Extract model name for display: "Claude"
- Badge component shows AI icon + model name
- Statistics query groups by agent prefix

## Success Metrics

- [ ] Dependency validation < 50ms (even with 100+ tasks)
- [ ] Auto-unblocking processes < 100ms per dependent
- [ ] Circular dependency detection < 100ms
- [ ] No race conditions in auto-unblocking
- [ ] 100% test coverage on dependency logic
- [ ] UI badges load without layout shift

## Verification Steps

```bash
# Test completion tracking
iex -S mix
alias Kanban.Tasks

task = Tasks.get_task!(1)
{:ok, completed} = Tasks.complete_task(task, %{
  completed_by_id: 1,
  completed_by_agent: "claude-sonnet-4.5",
  completion_summary: "Files Changed:\n- lib/kanban/tasks.ex\n\nTests: All passed"
})

# Test dependencies
{:ok, task1} = Tasks.create_task(%{title: "Task 1", status: "open"})
{:ok, task2} = Tasks.create_task(%{title: "Task 2", dependencies: [task1.id], status: "blocked"})

# Complete task1, verify task2 unblocks
{:ok, _} = Tasks.complete_task(task1, %{completion_summary: "Done"})
task2_updated = Tasks.get_task!(task2.id)
assert task2_updated.status == "open"

# Test circular dependency detection
{:ok, task3} = Tasks.create_task(%{title: "Task 3", dependencies: [task2.id]})
{:error, changeset} = Tasks.update_task(task2, %{dependencies: [task3.id]})
assert "circular dependency" in errors_on(changeset)

# Test AI badges
export TOKEN="kan_dev_..."
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"task": {"title": "AI task"}}'
# Verify UI shows AI badge

# Run tests
mix test
mix precommit
```

## Dependency Graph Example

```
Task 1 (completed)
  ↓
Task 2 (blocked) → Task 4 (blocked)
  ↓
Task 3 (open)

# When Task 2 completes:
- Task 3 status unchanged (no dependencies)
- Task 4 still blocked (has other dependency)
```

## AI Badge UI

```
┌─────────────────────────────────┐
│ Add user authentication    🤖AI │ <- Badge shows "Claude"
├─────────────────────────────────┤
│ Implement JWT token system      │
│                                  │
│ Complexity: Large                │
│ Created by: AI (claude-sonnet-4.5)
└─────────────────────────────────┘
```

## Out of Scope

- AI model capability matching (assign tasks based on agent capabilities)
- AI agent performance analytics dashboard
- AI model version tracking
- AI agent rate limiting by model
- Task completion time estimation
- Dependency visualization (graph view)
- Gantt chart view with dependencies
- Critical path calculation
- Automatic dependency suggestion based on file paths
- Batch completion of multiple tasks
