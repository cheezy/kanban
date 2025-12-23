# Agent Configuration and Workflow Hooks

**Status:** Design Document
**Created:** 2025-12-18
**Related:** Improvements #6-10, Task 08

## Overview

Agents can execute custom commands at specific points in the task workflow (e.g., before claiming a task, after completing work, before review). This document defines how agents configure their behavior and how boards define workflow hook points.

## Design Principles

1. **Separation of Concerns**:
   - Boards define *when* hooks run (workflow stages)
   - Agents define *what* to do at those hooks (commands/actions)

2. **Flexibility**:
   - Different boards can have different workflows
   - Different agents can have different behaviors at the same hook points
   - Hooks are optional - agents can choose which hooks to implement

3. **Safety**:
   - All hooks are logged and tracked
   - Failed hooks don't block workflow (configurable)
   - Hooks have timeouts to prevent hanging

## Hook Points

### Standard Workflow Hooks

These are the standard hook points that boards can configure:

```yaml
# Board-level hook points (configurable per board)
workflow_hooks:
  before_claim:
    description: "Runs before agent claims a task"
    column: null  # Not column-specific
    examples:
      - "Sync with latest main branch"
      - "Check for system updates"
      - "Validate environment setup"

  after_claim:
    description: "Runs immediately after task is claimed"
    column: null
    examples:
      - "Create feature branch"
      - "Update local dependencies"
      - "Send notification to team"

  before_column_enter:
    description: "Runs when task enters a column"
    column: specific  # Runs for specific columns
    examples:
      - "Before entering 'In Progress': git rebase main"
      - "Before entering 'Review': run linters"
      - "Before entering 'QA': deploy to staging"
    note: "Review column hooks execute even if needs_review = false"

  after_column_enter:
    description: "Runs after task enters a column"
    column: specific
    examples:
      - "After entering 'In Progress': start time tracking"
      - "After entering 'Review': request code review"
      - "After entering 'Done': update project board"
    note: "Review column hooks execute even if needs_review = false"

  before_column_exit:
    description: "Runs before task exits a column"
    column: specific
    examples:
      - "Before exiting 'In Progress': run quality checks"
      - "Before exiting 'Review': verify approval received"
      - "Before exiting 'QA': run smoke tests"
    note: "Review column hooks execute even if needs_review = false"

  after_column_exit:
    description: "Runs after task exits a column"
    column: specific
    examples:
      - "After exiting 'In Progress': update status"
      - "After exiting 'Review': create git tag"
      - "After exiting 'Done': archive artifacts"
    note: "Review column hooks execute even if needs_review = false"

  before_complete:
    description: "Runs before task is marked complete"
    column: null
    examples:
      - "Verify all tests pass"
      - "Check code coverage threshold"
      - "Validate documentation updated"

  after_complete:
    description: "Runs after task is marked complete"
    column: null
    examples:
      - "git commit and push changes"
      - "Update changelog"
      - "Send completion notification"

  before_unclaim:
    description: "Runs before agent unclaims a task"
    column: null
    examples:
      - "Clean up local changes"
      - "Save work in progress"
      - "Reset environment"

  after_unclaim:
    description: "Runs after task is unclaimed"
    column: null
    examples:
      - "Delete feature branch"
      - "Clear local state"
      - "Notify team of unclaim"
```

## Review Workflow and needs_review Flag

Tasks have a `needs_review` boolean field (default: false) that controls whether they require human review before being marked as complete.

**When needs_review = true:**

- Task moves to Review column after completion
- Human reviews the work and sets review_status (approved, changes_requested, rejected)
- Review column hooks execute (before_column_enter[Review], after_column_exit[Review])
- Task waits for human approval before moving to Done

**When needs_review = false:**

- Task skips Review column and moves directly to Done after completion
- Review column hooks **still execute** if configured (allows for automated quality checks)
- No human review required, task is automatically considered complete
- Useful for low-risk tasks (documentation, minor fixes, automated updates)

