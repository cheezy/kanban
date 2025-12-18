# needs_review Field Feature Summary

**Date:** 2025-12-18
**Feature:** Optional Human Review Flag
**Related Tasks:** Task 02 (Task Metadata Fields), AGENTS-AND-HOOKS.md

## Overview

Added a `needs_review` boolean field to tasks (default: false) that allows humans to specify which tasks require human review and which can be automatically completed by agents. This provides flexibility to focus review effort on high-risk changes while allowing agents to autonomously complete low-risk tasks.

## Changes Made

### 1. Updated Task 02: Add Task Metadata Fields

**File:** `02-add-task-metadata-fields.md`

**Key Changes:**
- Added `needs_review` field to tasks table migration (boolean, default: false)
- Added `needs_review` field to Task schema
- Added `needs_review` to changeset cast fields
- Created index on needs_review for filtering tasks by review requirement
- Updated field documentation to explain the flag's purpose

**Migration:**
```elixir
add :needs_review, :boolean, default: false  # Whether task requires human review
```

**Schema:**
```elixir
field :needs_review, :boolean, default: false
```

### 2. Updated IMPROVEMENTS.md

**File:** `IMPROVEMENTS.md`

**Key Changes:**
- Updated improvement #10 (Human Review Queue) to document needs_review field
- Added workflow descriptions for both needs_review = true and needs_review = false
- Provided examples of when to use each setting
- Explained that review hooks still execute even when needs_review = false

### 3. Updated AGENTS-AND-HOOKS.md

**File:** `AGENTS-AND-HOOKS.md`

**Key Changes:**
- Added dedicated "Review Workflow and needs_review Flag" section
- Documented behavior when needs_review = true vs false
- Added notes to review column hooks explaining they execute regardless of needs_review value
- Added TASK_NEEDS_REVIEW environment variable for hook commands
- Provided use case examples for both settings

### 4. Updated Task 14: Hook Execution Engine

**File:** `14-implement-hook-execution-engine.md`

**Key Changes:**
- Added TASK_NEEDS_REVIEW to environment variables in Environment.build/3 function
- Hooks can check this variable to conditionally execute logic based on review requirements

## Design Rationale

### Why Default to false?

**Decision:** Default needs_review to false (no review required).

**Rationale:**
- Most tasks in a typical workflow are low-risk and don't require human review
- Agents can autonomously complete documentation, tests, minor fixes
- Humans explicitly opt-in to review for high-risk changes
- Reduces friction for autonomous agent operation
- Focuses human attention where it's most valuable

### Why Execute Review Hooks Even When needs_review = false?

**Decision:** Review column hooks execute even when needs_review = false.

**Rationale:**
- Allows automated quality checks (tests, linters, security scans) via hooks
- Provides consistency in workflow execution
- Hooks can use TASK_NEEDS_REVIEW env var to conditionally skip certain actions
- Separates "moving to review column" from "waiting for human review"

**Example:**
```bash
#### before_column_enter[Review]
```bash
# Always run automated quality checks
mix test
mix credo --strict

# Only request human review if needed
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  echo "Requesting human review for task $TASK_ID"
  # Send notification to reviewers
fi
```
```

## Workflow Behavior

### When needs_review = true (Human Review Required)

**Workflow:**
1. Agent completes work on task
2. Agent moves task to Review column
3. before_column_enter[Review] hook executes (quality checks)
4. Task enters Review column
5. after_column_enter[Review] hook executes (request review notification)
6. **Task waits for human review**
7. Human reviews task and sets review_status (approved/changes_requested/rejected)
8. If approved, task moves to Done
9. If changes_requested, agent addresses feedback and task returns to In Progress

**Use Cases:**
- Security-related changes (authentication, authorization, encryption)
- Database schema migrations
- API contract changes (breaking changes to public APIs)
- Production configuration changes
- Financial/payment processing logic
- Data privacy/compliance changes

### When needs_review = false (No Human Review)

**Workflow:**
1. Agent completes work on task
2. Agent marks task as complete
3. before_column_enter[Review] hook executes (quality checks) - **still runs**
4. after_column_exit[Review] hook executes (if configured) - **still runs**
5. **Task skips Review column** and moves directly to Done
6. No human intervention required

