# Agent Capability Matching Implementation Summary

**Date:** 2025-12-18
**Improvement:** #3 from IMPROVEMENTS.md
**Related Improvements:** Works with #1 (Timeout) for complete task claiming system

## Overview

Implemented agent capability matching to ensure tasks are only assigned to agents with the appropriate skills to complete them. This prevents mismatched assignments where, for example, a documentation-only agent claims a complex database design task.

## Changes Made

### 1. Updated Task 02: Add Task Metadata Fields

**File:** `02-add-task-metadata-fields.md`

**Key Changes:**
- **Field Added**: `required_capabilities` (array of string) - Specifies which agent capabilities are needed to complete this task
- **Migration**: Added `required_capabilities` column with default empty array
- **Schema**: Added field to Task schema and changeset

**Example Values:**
- `[]` - Any agent can claim this task
- `["code_generation"]` - Agent must be able to write code
- `["code_generation", "database_design"]` - Agent must have both capabilities
- `["documentation"]` - Documentation-only task

### 2. Updated Task 06: Create API Authentication

**File:** `06-create-api-authentication.md`

**Key Changes:**
- **Field Added**: `capabilities` (array of string) - Agent's capabilities
- **Field Added**: `metadata` (jsonb) - Additional agent metadata (model name, version)
- **Standard Capabilities Defined**: 12 standard capability types documented
- **Acceptance Criteria**: Added capability and metadata requirements

**Standard Capabilities:**
```
code_generation        # Can write code (most programming tasks)
code_review            # Can review code quality and suggest improvements
database_design        # Can design schemas and write migrations
testing                # Can write automated tests
documentation          # Can write docs, comments, READMEs
debugging              # Can diagnose and fix bugs
refactoring            # Can improve code structure without changing behavior
api_design             # Can design REST/GraphQL APIs
ui_implementation      # Can implement user interfaces
performance_optimization  # Can optimize slow code
security_analysis      # Can identify security vulnerabilities
devops                 # Can write CI/CD, Docker, deployment configs
```

**Capability Matching Logic:**
- Task specifies required capabilities
- API token includes agent capabilities
- Task is only returned if agent has ALL required capabilities
- Empty required_capabilities means any agent can claim

### 3. Updated Task 08: Add Task Ready/Claim Endpoints

**File:** `08-add-task-ready-endpoint.md`

**Key Changes:**
- **Description**: Added capability filtering requirement
- **Acceptance Criteria**: Added capability matching criteria
- **Query Logic**: Added PostgreSQL array subset check (`required_capabilities <@ agent_capabilities`)
- **Function Signatures**: Updated `get_next_task/1` and `claim_next_task/1` to accept `agent_capabilities` parameter
- **Controller Actions**: Extract capabilities from API token and pass to context functions
- **Error Messages**: Updated to mention capability mismatch
- **Telemetry**: Added `required_capabilities` and `agent_capabilities` to telemetry metadata

**Capability Matching Implementation:**

Query uses PostgreSQL array subset operator:
```sql
WHERE (task.required_capabilities = '{}' OR task.required_capabilities <@ agent.capabilities)
```

This ensures:
- Tasks with no requirements (`[]`) are available to all agents
- Tasks with requirements are only available to agents with ALL those capabilities

### 4. Updated IMPROVEMENTS.md

**File:** `IMPROVEMENTS.md`

**Key Changes:**
- Marked improvement #3 as "✅ IMPLEMENTED"
- Added status section with implementation details
- Cross-referenced tasks 02, 06, and 08

## Technical Implementation

### Database Changes

**Task Schema (task 02):**
```elixir
ALTER TABLE tasks ADD COLUMN required_capabilities TEXT[] DEFAULT '{}';
```

**API Token Schema (task 06):**
```elixir
ALTER TABLE api_tokens ADD COLUMN capabilities TEXT[] DEFAULT '{}';
ALTER TABLE api_tokens ADD COLUMN metadata JSONB DEFAULT '{}';
```

### Query Logic (task 08)

**Capability Filtering Fragment:**
```elixir
where: fragment(
  "cardinality(?) = 0 OR ? <@ ?",
  t.required_capabilities,
  t.required_capabilities,
  ^agent_capabilities
)
```

**Breakdown:**
- `cardinality(?) = 0` - Task has no capability requirements (empty array)
- `? <@ ?` - Task's required capabilities are a subset of agent's capabilities
- Returns `true` if either condition is met

### Context Functions (task 08)

**Function Signatures:**
```elixir
def get_next_task(agent_capabilities \\ [])
def claim_next_task(agent_capabilities \\ [])
```

**Controller Integration:**
```elixir
def next(conn, _params) do
  agent_capabilities = conn.assigns.api_token.capabilities || []
  case Tasks.get_next_task(agent_capabilities) do
    # ...
  end
end

def claim(conn, _params) do
  agent_capabilities = conn.assigns.api_token.capabilities || []
  case Tasks.claim_next_task(agent_capabilities) do
    # ...
  end
end
```

### API Token Creation (task 06)

**Example Token Creation:**
```elixir
{:ok, token, plain_token} = Accounts.create_api_token(user, %{
  name: "Claude Sonnet 4.5 Agent",
  scopes: ["tasks:read", "tasks:write"],
  capabilities: ["code_generation", "testing", "documentation", "debugging"],
  metadata: %{
    "ai_agent" => "claude-sonnet-4.5",
    "version" => "20251101",
    "provider" => "Anthropic"
  }
})
```

### Task Creation with Capabilities

**Example Task:**
```elixir
{:ok, task} = Tasks.create_task(%{
  title: "Implement user authentication system",
  required_capabilities: ["code_generation", "database_design", "security_analysis"],
  complexity: "large",
  column_id: ready_column.id
})
```