**Example use cases for needs_review = false:**

- Documentation updates
- Automated dependency updates
- Minor bug fixes in non-critical code
- Test additions
- Code formatting changes

**Example use cases for needs_review = true:**

- Security-related changes
- Database schema migrations
- API contract changes
- Authentication/authorization changes
- Production configuration changes

This allows humans to focus review effort on high-risk changes while allowing agents to autonomously complete low-risk tasks.

## Agent Configuration (.stride.md)

Agents define their behavior for each hook point in a `.stride.md` file at the root of the repository. This file should be checked into version control so the entire team can see and use the configured hooks.

### .stride.md Format

```markdown
# Agent Configuration

This file defines how AI agents should behave when working on tasks in this project.

## Agent: Claude Sonnet 4.5

### Capabilities
- code_generation
- testing
- documentation
- refactoring

### Hook Implementations

#### before_claim
```bash
# Sync with latest main branch to avoid conflicts
git fetch origin main
git status
```

#### after_claim
```bash
# Create feature branch for this task
TASK_ID="$TASK_ID"
BRANCH_NAME="task-${TASK_ID}-$(echo $TASK_TITLE | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
git checkout -b "$BRANCH_NAME" origin/main
echo "Created branch: $BRANCH_NAME"
```

#### before_column_enter[In Progress]
```bash
# Rebase on main before starting work
git fetch origin main
git rebase origin/main
```

#### after_column_enter[In Progress]
```bash
# Mark task as in progress
echo "Task $TASK_ID: Started at $(date)"
```

#### before_column_exit[In Progress]
```bash
# Run quality checks before moving to review
mix format --check-formatted
mix credo --strict
mix test
mix dialyzer
```

#### after_column_exit[In Progress]
```bash
# Push changes to remote
git push origin HEAD
```

#### before_column_enter[Review]
```bash
# Ensure all tests pass before review
mix test
echo "All tests passed - ready for review"
```

#### before_complete
```bash
# Final verification before completion
mix precommit
```

#### after_complete
```bash
# Commit and push changes
git add .
git commit -m "Complete task $TASK_ID: $TASK_TITLE

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

git push origin HEAD
```

#### before_unclaim
```bash
# Save work in progress before unclaiming
git stash save "WIP: Task $TASK_ID - $UNCLAIM_REASON"
```

#### after_unclaim
```bash
# Return to main branch
git checkout main
```

## Agent: GitHub Copilot Agent

### Capabilities
- code_generation
- code_review

### Hook Implementations

#### before_claim
```bash
# Update dependencies
npm install
```

#### after_claim
```bash
# Create feature branch
git checkout -b "copilot-task-$TASK_ID"
```

#### before_complete
```bash
# Run linters
npm run lint
npm run test
```

#### after_complete
```bash
# Commit changes
git add .
git commit -m "feat: $TASK_TITLE (task #$TASK_ID)"
git push origin HEAD
```
```

## Board Configuration

Boards define which hook points are enabled and their configuration.

### Database Schema

```elixir
# boards table
add :workflow_hooks, :jsonb, default: %{
  "before_claim" => %{"enabled" => true, "timeout" => 60},
  "after_claim" => %{"enabled" => true, "timeout" => 30},
  "before_complete" => %{"enabled" => true, "timeout" => 120},
  "after_complete" => %{"enabled" => true, "timeout" => 60},
  "before_unclaim" => %{"enabled" => false, "timeout" => 30},
  "after_unclaim" => %{"enabled" => false, "timeout" => 30}
}

# columns table
add :enter_hooks, :jsonb, default: %{
  "before" => %{"enabled" => true, "timeout" => 60},
  "after" => %{"enabled" => false, "timeout" => 30}
}
add :exit_hooks, :jsonb, default: %{
  "before" => %{"enabled" => true, "timeout" => 60},
  "after" => %{"enabled" => false, "timeout" => 30}
}
```

### Board Settings UI

