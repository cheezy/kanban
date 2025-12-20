# AI Workflow Integration Guide

## What Makes This Powerful for AI Workflows

The Kanban system uses a **2-level hierarchy** with **two task types** optimized for AI interaction:

**Hierarchy:**
- **Goal** (G prefix) - Large initiatives (25+ hours, multiple tasks)
- **Task** (W/D prefix) - Individual work items (1-3 hours each)

**Task Types:**
- **Work** (W prefix) - New functionality, enhancements
- **Defect** (D prefix) - Bug fixes, corrections

### Core Schema Fields

- title (string)
- description (text) - the "what" and "why"
- status (enum: open, in_progress, completed, blocked)
- priority (enum: low, medium, high, critical)
- type (enum: work, defect) - **Required for tasks**
- task_type (string: "goal", "work", "defect") - **Hierarchy level**
- identifier (string) - Human-readable ID (G1, W42, D7)

### AI-Optimized Fields (18 Categories from TASKS.md)

**Planning & Context:**
- complexity (enum: small, medium, large)
- estimated_files (string) - "2-3", "5-7"
- why (text) - Business/technical rationale
- what (text) - High-level description
- where_context (text) - Location in codebase

**Implementation Guidance:**
- patterns_to_follow (text)
- database_changes (text)
- validation_rules (text)

**Key Files & Verification:**
- key_files (jsonb array) - Embedded KeyFile schemas
- verification_steps (jsonb array) - Embedded VerificationStep schemas
- technology_requirements (array) - ["ecto", "phoenix", "liveview"]

**Observability & Error Handling:**
- telemetry_event (string)
- metrics_to_track (text)
- logging_requirements (text)
- error_user_message (text)
- error_on_failure (text)

**Lifecycle Tracking:**
- created_by_id (integer) - User who created task
- created_by_agent (string) - AI agent name if AI-created
- completed_by_id (integer)
- completed_by_agent (string)
- completed_at (timestamp)
- completion_summary (jsonb) - Detailed completion data

**Dependencies & Relationships:**
- dependencies (array of task IDs) - Task blocks
- parent_id (integer) - Links task to goal
- required_capabilities (array) - ["elixir", "phoenix", "database"]

### Standard Fields

- assigned_to_id (user)
- created_at, updated_at
- column_id (Kanban column position)

### Key API Endpoints for AI

**Task Management:**
- `GET  /api/tasks/ready` - Tasks ready to work (no blockers, status=open)
- `GET  /api/tasks/next` - Get next available task matching agent capabilities
- `POST /api/tasks/claim` - Atomically claim a task (prevents race conditions)
- `POST /api/tasks/:id/unclaim` - Release task if blocked
- `GET  /api/tasks/:id` - Get full task details with all AI fields
- `PATCH /api/tasks/:id` - Update status/progress/completion
- `POST /api/tasks` - Create new task(s) or goal with tasks

**Hierarchy & Context:**
- `GET  /api/tasks/:id/tree` - Get hierarchical view (goal → tasks)
- `GET  /api/agent/info` - Get system documentation and workflow guidance

**Authentication:**
- Bearer token authentication with scopes: `tasks:read`, `tasks:write`, `tasks:claim`, `tasks:delete`
- Capability matching: Agent capabilities matched against task `required_capabilities`

### AI Workflow Integration

**Complete AI Workflow (Planning → Execution → Completion):**

1. **Explore** the codebase to understand requirements
2. **Create a plan** using TASKS.md template structure (18 categories)
3. **POST** the plan as a goal with nested tasks:
   ```json
   POST /api/tasks
   {
     "title": "Add user authentication",
     "task_type": "goal",
     "identifier": "G2",
     "tasks": [
       {"title": "Add JWT library", "type": "work", "complexity": "small"},
       {"title": "Create auth controller", "type": "work", "complexity": "medium"},
       {"title": "Fix password validation", "type": "defect", "complexity": "small"}
     ]
   }
   ```
4. **You review** in the Kanban UI (or approve automatically)
5. **When ready**, AI begins execution
6. **GET** `/api/tasks/next` to get best matching task (based on capabilities)
7. **POST** `/api/tasks/claim` to atomically claim the task
8. **Implement** the task (read key_files, follow patterns, run verification)
9. **Update** with completion summary (PATCH with completion data)
10. **Mark complete** (status=completed with detailed completion_summary)
11. **Dependencies** automatically unblock (next tasks become available)

### Task Type Workflow Patterns

**Creating a Goal:**
```json
POST /api/tasks
{
  "title": "Implement search feature",
  "task_type": "goal",
  "complexity": "large",
  "tasks": [
    {"title": "Add search schema", "type": "work"},
    {"title": "Build search UI", "type": "work"},
    {"title": "Fix search performance", "type": "defect"}
  ]
}
```

**Creating Individual Tasks:**
```json
POST /api/tasks
{
  "title": "Quick bug fix",
  "type": "defect",  // Creates standalone defect (D1)
  "complexity": "small",
  "parent_id": null  // No parent = top-level task
}
```

**Filtering by Type:**
- `GET /api/tasks/ready?type=work` - Only work tasks
- `GET /api/tasks/ready?type=defect` - Only defects
- `GET /api/tasks/ready` - All available tasks

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

### Implementation Decisions Made

The system has made the following design decisions for AI optimization:

1. **API Format**: JSON with TASKS.md structure (18 categories)
   - See [API-FORMAT.md](API-FORMAT.md) for full schema

2. **Authentication**: Bearer token with scopes and capability matching
   - See [AI-AUTHENTICATION.md](AI-AUTHENTICATION.md) for details

3. **Task Breakdown**: 2-level hierarchy (Goal → Tasks) with dependencies
   - Goals group related work
   - Tasks are flat with Work/Defect types
   - See [TASK-BREAKDOWN.md](TASK-BREAKDOWN.md) for rationale

4. **Rich Context**: Structured JSONB with embedded schemas
   - key_files: Array of KeyFile embedded schemas
   - verification_steps: Array of VerificationStep embedded schemas
   - See [RICH-CONTENT.md](RICH-CONTENT.md) for schema details

5. **UI Integration**: AI-created tasks show creator badges
   - created_by_agent field displays AI agent name
   - See [UI-INTEGRATION.md](UI-INTEGRATION.md) for mockups

### Key Benefits for AI Agents

**Efficiency Gains:**
- **No exploration needed** - key_files listed upfront
- **Atomic claiming** - No race conditions between agents
- **Capability matching** - Only see tasks you can complete
- **Real-time updates** - PubSub broadcasts keep all agents in sync
- **Structured verification** - Know exactly what commands to run

**Quality Improvements:**
- **Completion summaries** - Detailed audit trail of all changes
- **Pattern learning** - Deviations inform future task creation
- **Observability** - Built-in telemetry and logging requirements
- **Error handling** - User-facing messages and failure procedures

**Coordination:**
- **Dependencies** - Server handles blocking/unblocking
- **60-minute timeout** - Tasks auto-unclaimed if agent crashes
- **Unclaim mechanism** - Agent can release if blocked
- **Review workflow** - Optional human review before/after

This creates a **Kanban board that speaks AI natively** - structured enough for automation, flexible enough for human collaboration.

### Related Documentation

See [UPDATE-TASKS/README.md](UPDATE-TASKS/README.md) for the complete implementation plan with 13 tasks covering database schema, UI, API, and task management features.