**Use Cases:**
- Documentation updates (README, inline comments)
- Automated dependency updates (minor versions)
- Minor bug fixes in non-critical code
- Test additions (new test cases)
- Code formatting/linting changes
- Refactoring with no behavioral changes
- Configuration updates (non-production)

## Benefits

### For AI Agents

1. **Autonomy**: Can complete low-risk tasks without waiting for human approval
2. **Efficiency**: Faster completion of routine tasks
3. **Context Awareness**: Can check TASK_NEEDS_REVIEW in hooks to adjust behavior
4. **Consistency**: Same workflow regardless of review requirement

### For Humans

1. **Focus**: Review effort concentrated on high-risk changes
2. **Efficiency**: Don't need to review routine updates
3. **Control**: Explicit opt-in for tasks requiring review
4. **Flexibility**: Can adjust review requirements on a per-task basis

### For System

1. **Throughput**: Higher task completion rate with selective review
2. **Quality**: Automated checks still run via hooks
3. **Auditability**: Clear indication which tasks were reviewed vs auto-completed
4. **Scalability**: System can handle more tasks with same human capacity

## Examples

### Example 1: Security Change (needs_review = true)

**Task:** "Implement OAuth2 authentication"

**Configuration:**
```json
{
  "title": "Implement OAuth2 authentication",
  "needs_review": true,
  "required_capabilities": ["code_generation", "security_analysis"]
}
```

**Workflow:**
1. Agent implements OAuth2
2. Agent moves to Review column
3. Hooks run automated security scans
4. Human reviews security implementation
5. Human sets review_status = "approved" after security audit
6. Task moves to Done

**Rationale:** Security changes require human verification to prevent vulnerabilities.

### Example 2: Documentation Update (needs_review = false)

**Task:** "Update API documentation for new endpoint"

**Configuration:**
```json
{
  "title": "Update API documentation for new endpoint",
  "needs_review": false,
  "required_capabilities": ["documentation"]
}
```

**Workflow:**
1. Agent updates documentation
2. Agent marks task complete
3. Hooks run spell check and link validation
4. Task moves directly to Done
5. No human review needed

**Rationale:** Documentation updates are low-risk and can be autonomously completed.

### Example 3: Database Migration (needs_review = true)

**Task:** "Add user_preferences table to database"

**Configuration:**
```json
{
  "title": "Add user_preferences table to database",
  "needs_review": true,
  "required_capabilities": ["database_design"]
}
```

**Workflow:**
1. Agent writes migration
2. Agent moves to Review column
3. Hooks run migration validation
4. Human reviews schema design
5. Human verifies migration is reversible
6. Human sets review_status = "approved"
7. Task moves to Done

**Rationale:** Database migrations are risky and require human verification before production deployment.

### Example 4: Conditional Hook Behavior

**AGENTS.md Hook Example:**
```bash
#### before_column_enter[Review]
```bash
# Always run quality checks
mix test || exit 1
mix credo --strict || exit 1

# Only request human review if needed
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  echo "🔍 Requesting human review for task $TASK_ID"
  # Send Slack notification to reviewers
  curl -X POST https://slack.com/api/chat.postMessage \
    -d "text=Task $TASK_ID requires review: $TASK_TITLE" \
    -d "channel=#code-review"
else
  echo "✅ Task $TASK_ID auto-approved (no review required)"
fi
```
```

This allows hooks to adapt their behavior based on whether human review is required.

## Database Schema

**Migration (task 02):**
```elixir
alter table(:tasks) do
  add :needs_review, :boolean, default: false
end

create index(:tasks, [:needs_review])
```

**Query Examples:**
```elixir
# Get all tasks requiring review
from t in Task, where: t.needs_review == true

# Get tasks that don't need review but are in review status
from t in Task,
  where: t.needs_review == false and t.review_status == "pending"

# Count tasks by review requirement
from t in Task,
  group_by: t.needs_review,
  select: {t.needs_review, count(t.id)}
```

## Environment Variable

**Available in all hooks:**
```bash
TASK_NEEDS_REVIEW="true"   # or "false"
```

**Usage in hooks:**
```bash
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  # Execute review-specific actions
fi
```

