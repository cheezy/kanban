# What things should I do to make this powerful for AI workflows?

## What Would Make This Powerful for AI Workflows

Based on what I track internally, here's what would make this incredibly useful:
Task Schema - AI-Optimized Fields

### Core fields

- title (string)
- description (text) - the "what" and "why"
- status (enum: open, in_progress, completed, blocked)
- priority (0-4, 0 = highest)
- task_type (enum: feature, bug, task, research, refactor)

### AI-specific fields

- acceptance_criteria (jsonb/text) - list of checkboxes/conditions
- technical_context (jsonb)
  - files_to_modify: [paths]
  - related_modules: [module names]
  - existing_patterns: "description"
  - constraints: [list]
  
- scope (jsonb)
  - in_scope: [items]
  - out_of_scope: [items]
  
- examples (jsonb) - input/output examples, test cases
- dependencies (relations) - blocks/blocked_by
- discovered_by (string) - which AI/session created it
- implementation_notes (text) - learnings after completion

### Standard fields

- assignee
- created_at, updated_at
- parent_task_id (for epics/subtasks)

### Key API Endpoints for AI

GET  /api/tasks/ready          # Tasks ready to work (no blockers, status=open)
POST /api/tasks                # Create new task(s) from planning
GET  /api/tasks/:id            # Get full task details
PATCH /api/tasks/:id           # Update status/progress
POST /api/tasks/:id/subtasks   # Break down into smaller tasks
GET  /api/tasks/:id/context    # Get all related tasks/dependencies

### AI Workflow Integration

When I'm in plan mode, I could:

1. **Explore** the codebase
2. **Create a plan** (using TASKS.md template structure)
3. **POST** the plan to your app as a set of tasks with dependencies
4. **You review** in the Kanban UI
5. **When you're ready**, you tell me to work on it
6. **I GET** `/api/tasks/ready` to see what's unblocked
7. **I claim** a task (PATCH status=in_progress)
8. **I implement** it
9. **I update** the task with completion summary (see TASKS.md completion format)
10. **I mark complete** (PATCH status=completed with completion data)
11. **Dependencies** automatically unblock

### Task Completion Updates

When completing a task, AI should PATCH with a completion summary:

```json
PATCH /api/tasks/:id
{
  "status": "completed",
  "completion": {
    "completed_at": "2025-12-17",
    "completed_by": "Claude Sonnet 4.5",
    "files_changed": [
      {
        "path": "lib/kanban_web/live/board_live.ex",
        "changes": "Added priority filter dropdown and handle_event"
      },
      {
        "path": "lib/kanban/boards.ex",
        "changes": "Updated get_tasks/2 to filter by priority"
      }
    ],
    "tests_added": [
      "test/kanban/boards_test.exs - Added priority filter tests"
    ],
    "verification_results": {
      "commands_run": ["mix test", "mix precommit"],
      "status": "passed",
      "output": "All tests passed, no warnings"
    },
    "implementation_notes": {
      "deviations": ["Added graceful handling for nil priority values"],
      "discoveries": ["Existing filter pattern worked perfectly"],
      "edge_cases": ["Tasks without priority show in 'All' filter only"]
    },
    "telemetry_added": ["[:kanban, :filter, :used]"],
    "follow_up_tasks": [],
    "known_limitations": ["Priority sorting not implemented (out of scope)"]
  }
}
```

This completion data provides:
- **Audit trail** - What actually changed vs. what was planned
- **Knowledge transfer** - Future work references actual implementation
- **Debugging context** - If bugs appear, clear record of changes
- **Learning** - Pattern of deviations improves future task creation

See **TASKS.md** for the full completion summary template.

### Questions for You

1. **API Format**: Would you want tasks as JSON, or some other format?
    See API-FORMAT.md
2. **Authentication**: How would AI authenticate to the API?
    See AI-AUTHENTICATION.md
3. **Task Breakdown**: Should I be able to create subtasks automatically, or just flat tasks?
    See TASK-BREAKDOWN.md
4. **Rich Context**: Should technical_context be structured JSON, or free-form markdown?
    See RICH-CONTEXT.md
5. **UI Integration**: Do you want the Kanban board to show "AI-created" vs "human-created" tasks differently?
    See UI-INTEGRATION.md

This could be really powerful - essentially a Kanban board that speaks AI natively! Want me to explore the current codebase to see what's already there and plan out how to add this capability?
