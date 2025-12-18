# Feature 3: AI Agent API

**Epic:** [EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
**Type:** Feature
**Identifier:** F3 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Large (9 hours estimated)

## Description

Build a JSON API that enables AI agents to interact with tasks programmatically. AI agents need to authenticate with bearer tokens, create/read/update/delete tasks with full rich field support, query for and atomically claim ready-to-work tasks, and access the complete hierarchical structure of epics/features/tasks.

## Goal

By the end of this feature, AI agents can authenticate via API tokens, perform full CRUD operations on tasks using the TASKS.md format, atomically claim the next available task to prevent race conditions, and retrieve the complete task hierarchy for context.

## Business Value

**Why This Matters:**
- Enables AI agents to participate in task workflow
- AI can create well-structured tasks for humans to review
- AI can pick up ready tasks and complete them autonomously
- API provides structured input/output format (JSON) for AI consumption
- Bearer tokens provide simple, secure authentication

**What Changes:**
- API token system for AI agent authentication
- RESTful JSON endpoints for task CRUD operations
- Atomic claiming endpoint to prevent race conditions between multiple agents
- Hierarchical tree endpoint to see full epic/feature/task structure
- Agent documentation endpoint to provide system information
- API accepts rich task fields in JSON format
- API responses include all TASKS.md fields

## Tasks

- [ ] **06** - [06-create-api-authentication.md](06-create-api-authentication.md) - **Large** (2.5 hours)
  - Create api_tokens table
  - Bearer token generation and validation
  - Scopes for permissions (tasks:read, tasks:write)
  - Token metadata (AI agent name, capabilities)

- [ ] **07** - [07-implement-task-crud-api.md](07-implement-task-crud-api.md) - **Large** (3 hours)
  - POST /api/tasks - Create task with rich fields
  - GET /api/tasks/:id - Get task with all fields
  - PATCH /api/tasks/:id - Update task fields
  - DELETE /api/tasks/:id - Delete task
  - GET /api/tasks - List tasks with filters
  - TextFieldParser converts between text storage and JSON

- [ ] **08** - [08-add-task-ready-endpoint.md](08-add-task-ready-endpoint.md) - **Medium** (1 hour)
  - GET /api/tasks/next - Peek at next available task
  - POST /api/tasks/claim - Atomically claim next task
  - Filter by Ready column, status=open, dependencies completed
  - Sort by priority (0=highest) then created_at
  - Prevent race conditions with atomic update

- [ ] **12** - [12-add-hierarchical-task-tree-endpoint.md](12-add-hierarchical-task-tree-endpoint.md) - **Medium** (1.5 hours)
  - GET /api/tasks/:id/tree - Return hierarchical structure
  - Epic returns all features and their tasks (3 levels)
  - Feature returns all tasks (2 levels)
  - Task returns just that task (1 level)
  - Include statistics (total, completed, blocked counts)

- [ ] **15** - [15-add-agent-info-endpoint.md](15-add-agent-info-endpoint.md) - **Small** (1 hour)
  - GET /api/agent/info - Return comprehensive agent documentation
  - System overview, workflow, hooks, review process
  - API endpoints list, task metadata fields
  - Best practices and common pitfalls
  - Practical examples with request/response samples

## Dependencies

**Requires:** Feature 1 (Database Schema Foundation), Task 03 (for TextFieldParser usage pattern)
**Blocks:** Feature 4 (Task Management needs API endpoints)

## Acceptance Criteria

- [ ] API tokens stored securely (hashed)
- [ ] Bearer token authentication works via Authorization header
- [ ] Scopes limit what tokens can do (read vs write)
- [ ] Token metadata tracks AI agent identity
- [ ] POST /api/tasks accepts all TASKS.md fields in JSON
- [ ] GET /api/tasks/:id returns complete task with parsed collections
- [ ] PATCH /api/tasks/:id updates any field
- [ ] DELETE /api/tasks/:id removes task
- [ ] GET /api/tasks lists tasks with pagination
- [ ] GET /api/tasks/next returns single unblocked task
- [ ] POST /api/tasks/claim atomically claims next task
- [ ] GET /api/tasks/:id/tree returns hierarchical structure
- [ ] API validates input fields (complexity, status, etc.)
- [ ] API returns appropriate HTTP status codes
- [ ] Error messages are clear and actionable
- [ ] All endpoints documented with examples

## Technical Approach

**Authentication:**
- api_tokens table with hashed tokens
- Middleware validates Bearer token on API routes
- Check scopes before allowing operations
- Token metadata includes AI agent name

**API Design:**
- RESTful routes following Rails conventions
- JSON request/response format
- TextFieldParser converts text ↔ JSON for collections
- Pagination using page/per_page params
- Error responses include field-level validation errors

**Endpoints:**
```
POST   /api/tasks              - Create task
GET    /api/tasks              - List tasks
GET    /api/tasks/next         - Peek at next available task
POST   /api/tasks/claim        - Atomically claim next task
GET    /api/tasks/:id          - Show task
GET    /api/tasks/:id/tree     - Show hierarchical tree
PATCH  /api/tasks/:id          - Update task
DELETE /api/tasks/:id          - Delete task
PATCH  /api/tasks/:id/complete - Mark complete
```

**Request/Response Format:**
```json
{
  "task": {
    "title": "Add user authentication",
    "complexity": "large",
    "estimated_files": "5+",
    "why": "Users need secure access",
    "key_files": [
      {"file_path": "lib/kanban/accounts.ex", "note": "User context"}
    ],
    "verification_steps": [
      {"step_type": "command", "step_text": "mix test", "expected_result": "All pass"}
    ]
  }
}
```

## Success Metrics

- [ ] Token generation takes < 100ms
- [ ] Authentication adds < 10ms per request
- [ ] API responses < 200ms for single task
- [ ] API responses < 500ms for list (50 tasks)
- [ ] 100% test coverage on API controllers
- [ ] Security audit passes (no token leaks)

## Verification Steps

```bash
# Generate API token
iex -S mix
alias Kanban.Accounts
{:ok, token, plain_token} = Accounts.create_api_token(user, %{
  name: "Claude Agent",
  scopes: ["tasks:read", "tasks:write"],
  metadata: %{ai_agent: "claude-sonnet-4.5"}
})

export TOKEN="kan_dev_..."

# Create task via API
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"task": {"title": "Test task", "complexity": "small"}}'

# Claim next task
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer $TOKEN"

# Get task tree
curl http://localhost:4000/api/tasks/1/tree \
  -H "Authorization: Bearer $TOKEN"

# Run tests
mix test test/kanban_web/controllers/api/
mix precommit
```

## Security Considerations

- [ ] Tokens hashed with bcrypt before storage
- [ ] Plain token shown only once at creation
- [ ] Token prefix "kan_dev_" for development, "kan_prod_" for production
- [ ] Rate limiting on API endpoints (100 req/min per token)
- [ ] Scope validation on every request
- [ ] HTTPS required in production
- [ ] No sensitive data in logs (redact tokens)

## Out of Scope

- OAuth/social login for tokens
- Token rotation/refresh
- Webhooks for task events
- Batch operations (create multiple tasks)
- GraphQL API
- API versioning (v1, v2)
- Advanced filtering (full-text search)
- Real-time updates via WebSockets (use LiveView for that)
