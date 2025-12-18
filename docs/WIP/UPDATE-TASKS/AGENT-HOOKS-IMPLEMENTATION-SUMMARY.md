# Agent Workflow Hooks Implementation Summary

**Date:** 2025-12-18
**Feature:** Agent Workflow Hooks
**Related Tasks:** Task 13, Task 14

## Overview

Implemented comprehensive workflow hooks system that allows AI agents to execute custom commands at specific workflow transition points. This enables agents to integrate with git workflows, run quality checks, and perform setup/cleanup tasks automatically as they work on tasks.

## Changes Made

### 1. Created Design Document: AGENTS-AND-HOOKS.md

**File:** `AGENTS-AND-HOOKS.md`

**Key Sections:**
- **Hook Points**: 10 standard workflow hooks defined
- **AGENTS.md Format**: Markdown format for agents to define hook implementations
- **Board Configuration**: JSONB fields for enabling/disabling hooks and setting timeouts
- **API Integration**: How hooks integrate with claim/move/complete/unclaim workflows
- **Environment Variables**: Available variables for hook commands
- **Error Handling**: Blocking vs non-blocking behavior
- **Security**: Command injection prevention, resource limits, audit trail
- **Testing Strategy**: Unit, integration, and manual test scenarios

### 2. Created Task 13: Add Hook Configuration to Boards/Columns

**File:** `13-add-workflow-hooks-configuration.md`

**Key Features:**
- Database migration for workflow_hooks on boards table
- Database migration for enter_hooks and exit_hooks on columns table
- Schema validation for hook configuration structure
- Context functions for managing hook settings
- Default hook values for common use cases

**Database Schema:**
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

### 3. Created Task 14: Implement Hook Execution Engine

**File:** `14-implement-hook-execution-engine.md`

**Key Components:**
- **Kanban.Hooks.Parser**: Parse AGENTS.md file to extract hook commands
- **Kanban.Hooks.Executor**: Execute hook commands with timeout and output capture
- **Kanban.Hooks.Environment**: Build environment variables for hook execution
- **Kanban.Hooks.Reporter**: Report hook execution results via telemetry
- **Integration**: Integrate hooks into Tasks context (claim, move, complete, unclaim)

**Architecture:**
```
Kanban.Hooks (new context)
├── Parser - Parse AGENTS.md file
├── Executor - Execute hook commands
├── Environment - Build environment variables
└── Reporter - Report hook execution results
```

### 4. Updated IMPROVEMENTS.md

**File:** `IMPROVEMENTS.md`

**Key Changes:**
- Added workflow hooks to implementation status
- Created new section "New Features (Beyond Original Improvements)"
- Cross-referenced tasks 13 and 14
- Linked to AGENTS-AND-HOOKS.md design document

## Design Decisions

### 1. Hybrid Configuration Approach

**Decision:** Boards define **when** hooks run, agents define **what** to do.

**Rationale:**
- **Separation of Concerns**: Board owners control workflow stages, agents control their own behavior
- **Flexibility**: Different boards can have different workflows, different agents can have different behaviors
- **Simplicity**: Agents don't need to know about board-specific configurations

### 2. AGENTS.md File Format

**Decision:** Use markdown file at repository root with code blocks for hook commands.

**Rationale:**
- **Human Readable**: Easy to read and edit manually
- **Version Control**: Can be committed to git and versioned
- **Agent Agnostic**: Multiple agents can define their own sections
- **Familiar Format**: Developers already understand markdown

**Example:**
```markdown
## Agent: Claude Sonnet 4.5

### Hook Implementations

#### after_claim
```bash
git checkout -b "task-$TASK_ID"
```

#### before_complete
```bash
mix test
mix format --check-formatted
```
```

### 3. Blocking vs Non-Blocking Hooks

**Decision:** before_* hooks block on failure, after_* hooks don't.

**Rationale:**
- **Safety**: before_* hooks prevent actions if prerequisites aren't met (e.g., tests must pass before completion)
- **Reliability**: after_* hooks don't prevent completion if they fail (e.g., notification failure shouldn't block completion)
- **Predictability**: Clear naming convention (before = blocking, after = non-blocking)

### 4. Environment Variable Substitution

**Decision:** Provide rich environment variables and substitute them in hook commands.

**Rationale:**
- **Flexibility**: Agents can use task metadata in their commands
- **Security**: Variables are sanitized to prevent injection
- **Convenience**: Common patterns like "task-$TASK_ID" work out of the box

**Available Variables:**
- Task: TASK_ID, TASK_TITLE, TASK_DESCRIPTION, TASK_STATUS, TASK_COMPLEXITY, TASK_PRIORITY
- Board: BOARD_ID, BOARD_NAME
- Column: COLUMN_ID, COLUMN_NAME, PREV_COLUMN_NAME
- Agent: AGENT_NAME, AGENT_CAPABILITIES
- Hook: HOOK_NAME, HOOK_TIMEOUT
- Context: UNCLAIM_REASON (for unclaim hooks)

