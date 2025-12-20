# What's Missing or Could Be Improved

## ✅ 1. Task Claiming Timeout/Auto-Release (IMPLEMENTED)

**Status:** Added to task 08 with 60-minute timeout

Problem: If I claim a task and then crash/disconnect, that task is stuck in "in_progress" forever, blocking other agents.

Solution Implemented:

- Added `claimed_at` and `claim_expires_at` fields to tasks table
- Claims automatically expire after 60 minutes of inactivity
- Background job (Oban) runs every 5 minutes to release expired claims
- Tasks with expired claims become available to other agents
- PubSub broadcasts when claims expire for real-time updates
- See task 08 for full implementation details

## ~~2. Partial Progress / Checkpointing~~ (NOT NEEDED)

**Decision:** This is solved by proper task decomposition, not by adding checkpointing mechanisms.

Problem: If I'm 80% done with a large task and crash, the next agent starts from scratch.

Solution: **Keep tasks small and focused.** The Goal/Task hierarchy exists specifically to break down large work into small, completable units. Each task should be completable within the 60-minute claim timeout.

Design Principle:
- Tasks should be atomic units of work (15-45 minutes to complete)
- If a task is too large to complete in 60 minutes, break it into multiple tasks
- Use Goals to group related tasks
- The 60-minute timeout acts as a forcing function for proper decomposition

## ✅ 3. Agent Capability Matching (IMPLEMENTED)

**Status:** Added to tasks schema and task 08 claiming logic

Problem: Not all agents have the same capabilities. I might be Claude Sonnet 4.5 with strong coding skills, but another agent might be a simpler model better suited for documentation tasks.

Solution Implemented:

- Added `required_capabilities` array to tasks table (e.g., `["code_generation", "database_design"]`)
- Added `capabilities` array to api_tokens table (e.g., `["code_generation", "testing", "documentation"]`)
- GET /api/tasks/next and POST /api/tasks/claim filter by capability match
- Task is only returned if agent has ALL required capabilities
- Empty required_capabilities means any agent can claim the task
- See task 02, task 06, and task 08 for full implementation details

## ~~4. Blocked Task Notifications~~ (NOT NEEDED)

**Decision:** Server-side dependency resolution is sufficient. Agents simply request the next task and the server determines what is unblocked and ready to work on.

Problem: If I'm waiting for a dependency to complete, I have no way to know when it's done besides polling.

Solution: **The server handles dependency resolution.** When an agent calls GET /api/tasks/next or POST /api/tasks/claim, the server automatically filters out tasks with incomplete dependencies. The agent doesn't need to know about or wait for specific dependencies - it just asks for the next task and receives whatever is ready.

Design Principle:
- Agents don't select their own work or wait for specific tasks
- Server maintains full visibility of dependency graph
- GET /api/tasks/next and POST /api/tasks/claim already filter by completed dependencies
- Agent workflow is simple: claim task → work on it → complete it → claim next task
- No need for webhooks, polling, or waiting logic in agents

## ✅ 5. Work Estimation Feedback Loop (IMPLEMENTED)

**Status:** Added to task 02 and task 09 with completion tracking fields

Problem: The `complexity` and `estimated_files` fields are set upfront, but actual complexity might differ. No way to report back "this was actually Large, not Medium."

Solution Implemented:

- Added `actual_complexity` field to tasks table (stores actual complexity experienced)
- Added `actual_files_changed` field to tasks table (stores actual number of files modified)
- Added `time_spent_minutes` field to tasks table (stores actual time in minutes)
- Completion summary includes estimation accuracy feedback
- Analytics can compare estimated vs actual to improve future estimates
- See task 02 and task 09 for full implementation details

Example completion data:
```json
{
  "estimated_complexity": "medium",
  "actual_complexity": "large",
  "estimated_files": "2-3",
  "actual_files_changed": 5,
  "time_spent_minutes": 45
}
```

This helps improve future task estimates and identify tasks that are consistently underestimated.

## ✅ 6. Rollback/Unclaim Mechanism (IMPLEMENTED)