## Benefits

### For AI Agents
1. **Appropriate Work Assignment**: Only see tasks they can actually complete
2. **Clear Requirements**: Know upfront what capabilities are needed
3. **Reduced Failures**: Don't claim tasks they can't finish
4. **Better Resource Utilization**: Specialized agents work on specialized tasks

### For System
1. **Quality Assurance**: Tasks matched to agent expertise
2. **Efficiency**: Right agent for the right job
3. **Flexibility**: Easy to add new capability types
4. **Observability**: Telemetry tracks capability matches and mismatches

### For Task Creators
1. **Control**: Specify exactly what skills are needed
2. **Safety**: Complex tasks only go to capable agents
3. **Optional**: Empty array means any agent can claim

## Observability

**Enhanced Telemetry Events:**
- `[:kanban, :api, :next_task_fetched]` - Now includes `required_capabilities`
- `[:kanban, :api, :task_claimed]` - Now includes both `required_capabilities` and `agent_capabilities`

**New Metrics:**
- Counter: Tasks claimed by capability type
- Counter: Capability mismatches (tasks available but agent lacks capabilities)
- Histogram: Distribution of required capabilities per task
- Gauge: Agents online by capability profile

**New Logging:**
- Info level: Task claims include agent capabilities and required capabilities
- Debug level: Capability match checks for debugging

## Testing Strategy

**Unit Tests:**
1. Test task with empty required_capabilities is available to any agent
2. Test task with capabilities is only available to agents with those capabilities
3. Test agent with subset of required capabilities cannot claim task
4. Test agent with superset of required capabilities can claim task
5. Test multiple tasks filtered correctly by different capability sets

**Integration Tests:**
1. Create two agents: one with `["code_generation"]`, one with `["documentation"]`
2. Create coding task with `required_capabilities: ["code_generation"]`
3. Verify only coding agent sees the task
4. Create doc task with `required_capabilities: ["documentation"]`
5. Verify only doc agent sees the task
6. Create task with `required_capabilities: []`
7. Verify both agents see the task

**Manual Testing:**
See task 08 for complete manual test scenarios including capability filtering.

## Migration Path

**Step 1: Database Migrations (Tasks 02 & 06)**
```bash
mix ecto.gen.migration add_capabilities
mix ecto.migrate
```

**Step 2: Schema Updates (Tasks 02 & 06)**
Update Task and ApiToken schemas to include new fields.

**Step 3: Context Functions (Task 08)**
Update `get_next_task/1` and `claim_next_task/1` to accept and filter by capabilities.

**Step 4: Controller Updates (Task 08)**
Extract capabilities from API token and pass to context functions.

**Step 5: Token Creation UI (Task 06)**
Add capability selection to token generation form.

**Step 6: Task Creation UI (Task 04)**
Add required_capabilities field to task creation form.

## Usage Examples

### Creating an Agent Token

```bash
# In user settings, create API token with capabilities
Name: "Claude Agent"
Scopes: [tasks:read, tasks:write]
Capabilities: [code_generation, testing, documentation]
Metadata:
  - ai_agent: claude-sonnet-4.5
  - version: 20251101
```

### Creating a Task with Requirements

```elixir
# Via API or UI
POST /api/tasks
{
  "title": "Implement OAuth2 authentication",
  "required_capabilities": ["code_generation", "security_analysis", "api_design"],
  "complexity": "large",
  "description": "Add OAuth2 support to API"
}
```

### Claiming a Task

```bash
# Agent with matching capabilities
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer kan_live_abc123..."

# Returns task if agent has required capabilities
# Returns 409 if no tasks match agent's capabilities
```

## Configuration

**No Configuration Required:**
- Capabilities are user-defined per token
- No hardcoded capability validation
- Standard capabilities are documentation only (not enforced)

**Extensibility:**
- Add new capability types at any time
- No code changes needed for new capabilities
- Consider adding capability validation in UI for consistency

## Future Enhancements (Out of Scope)

From IMPROVEMENTS.md, these related features are NOT implemented:

1. **Partial Capability Matching**: Task recommends agent with 80% match
2. **Capability Levels**: Beginner/intermediate/expert coding ability
3. **Capability Learning**: Track which agents excel at which capabilities
4. **Dynamic Capability Detection**: Automatically detect agent capabilities from model metadata
5. **Capability Negotiation**: Suggest alternative agents for unclaimed tasks
6. **Capability Requirements Inference**: Automatically suggest required capabilities based on task description

## Dependencies

**Task 02 Must Complete First:**
- Tasks 06 and 08 depend on task 02 for the `required_capabilities` field

**Task 06 Must Complete Before Task 08:**
- Task 08 needs API tokens with capabilities field

## Success Criteria

- [ ] Tasks with required capabilities only available to matching agents
- [ ] Tasks with empty required capabilities available to all agents
- [ ] Agent capabilities stored in API tokens
- [ ] Telemetry tracks capability matches
- [ ] Error messages explain capability mismatches
- [ ] No performance impact on claiming queries
- [ ] Tests cover all capability matching scenarios

## Rollback Plan

If issues arise:

1. **Revert Query Logic:**
```elixir
# Remove capability check from query
# Tasks become available to all agents again
```

2. **Keep Database Columns:**
- Leave `required_capabilities` and `capabilities` columns
- Just don't filter by them
- Re-enable later when ready

3. **Future: Remove Feature:**
- Stop populating capability fields
- Keep columns for historical data

## Documentation References

- **Full Implementation**: See tasks 02, 06, and 08
- **Standard Capabilities**: See task 06 (lines 70-84)
- **Requirements**: See IMPROVEMENTS.md improvement #3
- **Query Logic**: See task 08 (lines 287-292, 338-343)
- **API Workflow**: See task 08 controller examples