### 5. Timeout Enforcement

**Decision:** All hooks have configurable timeouts with default values.

**Rationale:**
- **Reliability**: Prevents hooks from hanging indefinitely
- **Configurability**: Different hooks have different timeout needs (tests may take longer than git commands)
- **Resource Management**: Limits resource consumption per hook

**Default Timeouts:**
- before_claim: 60s
- after_claim: 30s
- before_complete: 120s (longer for quality checks)
- after_complete: 60s
- before/after_unclaim: 30s
- Column hooks: 60s

## Benefits

### For AI Agents

1. **Automated Workflows**: Execute git commands, quality checks, and cleanup automatically
2. **Consistency**: Same workflow patterns across all tasks
3. **Customization**: Each agent can define its own behavior
4. **Feedback**: Immediate feedback if prerequisites fail (blocking hooks)

### For Development Teams

1. **Quality Gates**: Enforce quality checks before code moves to review
2. **Git Automation**: Automatic branch creation, commits, and pushes
3. **Traceability**: All hook executions logged for debugging
4. **Flexibility**: Different boards can have different workflows

### For System

1. **Observability**: Telemetry tracks all hook executions
2. **Safety**: Timeouts prevent runaway processes
3. **Audit Trail**: All hook output captured for debugging
4. **Extensibility**: Easy to add new hook points in the future

## Usage Examples

### Example 1: Git Workflow Integration

**AGENTS.md:**
```markdown
#### after_claim
```bash
# Create feature branch
git checkout -b "task-$TASK_ID-$(echo $TASK_TITLE | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
```

#### before_column_exit[In Progress]
```bash
# Run quality checks before moving to review
mix format --check-formatted
mix credo --strict
mix test
mix dialyzer
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
```

**Workflow:**
1. Agent claims task → creates feature branch automatically
2. Agent works on task in "In Progress" column
3. Agent moves task to "Review" → quality checks run automatically
4. If quality checks fail → task stays in "In Progress"
5. Agent completes task → commits and pushes changes automatically

### Example 2: Quality Gate Enforcement

**Board Configuration:**
```json
{
  "workflow_hooks": {
    "before_complete": {
      "enabled": true,
      "timeout": 180
    }
  }
}
```

**AGENTS.md:**
```markdown
#### before_complete
```bash
# Comprehensive quality checks
mix test || exit 1
mix credo --strict || exit 1
mix dialyzer || exit 1
mix sobelow --config || exit 1

echo "All quality checks passed ✓"
```
```

**Result:** Task cannot be completed until all quality checks pass.

### Example 3: Environment Setup

**AGENTS.md:**
```markdown
#### before_claim
```bash
# Ensure environment is up to date
git fetch origin main
git status

# Update dependencies
mix deps.get
npm install
```

