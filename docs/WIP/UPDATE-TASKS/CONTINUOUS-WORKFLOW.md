# Continuous AI Workflow Mode

## Overview

When an AI agent completes a task that **doesn't require human review**, the system enables **continuous autonomous execution** - the AI automatically proceeds to the next available task without waiting for a human prompt.

This creates an efficient workflow where AI agents work through task queues independently, stopping only when genuine human input is needed.

## How It Works

### Task Completion Flow

When a task is marked as completed (status = `:completed`):

1. **Automatic Movement to Done**
   - Task moves from current column to "Done" column
   - `completed_at` timestamp set
   - `completed_by_id` and optionally `completed_by_agent` recorded

2. **Parent Goal Repositioning** (if applicable)
   - If task belongs to a goal (`parent_id` is set):
     - System checks if ALL sibling tasks are in same column
     - If yes, parent goal automatically moves to that column
     - Special handling: In "Done" column, goal positions at END
     - Otherwise: Goal positions BEFORE first child in target column

3. **PubSub Broadcasts**
   - `{:task_completed, updated_task}` broadcast to board channel
   - Real-time UI updates for all connected clients
   - Goal progress bars update automatically

4. **Telemetry Events**
   - `[:kanban, :task, :completed]` event emitted
   - Metadata includes task_id and completed_by user

5. **Dependency Unblocking**
   - Any tasks blocked by this task become unblocked
   - Status changes from `:blocked` to `:open`
   - Tasks become available in `/api/tasks/next` endpoint

### Continuous Execution Trigger

**After steps 1-5 complete**, the AI agent:

1. **Immediately queries** `GET /api/tasks/next` (without waiting for human prompt)
2. **If task available**: Claim it with `POST /api/tasks/claim` and begin work
3. **If no tasks**: Stop and report completion (all tasks done or blocked)
4. **If review needed**: Stop and notify human for review

## Stopping Conditions

The AI agent continues working **until one of these conditions is met**:

### 1. No More Tasks Available
```json
GET /api/tasks/next
Response: 204 No Content
```
All tasks are either:
- Completed
- Blocked by dependencies
- Already claimed by another agent
- Don't match agent's capabilities

**Action:** AI reports "All available tasks completed" and waits for new work.

### 2. Task Requires Review
Task has `needs_review: true` flag set or moves to "Review" column:
```json
GET /api/tasks/next
Response: 200 OK
{
  "id": 42,
  "title": "Complex refactoring",
  "needs_review": true,
  ...
}
```

**Action:** AI can claim and work on task, but **must move it to Review column** when complete instead of Done. AI then **stops and notifies human** that review is needed.

### 3. Error or Blocker Encountered

AI encounters an issue during implementation:
- Missing dependencies or tools
- Failing tests that can't be fixed
- Ambiguous requirements
- Security concerns

**Action:** AI calls `POST /api/tasks/:id/unclaim` to release the task, updates task description with blocker details, and **notifies human** for assistance.

## Example Workflow

### Scenario: AI Completing a Goal with 3 Tasks

**Initial State:**
- Goal G1 (in Backlog): "Add search feature"
  - Task W1 (in Backlog): "Add search schema" - Status: open
  - Task W2 (in Backlog): "Build search UI" - Status: open, blocks: [W1]
  - Task W3 (in Backlog): "Add search tests" - Status: open, blocks: [W1, W2]

**Execution:**

1. **Human:** "Please start working on the search feature"

2. **AI:** Claims W1 (only unblocked task)
   ```bash
   POST /api/tasks/claim
   → Task W1 claimed
   ```

3. **AI:** Completes W1
   - Implements schema
   - Runs tests
   - Updates with completion summary
   - Marks status as `:completed`
   - **Task W1 moves to Done column**
   - **Goal G1 stays in Backlog** (not all children in same column yet)
   - **W2 and W3 unblock** (W1 dependency removed)

4. **AI:** **Immediately** (without prompt) queries next task
   ```bash
   GET /api/tasks/next
   → Returns W2 (now unblocked)
   ```

5. **AI:** Claims and completes W2
   - **Task W2 moves to Done column**
   - **Goal G1 stays in Backlog** (W3 still in Backlog)
   - **W3 unblocks** (all dependencies satisfied)

6. **AI:** **Immediately** queries next task
   ```bash
   GET /api/tasks/next
   → Returns W3
   ```

7. **AI:** Claims and completes W3
   - **Task W3 moves to Done column**
   - **Goal G1 automatically moves to Done column** (all children in Done)
   - **Goal positions at END of Done column** (special Done column handling)

8. **AI:** **Immediately** queries next task
   ```bash
   GET /api/tasks/next
   → 204 No Content (no more tasks)
   ```

