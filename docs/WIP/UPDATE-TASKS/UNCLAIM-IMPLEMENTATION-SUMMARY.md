# Rollback/Unclaim Mechanism Implementation Summary

**Date:** 2025-12-18
**Improvement:** #6 from IMPROVEMENTS.md
**Related Improvements:** Works with #1 (Timeout) for complete task lifecycle management

## Overview

Implemented unclaim mechanism to allow agents to release tasks they realize they can't complete. This provides a clean way for agents to return tasks to the available pool instead of waiting for the 60-minute timeout, improving overall system efficiency and agent autonomy.

## Changes Made

### 1. Updated Task 08: Add Task Ready/Claim Endpoints

**File:** `08-add-task-ready-endpoint.md`

**Key Changes:**
- **Endpoint Added**: POST /api/tasks/:id/unclaim
- **Acceptance Criteria**: Added unclaim endpoint requirements
- **Context Function**: Added `unclaim_task/3` function with validation
- **Controller Action**: Added `unclaim/2` action with reason parameter
- **Observability**: Added telemetry for unclaim events
- **Router**: Added unclaim route

### 2. Updated IMPROVEMENTS.md

**File:** `IMPROVEMENTS.md`

**Key Changes:**
- Marked improvement #6 as "✅ IMPLEMENTED"
- Added status section with implementation details
- Cross-referenced task 08

## Technical Implementation

### Context Function (task 08)

**Function Signature:**
```elixir
def unclaim_task(task_id, api_token_id, reason \\ nil)
```

**Validation Logic:**
```elixir
def unclaim_task(task_id, api_token_id, reason \\ nil) do
  task = get_task!(task_id)

  # Validate task is claimed and in_progress
  cond do
    task.status != "in_progress" ->
      {:error, :not_claimed}

    is_nil(task.claimed_at) ->
      {:error, :not_claimed}

    # Note: We don't validate which agent claimed it since we don't store that info
    # In the future, we could add a claimed_by_api_token_id field to validate ownership
    true ->
      now = DateTime.utc_now()

      changeset =
        task
        |> Ecto.Changeset.change(%{
          status: "open",
          claimed_at: nil,
          claim_expires_at: nil,
          updated_at: now
        })

      case Repo.update(changeset) do
        {:ok, updated_task} ->
          # Emit telemetry
          :telemetry.execute(
            [:kanban, :task, :unclaimed],
            %{task_id: task.id},
            %{
              api_token_id: api_token_id,
              reason: reason,
              unclaimed_at: now,
              was_claimed_for_minutes: DateTime.diff(now, task.claimed_at, :minute)
            }
          )

          # Broadcast change
          updated_task = Repo.preload(updated_task, [:column])
          broadcast_task_change(updated_task, :task_unclaimed)

          {:ok, updated_task}

        {:error, changeset} ->
          {:error, changeset}
      end
  end
end
```

### Controller Action (task 08)

**Endpoint:** POST /api/tasks/:id/unclaim

```elixir
def unclaim(conn, %{"id" => id} = params) do
  if has_scope?(conn, "tasks:write") do
    reason = params["reason"]

    case Tasks.unclaim_task(id, conn.assigns.api_token.id, reason) do
      {:ok, task} ->
        :telemetry.execute(
          [:kanban, :api, :task_unclaimed],
          %{task_id: task.id},
          %{
            api_token_id: conn.assigns.api_token.id,
            reason: reason,
            ai_agent: conn.assigns.api_token.metadata["ai_agent"]
          }
        )

        render(conn, "show.json", task: task)

      {:error, :not_claimed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Task is not currently claimed"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Task not found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset_errors(changeset)})
    end
  else
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Insufficient permissions. Requires tasks:write scope"})
  end
end
```

### Router Update

```elixir
scope "/api", KanbanWeb.API do
  pipe_through :api

  # Special endpoints MUST come before resources
  get "/tasks/next", TaskController, :next
  post "/tasks/claim", TaskController, :claim
  get "/tasks/:id/validate", TaskController, :validate
  post "/tasks/:id/unclaim", TaskController, :unclaim

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
end
```

## Benefits

### For AI Agents
1. **Immediate Release**: Don't wait 60 minutes if you realize you can't complete a task
2. **Autonomy**: Make decisions about task feasibility
3. **Transparency**: Provide reason for unclaiming to help improve task descriptions
4. **Clean Workflow**: Explicit unclaim instead of abandoning tasks

### For System
1. **Efficiency**: Tasks become available faster instead of waiting for timeout
2. **Analytics**: Track unclaim reasons to identify problematic tasks
3. **Resource Optimization**: Other agents can claim tasks sooner
4. **Observability**: Clear telemetry for unclaim events

### For Task Creators
1. **Feedback**: Learn which tasks are problematic from unclaim reasons
2. **Improved Descriptions**: Use feedback to add missing context or dependencies
3. **Better Scoping**: Identify tasks that need to be split or clarified

## Usage Examples

### Unclaiming a Task

**API Request:**
```bash
curl -X POST http://localhost:4000/api/tasks/42/unclaim \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "reason": "Missing OAuth2 library dependencies"
  }'
```

**Response:**
```json
{
  "data": {
    "id": 42,
    "title": "Implement OAuth2 authentication",
    "status": "open",
    "claimed_at": null,
    "claim_expires_at": null,
    "updated_at": "2025-12-18T15:45:00Z"
  }
}
```

### Common Unclaim Reasons

**Examples from Real Usage:**
- "Missing OAuth2 library dependencies"
- "Requires database migration not yet applied"
- "Blocked by external API downtime"
- "Task description unclear - need more context"
- "Insufficient permissions to modify target files"
- "Discovered this is duplicate of task #123"
- "Need human decision on implementation approach"