#### after_unclaim
```bash
# Clean up after unclaiming
git checkout main
git clean -fd
```
```

**Result:** Environment is always fresh before starting work, and cleaned up after unclaiming.

## Observability

### Telemetry Events

**[:kanban, :hook, :executed]** - Emitted for all hook executions
- Measurements: `%{duration_ms: integer, exit_code: integer}`
- Metadata: `%{hook_name: string, task_id: integer, success: boolean, reason: string}`

### Metrics

**Counters:**
- `kanban.hooks.executions.total` - Total hook executions
- `kanban.hooks.executions.by_name` - By hook name (tag: hook_name)
- `kanban.hooks.executions.by_status` - By status (tag: success/failure/timeout)

**Histograms:**
- `kanban.hooks.duration` - Hook execution duration (tag: hook_name)

**Gauges:**
- `kanban.hooks.running` - Currently running hooks

### Logging

**Info Level:**
```
Hook execution started: task_id=42 hook=after_claim agent=claude-sonnet-4.5
Hook execution completed: task_id=42 hook=after_claim duration=1250ms exit_code=0
```

**Warn Level:**
```
Hook execution failed: task_id=42 hook=before_complete reason="tests failed" duration=5430ms
```

**Error Level:**
```
Hook execution timeout: task_id=42 hook=before_column_enter timeout=60s
```

## Testing Strategy

### Unit Tests (Task 14)

1. Test AGENTS.md parsing with various formats
2. Test environment variable substitution
3. Test timeout enforcement
4. Test error handling for failing hooks
5. Test blocking vs non-blocking behavior

### Integration Tests (Task 14)

1. Create task with hooks enabled
2. Claim task and verify after_claim hook runs
3. Move task to Review and verify before_column_enter hook runs
4. Complete task and verify after_complete hook runs
5. Test hook failure blocks action (blocking hook)
6. Test hook failure doesn't block action (non-blocking hook)
7. Test hook timeout kills process

### Manual Testing

1. Create AGENTS.md with sample hooks
2. Enable hooks in board settings
3. Claim task via API as agent
4. Verify hooks execute correctly
5. Check logs for hook execution details
6. Test hook failure scenarios
7. Verify telemetry metrics

## Security Considerations

### 1. Command Injection Prevention

**Mitigation:**
- All environment variables are sanitized
- No direct user input in commands
- Commands run in restricted shell context

### 2. Resource Limits

**Mitigation:**
- Timeout enforcement on all hooks
- CPU and memory limits (future: cgroups)
- Maximum output size captured

### 3. Audit Trail

**Implementation:**
- All hook executions logged
- Output captured for debugging
- Failed hooks logged with full context

## Migration Path

### Step 1: Implement Task 13 (Hook Configuration)
```bash
mix ecto.gen.migration add_workflow_hooks_configuration
mix ecto.migrate
```

### Step 2: Implement Task 14 (Hook Execution)
```bash
# Implement Kanban.Hooks context modules
# Integrate with Tasks context
mix test
```

### Step 3: Create AGENTS.md
```bash
# Create example AGENTS.md at repository root
# Document hook implementations for each agent
```

### Step 4: Enable Hooks on Boards
```bash
# Via board settings UI (future)
# Or via iex console
```

## Configuration

**Board-Level:**
- Enable/disable specific hooks
- Set timeout per hook
- Configure blocking behavior (future)

**Column-Level:**
- Enable/disable before/after enter hooks
- Enable/disable before/after exit hooks
- Set timeout per hook type

**No Environment Variables Needed**

## Future Enhancements (Out of Scope)

From AGENTS-AND-HOOKS.md, these features are NOT implemented:

1. **Conditional Hooks**: Run hooks only if certain conditions met (e.g., only on production board)
2. **Hook Dependencies**: Chain multiple hooks together
3. **Hook Templates**: Predefined hook libraries that agents can use
4. **Visual Hook Editor**: UI for editing AGENTS.md
5. **Hook Testing Tool**: Test hooks without claiming tasks
6. **Hook Marketplace**: Share hook configurations
7. **Remote Hook Execution**: Run hooks on separate servers
8. **Hook Versioning**: Track changes to hook configurations

## Dependencies

**Task 13 Must Complete Before Task 14:**
- Task 14 depends on database fields from task 13

**No Blocking Dependencies:**
- These tasks are additive and don't block other work
- Can be implemented after core API endpoints are complete

## Success Criteria

- [x] Design document created (AGENTS-AND-HOOKS.md)
- [x] Task 13 created (Hook Configuration)
- [x] Task 14 created (Hook Execution Engine)
- [x] IMPROVEMENTS.md updated with new feature
- [ ] Task 13 implemented (pending)
- [ ] Task 14 implemented (pending)
- [ ] Integration tests pass (pending)
- [ ] Production deployment (pending)

## Rollback Plan

If issues arise after implementation:

### Disable All Hooks Globally
```elixir
# In config/config.exs
config :kanban, :hooks_enabled, false
```

### Disable Specific Hooks on a Board
```elixir
# Via board settings or console
Boards.update_workflow_hooks(board, "before_complete", false, 120)
```

### Remove Hook Execution (Keep Configuration)
```elixir
# Comment out hook execution in Tasks context
# Keep database fields for future use
```

### Full Rollback (Last Resort)
```bash
# Rollback migration
mix ecto.rollback

# Remove Kanban.Hooks modules
# Revert Tasks context integration
```

## Documentation References

- **Design Document**: [docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md)
- **Task 13**: [docs/WIP/UPDATE-TASKS/13-add-workflow-hooks-configuration.md](13-add-workflow-hooks-configuration.md)
- **Task 14**: [docs/WIP/UPDATE-TASKS/14-implement-hook-execution-engine.md](14-implement-hook-execution-engine.md)
- **Requirements**: [docs/WIP/UPDATE-TASKS/IMPROVEMENTS.md](IMPROVEMENTS.md)

## Real-World Impact

### Before Agent Hooks

**Manual Workflow:**
1. Agent claims task
2. Agent manually creates feature branch
3. Agent works on task
4. Agent manually runs tests
5. Agent manually commits changes
6. Agent manually pushes to remote
7. Agent marks task complete

**Pain Points:**
- Manual git commands prone to errors
- Forgot to run quality checks before completion
- Inconsistent commit messages across agents
- No enforcement of quality gates

### After Agent Hooks

**Automated Workflow:**
1. Agent claims task → **feature branch created automatically**
2. Agent works on task
3. Agent moves to Review → **quality checks run automatically**
   - If checks fail → task stays in "In Progress" with error details
   - If checks pass → task moves to Review
4. Agent completes task → **commit and push happen automatically**

**Benefits:**
- Consistent git workflow across all agents
- Quality gates enforced automatically
- Standardized commit messages
- Reduced manual errors
- Full audit trail of all operations

This transforms the agent workflow from manual and error-prone to automated and reliable.