## Analytics & Metrics

**Recommended Metrics:**
- Counter: Tasks completed by needs_review flag (true vs false)
- Gauge: Current tasks in review by needs_review flag
- Histogram: Time spent in review by needs_review flag
- Counter: Review status outcomes (approved, changes_requested, rejected) by needs_review flag

**Dashboard Recommendations:**
- Show ratio of reviewed vs auto-completed tasks
- Track average review time for tasks with needs_review = true
- Monitor tasks stuck in review for > 24 hours
- Show top task types by review requirement

## Testing Strategy

### Unit Tests
1. Test task creation with needs_review = true
2. Test task creation with needs_review = false (default)
3. Test task creation with needs_review explicitly set
4. Test query filtering by needs_review flag
5. Test environment variable includes TASK_NEEDS_REVIEW

### Integration Tests
1. Create task with needs_review = false → verify skips review column
2. Create task with needs_review = true → verify enters review column
3. Complete task with needs_review = false → verify no review_status set
4. Complete task with needs_review = true → verify review_status = "pending"
5. Test hooks execute regardless of needs_review value
6. Test hook can read TASK_NEEDS_REVIEW env var

## Future Enhancements (Out of Scope)

1. **Automatic needs_review Assignment**: Use ML to suggest needs_review based on task content
2. **Review Templates**: Predefined review checklists for different task types
3. **Review Delegation**: Assign specific reviewers based on task attributes
4. **Review SLA Tracking**: Alert when tasks requiring review exceed time thresholds
5. **Batch Review**: Allow reviewers to approve/reject multiple tasks at once
6. **Review History**: Track who reviewed what and when across all tasks

## Migration Path

**Step 1: Add Field (Task 02)**
```bash
mix ecto.gen.migration add_needs_review_to_tasks
mix ecto.migrate
```

**Step 2: Update Existing Tasks (Optional)**
```elixir
# Set needs_review = true for existing tasks in Review column
from(t in Task, where: t.column.name == "Review")
|> Repo.update_all(set: [needs_review: true])
```

**Step 3: Update Task Creation UI**
Add checkbox for "Requires human review" when creating tasks.

**Step 4: Update Agent Logic**
Agents check task.needs_review before moving to Review column.

## Success Criteria

- [x] needs_review field added to tasks table
- [x] Default value is false
- [x] Schema updated with field
- [x] Index created for filtering
- [x] TASK_NEEDS_REVIEW environment variable available in hooks
- [x] Documentation updated (IMPROVEMENTS.md, AGENTS-AND-HOOKS.md)
- [ ] Migration implemented (pending)
- [ ] UI updated to support field (pending)
- [ ] Tests written (pending)

## Rollback Plan

If issues arise:

**Disable Feature (Keep Field):**
```elixir
# Set all tasks to needs_review = true (revert to manual review)
Repo.update_all(Task, set: [needs_review: true])
```

**Remove Field (Full Rollback):**
```bash
# Create rollback migration
mix ecto.gen.migration remove_needs_review_from_tasks

# In migration:
alter table(:tasks) do
  remove :needs_review
end

mix ecto.migrate
```

## Documentation References

- **Task Definition**: [docs/WIP/UPDATE-TASKS/02-add-task-metadata-fields.md](02-add-task-metadata-fields.md)
- **Workflow Hooks**: [docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md)
- **Requirements**: [docs/WIP/UPDATE-TASKS/IMPROVEMENTS.md](IMPROVEMENTS.md#-10-human-review-queue-implemented)
- **Hook Execution**: [docs/WIP/UPDATE-TASKS/14-implement-hook-execution-engine.md](14-implement-hook-execution-engine.md)

## Summary

The `needs_review` field provides a simple but powerful mechanism to balance agent autonomy with human oversight. By defaulting to false and allowing humans to opt-in for high-risk changes, the system can achieve:

- **Higher throughput**: More tasks completed autonomously
- **Focused review**: Human effort on critical changes only
- **Maintained quality**: Automated checks still run via hooks
- **Flexibility**: Adjust per-task as needed

This feature is essential for scaling agent-driven development while maintaining appropriate human control over risky changes.