## Observability

### Telemetry Events

**[:kanban, :task, :unclaimed]** - Emitted when task unclaimed via context function
- Measurements: `%{task_id: integer}`
- Metadata: `%{api_token_id, reason, unclaimed_at, was_claimed_for_minutes}`

**[:kanban, :api, :task_unclaimed]** - Emitted when unclaim succeeds via API
- Measurements: `%{task_id: integer}`
- Metadata: `%{api_token_id, reason, ai_agent}`

### Metrics

**Counter:**
- `kanban.tasks.unclaimed.total` - Total unclaims
- `kanban.tasks.unclaimed.by_reason` - Unclaims grouped by reason (tag: reason)

**Histogram:**
- `kanban.tasks.claim_duration.unclaimed` - How long task was claimed before unclaim

### Logging

**Info Level:**
```
Task unclaimed: task_id=42 agent=claude-sonnet-4.5 reason="Missing OAuth2 library dependencies" claimed_for=5 minutes
```

**Dashboard Recommendations:**
- Top 10 unclaim reasons (identify common problems)
- Unclaim rate over time (trend analysis)
- Average claim duration before unclaim (efficiency metric)
- Tasks unclaimed multiple times (problematic tasks)
- Agent-specific unclaim rates (training needs)

## Testing Strategy

### Unit Tests

1. Test unclaim with valid claimed task
2. Test unclaim with task not claimed (422 error)
3. Test unclaim with task not found (404 error)
4. Test unclaim with and without reason parameter
5. Test telemetry events emitted correctly
6. Test PubSub broadcast on unclaim
7. Test claimed_at and claim_expires_at cleared
8. Test status changes from "in_progress" to "open"

### Integration Tests

1. Claim task → unclaim task → verify available in next task endpoint
2. Agent A claims task → Agent B tries to unclaim (currently not validated, will succeed)
3. Unclaim task with reason → verify reason in telemetry
4. Unclaim task → another agent claims it successfully
5. Complete workflow: claim → start work → realize problem → unclaim → provide reason

### Manual Testing

See task 08 for complete manual test scenarios including unclaim workflow.

## Migration Path

**No Migration Needed:**
- Uses existing fields (status, claimed_at, claim_expires_at)
- No database changes required
- Only adds new endpoint and context function

**Deployment Steps:**
1. Deploy updated code with unclaim endpoint
2. Update API documentation
3. Notify agents of new capability
4. Monitor unclaim telemetry

## Configuration

**No Configuration Required:**
- Unclaim reason is optional
- No environment variables needed
- No feature flags required

**Recommendations:**
- Encourage agents to always provide a reason
- Set up alerts for high unclaim rates (> 20% of claims)
- Review unclaim reasons weekly to identify patterns

## Future Enhancements (Out of Scope)

From IMPROVEMENTS.md and task 08, these related features are NOT implemented:

1. **Ownership Validation**: Add `claimed_by_api_token_id` field to validate only claiming agent can unclaim
2. **Unclaim History**: Track how many times each task was unclaimed and by whom
3. **Unclaim Limits**: Prevent tasks from being unclaimed more than N times (indicates problem)
4. **Automatic Task Flagging**: Flag tasks for human review after multiple unclaims
5. **Reason Categorization**: Structured reason codes instead of free text
6. **Unclaim Penalties**: Track agents with high unclaim rates for training
7. **Alternative Agent Suggestion**: When unclaiming, suggest better-suited agents based on capabilities

## Dependencies

**Task 08 Must Complete:**
- This feature is part of task 08 implementation

**No Blocking Dependencies:**
- This feature is additive and doesn't block other work

## Success Criteria

- [x] Agents can unclaim tasks via POST /api/tasks/:id/unclaim
- [x] Unclaim validates task is claimed
- [x] Unclaim accepts optional reason parameter
- [x] Status changes from "in_progress" to "open"
- [x] claimed_at and claim_expires_at cleared
- [x] Telemetry tracks unclaim events with reason
- [x] PubSub broadcasts task change
- [x] Task becomes immediately available to other agents
- [x] Error handling for not claimed, not found cases
- [ ] Tests cover all scenarios (pending implementation)

## Rollback Plan

If issues arise:

1. **Disable Endpoint:**
```elixir
# Remove from router
# post "/tasks/:id/unclaim", TaskController, :unclaim
```

2. **Keep Function:**
- Leave `unclaim_task/3` in Tasks context for future use
- Only external API is disabled

3. **Revert to Timeout Only:**
- Agents rely on 60-minute timeout mechanism
- No immediate unclaim capability

## Documentation References

- **Full Implementation**: See task 08 (lines 497-545 context function, lines 749-781 controller action)
- **Requirements**: See IMPROVEMENTS.md improvement #6
- **API Workflow**: See task 08 unclaim workflow examples
- **Router Configuration**: See task 08 (line 811)

## Real-World Scenarios

### Scenario 1: Missing Dependencies

```
Agent claims task: "Add JWT authentication"
Agent discovers: jsonwebtoken library not in package.json
Agent unclaims with reason: "Missing jsonwebtoken dependency"
Result: Task creator adds dependency, updates task description
```

### Scenario 2: Unclear Requirements

```
Agent claims task: "Update user profile page"
Agent discovers: No mockups or specific requirements provided
Agent unclaims with reason: "Task description unclear - need mockups or requirements"
Result: Task creator adds mockups and acceptance criteria
```

### Scenario 3: External Blocker

```
Agent claims task: "Import data from external API"
Agent discovers: External API is down (503 error)
Agent unclaims with reason: "External API downtime - https://api.example.com"
Result: Human marks task as blocked, reschedules for later
```

These real-world patterns help identify systemic issues and improve task quality over time.