**Status:** Added to task 08 with unclaim endpoint

Problem: If I claim a task but quickly realize I can't complete it (missing context, blocked by external factor), I have no clean way to unclaim it.

Solution Implemented:

- Added POST /api/tasks/:id/unclaim endpoint
- Resets task status to "open"
- Clears claimed_at and claim_expires_at timestamps
- Requires optional reason parameter for analytics
- Validates agent can only unclaim tasks they claimed
- PubSub broadcasts when task unclaimed
- See task 08 for full implementation details

## ✅ 7. Dry Run / Validation Endpoint (IMPLEMENTED)

**Status:** Added to task 08 with validation endpoint

Problem: I want to verify I can successfully authenticate and parse the task format before claiming.

Solution Implemented:

- Added GET /api/tasks/:id/validate endpoint
- Returns schema validation results for the task
- Checks if agent has required scopes (tasks:read, tasks:write)
- Confirms all dependencies are in valid state (exist and have valid statuses)
- Verifies agent has required capabilities to claim the task
- Returns readiness status (can claim, reason if not)
- No side effects - read-only validation
- See task 08 for full implementation details

## ✅ 8. Batch Operations (IMPLEMENTED)

**Status:** Added to task 04 with batch creation endpoint

Problem: If I'm creating a plan with 20 interconnected tasks, I have to make 20 separate POST requests with dependency IDs that don't exist yet.

Solution Implemented:

- Added POST /api/tasks/batch endpoint
- Accepts array of tasks with temporary IDs for dependency references
- Resolves temporary IDs to actual task IDs after creation
- Creates all tasks in a single database transaction (atomic)
- Returns mapping of temporary IDs to actual task IDs
- Validates dependency graph (no cycles, all temp IDs referenced exist)
- See task 04 for full implementation details

Example request:
```json
{
  "tasks": [
    {"temp_id": "t1", "title": "Schema", "dependencies": []},
    {"temp_id": "t2", "title": "API", "dependencies": ["t1"]},
    {"temp_id": "t3", "title": "UI", "dependencies": ["t2"]}
  ]
}
```

Example response:
```json
{
  "data": [
    {"id": 101, "temp_id": "t1", "title": "Schema"},
    {"id": 102, "temp_id": "t2", "title": "API"},
    {"id": 103, "temp_id": "t3", "title": "UI"}
  ]
}
```

## ✅ 9. Context Limits (IMPLEMENTED)

**Status:** Added to task 12 with pagination and depth limiting

Problem: The tree endpoint could return thousands of tasks for a large goal. That might exceed my context window.

Solution Implemented:

- Added query parameters to GET /api/tasks/:id/tree endpoint:
  - `?depth=N` - Limit tree depth (e.g., depth=2 shows goal → tasks only)
  - `?max_tasks=N` - Limit total number of tasks returned (e.g., max_tasks=50)
  - `?page=N&per_page=N` - Pagination support for large result sets
- Default depth=2, max_tasks=100, per_page=50
- Response includes pagination metadata (total_count, page, per_page, has_more)
- Truncated results include indicator showing how many items were excluded
- See task 12 for full implementation details

## ✅ 10. Human Review Queue (IMPLEMENTED)

**Status:** Added to task 02 and task 09 with review tracking fields

**Note:** Column names are configurable per board. References to "Review" column in this document use the default name, but boards may use different names like "Code Review", "QA", or "Pending Review".

Problem: After I complete a task and move it to review column, I don't know if a human approved it, rejected it, or needs changes.

Solution Implemented:

- Added `needs_review` field (boolean, default: false) to control whether task requires human review
- Added `review_status` field to tasks table (pending, approved, changes_requested, rejected)
- Added `review_notes` field (text) for human feedback
- Added `reviewed_by_id` field (references users) to track who reviewed
- Added `reviewed_at` timestamp
- Added GET /api/tasks/:id/review endpoint to fetch review status and notes
- Added PATCH /api/tasks/:id/review endpoint for humans to submit reviews
- PubSub broadcasts review status changes to notify agents
- Agents can poll review status or subscribe to updates
- See task 02 and task 09 for full implementation details