```
Board Settings > Workflow Hooks

[x] Enable before_claim hooks (timeout: 60s)
[x] Enable after_claim hooks (timeout: 30s)
[x] Enable before_complete hooks (timeout: 120s)
[x] Enable after_complete hooks (timeout: 60s)
[ ] Enable before_unclaim hooks (timeout: 30s)
[ ] Enable after_unclaim hooks (timeout: 30s)

Column: In Progress
  [x] Enable before_enter hooks (timeout: 60s)
  [ ] Enable after_enter hooks
  [x] Enable before_exit hooks (timeout: 60s)
  [ ] Enable after_exit hooks

Column: Review
  [x] Enable before_enter hooks (timeout: 30s)
  [ ] Enable after_enter hooks
  [x] Enable before_exit hooks (timeout: 30s)
  [ ] Enable after_exit hooks
```

## API Integration

### Hook Execution Flow

When an agent performs an action that has hooks:

1. **Agent calls API endpoint** (e.g., POST /api/tasks/claim)

2. **Server checks board configuration**:
   ```elixir
   board.workflow_hooks["before_claim"]["enabled"] == true
   ```

3. **Server returns hook requirements in response**:
   ```json
   {
     "data": {
       "id": 42,
       "title": "Add user authentication",
       "status": "in_progress",
       "claimed_at": "2025-12-18T10:00:00Z"
     },
     "hooks": {
       "after_claim": {
         "required": true,
         "timeout": 30,
         "blocking": false
       },
       "before_column_enter": {
         "column": "In Progress",
         "required": true,
         "timeout": 60,
         "blocking": true
       }
     }
   }
   ```

4. **Agent reads .stride.md** and finds matching hook implementation

5. **Agent executes hook commands**:
   ```bash
   # Substitute environment variables
   export TASK_ID=42
   export TASK_TITLE="Add user authentication"
   export BOARD_ID=1
   export COLUMN_NAME="In Progress"

   # Execute hook from AGENTS.md
   git checkout -b "task-42-add-user-authentication" origin/main
   ```

6. **Agent reports hook execution** (optional):
   ```bash
   curl -X POST http://localhost:4000/api/tasks/42/hooks/after_claim \
     -H "Authorization: Bearer $TOKEN" \
     -d '{
       "status": "completed",
       "duration_ms": 1250,
       "output": "Created branch: task-42-add-user-authentication"
     }'
   ```

### Hook Execution Modes

**Blocking Hooks** (block workflow until complete):
- before_claim
- before_complete
- before_column_enter
- before_column_exit

**Non-Blocking Hooks** (fire and forget):
- after_claim
- after_complete
- after_column_enter
- after_column_exit

**Optional Hooks** (agent can skip):
- before_unclaim
- after_unclaim

## Environment Variables

Available to all hook commands:

```bash
# Task information
TASK_ID=42
TASK_TITLE="Add user authentication"
TASK_DESCRIPTION="Implement JWT authentication"
TASK_STATUS="in_progress"
TASK_COMPLEXITY="medium"
TASK_PRIORITY=0
TASK_NEEDS_REVIEW="true"  # Whether task requires human review

# Board/Column information
BOARD_ID=1
BOARD_NAME="Development"
COLUMN_ID=5
COLUMN_NAME="In Progress"
PREV_COLUMN_NAME="Ready"  # When moving between columns

# Agent information
AGENT_NAME="Claude Sonnet 4.5"
AGENT_CAPABILITIES="code_generation,testing,documentation"
API_TOKEN="kan_live_..."

# Hook context
HOOK_NAME="before_column_enter"
HOOK_TIMEOUT=60

# Unclaim-specific
UNCLAIM_REASON="Missing OAuth2 library dependencies"  # Only for unclaim hooks
```

## Error Handling

### Hook Failure Behavior

**Blocking Hooks** (before_*):
- If hook fails, action is aborted
- Task remains in previous state
- Error returned to agent
- Logged for debugging

