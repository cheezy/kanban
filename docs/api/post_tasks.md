# POST /api/tasks

Create a new task or goal with nested child tasks.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** POST
**Endpoint:** `/api/tasks`
**Content-Type:** application/json

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.title` | string | Yes | Task title |
| `task.description` | string | No | Detailed task description |
| `task.priority` | string | No | Priority: `low`, `medium`, `high`, `critical` (default: `medium`) |
| `task.complexity` | string | No | Complexity: `trivial`, `low`, `medium`, `high`, `very_high` (default: `medium`) |
| `task.type` | string | No | Type: `task` or `goal` (default: `task`) |
| `task.needs_review` | boolean | No | Whether task requires human review (default: `true`) |
| `task.column_id` | integer | No | Column ID where task should be created (default: Backlog or Ready) |
| `task.parent_goal_id` | integer | No | ID of parent goal if this is a child task |
| `task.required_capabilities` | array | No | Array of required capabilities (e.g., `["code_generation", "testing"]`) |
| `task.tasks` | array | No | Array of child task objects (creates a goal with nested tasks) |

### Request Body Examples

#### Create a simple task

```json
{
  "task": {
    "title": "Fix login bug",
    "description": "Users can't log in with special characters in password",
    "priority": "high",
    "complexity": "low",
    "needs_review": true,
    "required_capabilities": ["code_generation"]
  }
}
```

#### Create a goal with child tasks

```json
{
  "task": {
    "title": "Implement user authentication system",
    "description": "Complete authentication system with JWT tokens",
    "type": "goal",
    "priority": "critical",
    "complexity": "very_high",
    "tasks": [
      {
        "title": "Create database schema for users",
        "description": "Design and implement user table with authentication fields",
        "priority": "critical",
        "complexity": "medium",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Implement JWT token generation",
        "description": "Create functions to generate and validate JWT tokens",
        "priority": "critical",
        "complexity": "medium",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Write authentication tests",
        "description": "Comprehensive test suite for auth system",
        "priority": "high",
        "complexity": "medium",
        "required_capabilities": ["testing"]
      }
    ]
  }
}
```

## Response

### Success - Simple Task (201 Created)

```json
{
  "data": {
    "id": 124,
    "identifier": "W22",
    "title": "Fix login bug",
    "description": "Users can't log in with special characters in password",
    "status": "open",
    "priority": "high",
    "complexity": "low",
    "needs_review": true,
    "type": "task",
    "column_id": 5,
    "column_name": "Ready",
    "board_id": 1,
    "created_by_id": 5,
    "created_by_agent": "ai_agent:claude-sonnet-4-5",
    "required_capabilities": ["code_generation"],
    "inserted_at": "2025-12-28T13:00:00Z",
    "updated_at": "2025-12-28T13:00:00Z"
  }
}
```

### Success - Goal with Child Tasks (201 Created)

```json
{
  "goal": {
    "id": 125,
    "identifier": "G10",
    "title": "Implement user authentication system",
    "description": "Complete authentication system with JWT tokens",
    "status": "open",
    "priority": "critical",
    "complexity": "very_high",
    "type": "goal",
    "column_id": 5,
    "created_by_agent": "ai_agent:claude-sonnet-4-5",
    "inserted_at": "2025-12-28T13:00:00Z"
  },
  "child_tasks": [
    {
      "id": 126,
      "identifier": "W23",
      "title": "Create database schema for users",
      "status": "open",
      "priority": "critical",
      "complexity": "medium",
      "dependencies": []
    },
    {
      "id": 127,
      "identifier": "W24",
      "title": "Implement JWT token generation",
      "status": "open",
      "priority": "critical",
      "complexity": "medium",
      "dependencies": [126]
    },
    {
      "id": 128,
      "identifier": "W25",
      "title": "Write authentication tests",
      "status": "open",
      "priority": "high",
      "complexity": "medium",
      "dependencies": [127]
    }
  ]
}
```

### Unprocessable Entity (422)

Validation errors:

```json
{
  "errors": {
    "title": ["can't be blank"],
    "priority": ["is invalid"]
  }
}
```

WIP limit reached:

```json
{
  "error": "WIP limit reached for this column"
}
```

## Notes

### Task Creation
- Tasks are created in the Backlog or Ready column by default
- The `created_by_id` is automatically set to your user ID
- If your API token has an `agent_model`, it's recorded as `created_by_agent`
- Task identifiers are automatically generated (e.g., W22, G10)

### Goal Creation with Nested Tasks
- Set `type: "goal"` to create a goal
- Include a `tasks` array to create child tasks atomically
- All tasks are created in a single database transaction (all-or-nothing)
- Child tasks are automatically linked to the parent goal via `parent_goal_id`
- Child tasks can have dependencies on each other (by position in array)
- Goals have identifiers starting with "G", tasks with "W"

### Capabilities
- Required capabilities filter which agents can claim the task
- Available capabilities: `code_generation`, `testing`, `documentation`, `review`, `deployment`
- If not specified, any agent can claim the task
- Agents specify their capabilities in their API token configuration

### Priority Values
- `low` - Nice to have
- `medium` - Normal priority (default)
- `high` - Important
- `critical` - Urgent, must be done ASAP

### Complexity Values
- `trivial` - Less than 15 minutes
- `low` - 15-30 minutes
- `medium` - 30-60 minutes (default)
- `high` - 1-2 hours
- `very_high` - More than 2 hours

## Example Usage

### Create a simple task

```bash
curl -X POST \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Fix login bug",
      "description": "Users cannot log in with special characters",
      "priority": "high",
      "complexity": "low"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks
```

### Create a goal with child tasks

```bash
curl -X POST \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Implement authentication",
      "type": "goal",
      "priority": "critical",
      "tasks": [
        {"title": "Create user schema", "complexity": "medium"},
        {"title": "Implement JWT tokens", "complexity": "medium"},
        {"title": "Write tests", "complexity": "medium"}
      ]
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks
```

## See Also

- [GET /api/tasks](get_tasks.md) - List all tasks
- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working