Review workflow:

**For tasks with needs_review = true:**
1. Agent completes task (status: "completed")
2. Task moves to review column (configurable, default: "Review")
3. Human reviews task in review column
4. Human sets review_status via API
5. Agent receives notification or polls for review status
6. If changes_requested, agent can read review_notes and address feedback

**For tasks with needs_review = false:**
1. Agent completes task (status: "completed")
2. Task skips review column and moves directly to done
3. Review hooks (before_column_enter[Review], after_column_exit[Review]) still execute if configured
4. No human review required, task is considered done

This allows humans to specify which tasks need review (e.g., security changes, database migrations) and which can be automatically completed (e.g., documentation updates, minor bug fixes).

Column configuration applies to:
- Claimable column (where agents get tasks from) - default: "Ready"
- Review column (where completed tasks go if needs_review = true) - configurable per board
- Column names, positions, and workflow are fully customizable via UI

## Questions About the Current Design

1. Column Assignment: Who sets which column a task is in? Can I move tasks between columns via API, or is that human-only?

2. Priority Updates: Can I update task priority if I discover it's blocking critical work? Or is that product-owner-only?

3. Dependency Cycles: Is there validation to prevent circular dependencies (A depends on B, B depends on A)?

4. Error Recovery: If my API call to complete a task fails (network error), how do I retry idempotently?
5. Multiple Boards: Does the system support multiple boards? Do I need to scope my queries to a specific board_id?
6. Authentication Scope: Can one API token work across multiple boards, or is it board-specific?

## Summary

The system now has all the core features needed for effective AI agent collaboration:

### ✅ Implemented (Ready for Development)

1. **Task Claiming Timeout/Auto-Release** - 60-minute timeout with auto-release
2. **Agent Capability Matching** - Tasks filtered by required capabilities
3. **Work Estimation Feedback Loop** - Track actual vs estimated complexity
4. **Rollback/Unclaim Mechanism** - Agents can release tasks they can't complete
5. **Dry Run / Validation Endpoint** - Check task readiness before claiming
6. **Batch Operations** - Create interconnected tasks with temporary IDs
7. **Context Limits** - Pagination and depth limits for tree endpoint
8. **Human Review Queue** - Track review status and human feedback

### ❌ Not Needed (Solved by Better Design)

2. **Partial Progress / Checkpointing** - Use proper task decomposition instead
4. **Blocked Task Notifications** - Server handles dependency resolution

### Implementation Status

- ✅ **Resilience**: Timeouts (60 min), unclaim mechanism, validation endpoint
- ✅ **Capability matching**: Required capabilities filter on claim
- ✅ **Feedback loop**: Actual complexity, files, time tracking
- ✅ **Batch operations**: Create interconnected task graphs efficiently
- ✅ **Context limits**: Pagination and depth limits for large goals
- ✅ **Human review**: Review status, notes, and feedback loop
- ✅ **Coordination**: Server-side dependency resolution (no agent polling needed)
- ✅ **Workflow hooks**: Agent-specific commands at workflow transition points (tasks 13, 14)

### New Features (Beyond Original Improvements)

**Agent Workflow Hooks** - Added after original 10 improvements

Agents can execute custom commands at specific workflow transition points defined in AGENTS.md file:

- Hook points: before/after claim, before/after column enter/exit, before/after complete, before/after unclaim
- Board-level configuration: Enable/disable hooks, set timeouts
- Column-level configuration: Per-column hook settings
- Hybrid approach: Boards define when, agents define what
- Blocking vs non-blocking: before_* hooks block on failure, after_* hooks don't
- Full observability: Telemetry, logging, timeout enforcement

**Implementation Tasks:**

- Task 13: Add Hook Configuration to Boards/Columns
- Task 14: Implement Hook Execution Engine

**Documentation:**

- See [docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) for complete design

The system is now ready for full-scale multi-agent collaboration with all requested improvements documented and ready for implementation.