**Non-Blocking Hooks** (after_*):
- If hook fails, action still completes
- Error logged but not returned to agent
- Retry attempted (configurable)

**Timeout Handling**:
- Hook process killed after timeout
- Treated as failure
- Logged with timeout reason

### Example Error Responses

```json
{
  "error": "Hook execution failed",
  "hook": "before_complete",
  "reason": "Quality checks failed: 3 tests failing",
  "output": "mix test\n...\n3 failures\n",
  "duration_ms": 5430,
  "task": {
    "id": 42,
    "status": "in_progress",
    "claimed_at": "2025-12-18T10:00:00Z"
  }
}
```

## Telemetry & Observability

### Telemetry Events

```elixir
:telemetry.execute(
  [:kanban, :hook, :executed],
  %{duration_ms: 1250, exit_code: 0},
  %{
    hook_name: "after_claim",
    task_id: 42,
    agent_id: "claude-sonnet-4.5",
    blocking: false,
    success: true
  }
)
```

### Metrics

- Counter: Hook executions by name and status (success/failure/timeout)
- Histogram: Hook execution duration by name
- Gauge: Currently running hooks
- Counter: Hook failures by error type

### Logging

```
[info] Hook execution started: task_id=42 hook=after_claim agent=claude-sonnet-4.5
[info] Hook execution completed: task_id=42 hook=after_claim duration=1250ms exit_code=0
[warn] Hook execution failed: task_id=42 hook=before_complete reason="tests failed" duration=5430ms
[error] Hook execution timeout: task_id=42 hook=before_column_enter timeout=60s
```

## Security Considerations

1. **Command Injection Prevention**:
   - All environment variables are sanitized
   - Hook commands run in restricted shell
   - No direct user input in commands

2. **Resource Limits**:
   - CPU and memory limits per hook
   - Timeout enforcement
   - Maximum output size

3. **Audit Trail**:
   - All hook executions logged
   - Output captured for debugging
   - Failed hooks require human review (configurable)

## Testing Strategy

### Unit Tests

1. Test hook parsing from .stride.md
2. Test environment variable substitution
3. Test timeout enforcement
4. Test error handling for failing hooks
5. Test blocking vs non-blocking behavior

### Integration Tests

1. Create task with hooks enabled
2. Claim task and verify after_claim hook runs
3. Move task to Review and verify before_column_enter hook runs
4. Complete task and verify after_complete hook runs
5. Test hook failure blocks action
6. Test hook timeout kills process

### Manual Testing

1. Create .stride.md with sample hooks
2. Enable hooks in board settings
3. Claim task via API as agent
4. Verify hooks execute correctly
5. Test hook failure scenarios
6. Verify logs and telemetry

## Implementation Tasks

### Task: Add Hook Configuration to Boards (New Task)

**Complexity:** Medium | **Est. Files:** 3-4

Add workflow_hooks field to boards table and enter_hooks/exit_hooks to columns table. Create UI for configuring hook settings.

### Task: Implement Hook Execution Engine (New Task)

**Complexity:** Large | **Est. Files:** 5-6

Build system to parse .stride.md, substitute environment variables, execute hooks, handle timeouts, and report results.

### Task: Add Hook Reporting to API (New Task)

**Complexity:** Small | **Est. Files:** 2-3

Add endpoints for agents to report hook execution status and results.

## Future Enhancements

1. **Conditional Hooks**: Run hooks only if certain conditions met
2. **Hook Dependencies**: Chain multiple hooks together
3. **Hook Templates**: Predefined hook libraries
4. **Visual Hook Editor**: UI for editing .stride.md
5. **Hook Testing Tool**: Test hooks without claiming tasks
6. **Hook Marketplace**: Share hook configurations
7. **Remote Hook Execution**: Run hooks on separate servers
8. **Hook Versioning**: Track changes to hook configurations

## References

- Related to Improvement #6 (Unclaim Mechanism)
- Related to Task 08 (Claim/Unclaim Endpoints)
- Related to Board Configuration
- Related to Column Management