9. **AI:** Reports: "Search feature complete! All 3 tasks finished and Goal G1 moved to Done."

**Total Human Interactions:** 1 (initial prompt only)

## Benefits

### For AI Agents
- **Autonomous operation** - Work through entire goals without interruption
- **Efficient use of compute** - No idle time between tasks
- **Clear stopping points** - Know exactly when to stop and wait
- **Context preservation** - Maintain working state across related tasks

### For Human Users
- **Reduced interruptions** - AI works independently on routine tasks
- **Timely notifications** - Only alerted when review actually needed
- **Progress visibility** - Watch real-time progress via Kanban board
- **Control retention** - Can review/approve work at any time

### For Teams
- **Higher throughput** - Multiple agents can work concurrently
- **Better resource utilization** - Agents self-assign optimal tasks
- **Quality gates** - Review flags ensure critical work gets human oversight
- **Audit trail** - Complete history of who did what and when

## Configuration

### Enabling Continuous Mode

Continuous workflow is **enabled by default** when:
1. Task completes successfully (status = `:completed`)
2. Task does NOT have `needs_review: true`
3. Task does NOT move to "Review" column

### Requiring Review for Specific Tasks

Set `needs_review: true` when creating/updating tasks:

```json
POST /api/tasks
{
  "title": "Refactor authentication system",
  "type": "work",
  "complexity": "large",
  "needs_review": true,  // AI will stop after completing
  "why": "Security-critical code changes require human review"
}
```

### Workflow Hooks (Optional)

Configure `.stride.md` with hooks for automation:

```markdown
# .stride.md

## after_task_complete

When a task completes:
1. Run full test suite: `mix test`
2. Run code quality: `mix credo --strict`
3. Check coverage: `mix coveralls`
4. If all pass: Continue to next task
5. If any fail: Stop and notify human
```

See [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) for full hook system documentation.

## Review Workflow Integration

For tasks that **do require review**, the workflow changes:

1. **AI completes task** and moves it to "Review" column
2. **Human reviews** the work and sets `review_status`:
   - `:approved` - Work is good
   - `:changes_requested` - Needs fixes
   - `:rejected` - Start over

3. **Human notifies AI** that review is complete

4. **AI calls** `PATCH /api/tasks/:id/mark_reviewed`
   - If `approved`: Moves to Done, **continues to next task**
   - If `changes_requested`/`rejected`: Moves back to Doing, **AI fixes issues**

See [NEEDS-REVIEW-FEATURE-SUMMARY.md](NEEDS-REVIEW-FEATURE-SUMMARY.md) for full review workflow details.

## Best Practices

### For AI Agents

1. **Always check** `needs_review` flag before deciding next action
2. **Always call** `/api/tasks/next` after completing a task
3. **Stop immediately** if review needed or no tasks available
4. **Include context** when unclaiming blocked tasks
5. **Update progress** regularly during long-running tasks

### For Human Users

1. **Set `needs_review: true`** for:
   - Security-critical changes
   - Database schema migrations
   - Public API modifications
   - Major refactorings

2. **Let AI work autonomously** for:
   - Bug fixes
   - Test additions
   - Documentation updates
   - Code cleanup/formatting

3. **Monitor progress** via Kanban board real-time updates

4. **Review completion summaries** to understand what changed

## Error Handling

### AI Encounters Blocker

```bash
# AI claims task
POST /api/tasks/claim
→ Task W5 claimed

# AI discovers missing database migration
# AI cannot proceed

# AI unclimbs task
POST /api/tasks/W5/unclaim

# AI updates task with blocker info
PATCH /api/tasks/W5
{
  "description": "...\n\n**BLOCKER:** Requires migration from #W3 which failed. Cannot create test data.",
  "status": "blocked"
}

# AI notifies human
"I encountered a blocker on task W5. The database migration from W3 failed, preventing me from creating test data. Please review W3 and W5."
```

### System Timeout (60 minutes)

If AI crashes or loses connection during task execution:
- Task automatically unclaimed after 60 minutes
- Becomes available to other agents
- No manual intervention needed

See [TIMEOUT-IMPLEMENTATION-SUMMARY.md](TIMEOUT-IMPLEMENTATION-SUMMARY.md) for details.

## Related Documentation

- [AI-WORKFLOW.md](../AI-WORKFLOW.md) - Complete AI workflow guide
- [NEEDS-REVIEW-FEATURE-SUMMARY.md](NEEDS-REVIEW-FEATURE-SUMMARY.md) - Review workflow details
- [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) - Workflow hook system
- [TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md) - Goal → Task hierarchy
- [README.md](README.md) - Implementation plan and phased adoption
