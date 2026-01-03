# POST /api/tasks/batch

Create multiple goals with nested child tasks in a single API call. This endpoint allows agents to efficiently upload an entire project structure with multiple goals and their associated tasks.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** POST
**Endpoint:** `/api/tasks/batch`
**Content-Type:** application/json

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `goals` | array | Yes | Array of goal objects, each with the same structure as [POST /api/tasks](post_tasks.md) |

Each goal object in the `goals` array should follow the same format as a single goal creation in the [POST /api/tasks](post_tasks.md) endpoint, including:

- All basic fields (title, description, type, priority, complexity)
- Planning & context fields (why, what, where_context)
- Implementation guidance (acceptance_criteria, verification_steps)
- Child tasks array (`tasks`)
- All other optional fields

See the [POST /api/tasks documentation](post_tasks.md) for complete field descriptions.

### Request Body Example

#### Create multiple goals with child tasks

```json
{
  "goals": [
    {
      "title": "User Authentication System",
      "description": "Implement complete user authentication with JWT tokens",
      "type": "goal",
      "priority": "high",
      "complexity": "large",
      "why": "Users need secure authentication to access the platform",
      "what": "JWT-based authentication with login, logout, and token refresh",
      "where_context": "lib/kanban_web/controllers/auth/, lib/kanban/accounts/",
      "tasks": [
        {
          "title": "Create user database schema",
          "description": "Add users table with email, password_hash, and timestamps",
          "type": "work",
          "priority": "high",
          "complexity": "small"
        },
        {
          "title": "Implement JWT token generation",
          "description": "Add functions to generate and validate JWT tokens",
          "type": "work",
          "priority": "high",
          "complexity": "medium",
          "dependencies": [0]
        },
        {
          "title": "Create login endpoint",
          "description": "POST /api/auth/login endpoint with email/password",
          "type": "work",
          "priority": "high",
          "complexity": "medium",
          "dependencies": [0, 1]
        }
      ]
    },
    {
      "title": "User Profile Management",
      "description": "Allow users to view and edit their profiles",
      "type": "goal",
      "priority": "medium",
      "complexity": "medium",
      "why": "Users need to manage their personal information",
      "what": "Profile viewing and editing with avatar upload",
      "where_context": "lib/kanban_web/live/profile_live/",
      "tasks": [
        {
          "title": "Create profile schema",
          "description": "Add profile fields to users table",
          "type": "work",
          "priority": "medium",
          "complexity": "small"
        },
        {
          "title": "Build profile view page",
          "description": "LiveView page to display user profile",
          "type": "work",
          "priority": "medium",
          "complexity": "medium",
          "dependencies": [0]
        },
        {
          "title": "Add profile edit form",
          "description": "Form to edit profile with validation",
          "type": "work",
          "priority": "medium",
          "complexity": "medium",
          "dependencies": [0, 1]
        }
      ]
    }
  ]
}
```

#### Minimal example

```json
{
  "goals": [
    {
      "title": "Setup Project Infrastructure",
      "type": "goal",
      "tasks": [
        {
          "title": "Setup CI/CD pipeline",
          "type": "work"
        },
        {
          "title": "Configure deployment",
          "type": "work",
          "dependencies": ["W1"]
        }
      ]
    },
    {
      "title": "Add Documentation",
      "type": "goal",
      "tasks": [
        {
          "title": "Write API documentation",
          "type": "work"
        },
        {
          "title": "Create user guide",
          "type": "work"
        }
      ]
    }
  ]
}
```

## Response

### Success (201 Created)

Returns all created goals with their child tasks:

```json
{
  "success": true,
  "total": 2,
  "goals": [
    {
      "goal": {
        "id": 100,
        "identifier": "G1",
        "title": "User Authentication System",
        "description": "Implement complete user authentication with JWT tokens",
        "status": "open",
        "priority": "high",
        "complexity": "large",
        "type": "goal",
        "created_by_id": 1,
        "created_by_agent": "ai_agent:claude-sonnet-4-5",
        "column_id": 5,
        "inserted_at": "2025-01-02T10:00:00Z",
        "updated_at": "2025-01-02T10:00:00Z"
      },
      "child_tasks": [
        {
          "id": 101,
          "identifier": "W1",
          "title": "Create user database schema",
          "status": "open",
          "priority": "high",
          "complexity": "small",
          "dependencies": []
        },
        {
          "id": 102,
          "identifier": "W2",
          "title": "Implement JWT token generation",
          "status": "blocked",
          "priority": "high",
          "complexity": "medium",
          "dependencies": ["W1"]
        },
        {
          "id": 103,
          "identifier": "W3",
          "title": "Create login endpoint",
          "status": "blocked",
          "priority": "high",
          "complexity": "medium",
          "dependencies": ["W1", "W2"]
        }
      ]
    },
    {
      "goal": {
        "id": 104,
        "identifier": "G2",
        "title": "User Profile Management",
        "description": "Allow users to view and edit their profiles",
        "status": "blocked",
        "priority": "medium",
        "complexity": "medium",
        "type": "goal",
        "created_by_id": 1,
        "created_by_agent": "ai_agent:claude-sonnet-4-5",
        "column_id": 5,
        "inserted_at": "2025-01-02T10:00:01Z",
        "updated_at": "2025-01-02T10:00:01Z"
      },
      "child_tasks": [
        {
          "id": 105,
          "identifier": "W4",
          "title": "Create profile schema",
          "status": "open",
          "priority": "medium",
          "complexity": "small",
          "dependencies": []
        },
        {
          "id": 106,
          "identifier": "W5",
          "title": "Build profile view page",
          "status": "blocked",
          "priority": "medium",
          "complexity": "medium",
          "dependencies": ["W4"]
        },
        {
          "id": 107,
          "identifier": "W6",
          "title": "Add profile edit form",
          "status": "blocked",
          "priority": "medium",
          "complexity": "medium",
          "dependencies": ["W4", "W5"]
        }
      ]
    }
  ]
}
```

### Forbidden (403)

Column doesn't belong to the board:

```json
{
  "error": "Column does not belong to this board"
}
```

### Unprocessable Entity (422)

Validation error in one of the goals:

```json
{
  "error": "Failed to create goal at index 1",
  "index": 1,
  "details": {
    "title": ["can't be blank"],
    "type": ["is invalid"]
  }
}
```

WIP limit reached:

```json
{
  "error": "WIP limit reached while creating goal at index 2",
  "index": 2
}
```

## Behavior

### Goal Creation Order

- Goals are created in the order they appear in the `goals` array
- If any goal fails to create, the operation stops and returns an error
- Previously created goals in the batch are **not** rolled back
- The error response includes the index of the failed goal

### Dependency Handling

**⚠️ CRITICAL: Use INDEX-BASED dependencies for tasks within a goal!**

**How it works:**

- Use **0-based array indices** to reference tasks within the same goal
- Index 0 = first task, index 1 = second task, etc.
- The system automatically converts indices to actual task identifiers (W47, W48, etc.) during creation
- Result stored in database has human-readable identifiers

**Example - Index-based dependencies:**

```json
{
  "title": "User Authentication",
  "tasks": [
    {"title": "Create schema", "type": "work"},                        // index 0
    {"title": "Add endpoints", "type": "work", "dependencies": [0]},   // depends on index 0
    {"title": "Add tests", "type": "work", "dependencies": [0, 1]}     // depends on indices 0 and 1
  ]
}
```

**After creation, stored as:**

```json
{
  "tasks": [
    {"identifier": "W47", "title": "Create schema", "dependencies": []},
    {"identifier": "W48", "title": "Add endpoints", "dependencies": ["W47"]},
    {"identifier": "W49", "title": "Add tests", "dependencies": ["W47", "W48"]}
  ]
}
```

**You can also mix indices with existing task identifiers:**

```json
{
  "title": "Feature Extension",
  "tasks": [
    {"title": "New component", "type": "work"},
    {"title": "Integration", "type": "work", "dependencies": [0, "W23"]}  // index 0 + existing task W23
  ]
}
```

**What DOES NOT work:**

- ❌ **Cross-goal dependencies in batch**: Cannot reference tasks from other goals in the same batch
  - Identifiers are assigned during creation, so you can't predict them
  - Solution: Create goals separately or add dependencies after creation

**For cross-goal dependencies:**

1. **Create goals separately** - Create first goal, get identifiers, then create second goal with correct dependencies
2. **Add after creation** - Create all goals, then use `PATCH /api/tasks/:id` to add cross-goal dependencies
3. **Don't use dependencies** - If goals are independent

**Tasks with incomplete dependencies are automatically marked as `blocked`**

### Default Values

- All goals are created in the default column (typically "Backlog" or "Ready")
- **Note:** Any `column_id` specified in goal objects is ignored - all goals use the default column
- `type` defaults to `goal` for goals and `work` for child tasks
- `priority` defaults to `medium`
- `complexity` defaults to `small`
- `needs_review` defaults to `true`
- Agent model from API token is automatically recorded as `created_by_agent`

### Telemetry

The endpoint emits two types of telemetry events:
1. `[:kanban, :api, :goal_created]` - For each goal created (with `batch: true`)
2. `[:kanban, :api, :batch_goals_created]` - Once for the entire batch (with `total_goals` count)

## Use Cases

- **Project initialization**: Create entire project structure in one call
- **Sprint planning**: Upload all goals and tasks for a sprint
- **Agent workflow**: Allow AI agents to plan and create complex task hierarchies
- **Bulk import**: Import tasks from external systems
- **Template instantiation**: Create task sets from predefined templates

## Example Usage

### Create multiple goals

```bash
curl -X POST \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "goals": [
      {
        "title": "User Authentication",
        "type": "goal",
        "priority": "high",
        "tasks": [
          {"title": "Create user schema", "type": "work"},
          {"title": "Add login endpoint", "type": "work", "dependencies": [0]}
        ]
      },
      {
        "title": "User Profile",
        "type": "goal",
        "priority": "medium",
        "tasks": [
          {"title": "Profile view", "type": "work"},
          {"title": "Profile edit", "type": "work"}
        ]
      }
    ]
  }' \
  https://www.stridelikeaboss.com/api/tasks/batch
```

## Error Handling

### Partial Success

If the 3rd goal in a batch of 5 fails:
- Goals 1 and 2 are successfully created
- Goal 3 fails with an error
- Goals 4 and 5 are **not** created
- The response indicates the failure at index 2 (0-indexed)

To continue after an error:
1. Note the failed index from the error response
2. Fix the validation errors in that goal
3. Create a new batch with only the remaining goals (from the failed index onward)

### Common Validation Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `title: ["can't be blank"]` | Missing title | Add title to goal or task |
| `type: ["is invalid"]` | Invalid type value | Use `work`, `defect`, or `goal` |
| `priority: ["is invalid"]` | Invalid priority | Use `low`, `medium`, `high`, or `critical` |
| `complexity: ["is invalid"]` | Invalid complexity | Use `small`, `medium`, or `large` |
| `dependencies: ["must be an array"]` | Wrong type | Use array of strings |
| WIP limit reached | Too many tasks in column | Wait for tasks to complete or increase WIP limit |

## Performance Considerations

- **Database transactions**: Each goal is created in its own transaction for isolation
- **Sequential processing**: Goals are created one at a time in order
- **Partial success**: If creation fails mid-batch, successfully created goals remain in the system
- **WIP limits**: The batch is checked against column WIP limits for each goal

For best performance:

- Keep batches reasonably sized (typically 5-20 goals)
- Monitor batch creation progress via telemetry events
- Handle partial failures by resuming from the failed index

## Notes

- All goals in the batch must belong to the board associated with your API token
- Goals are created in the default column (cannot specify different columns per goal)
- The batch operation is **not atomic** - partial success is possible
- Task identifiers (W1, W2, G1, etc.) are assigned sequentially during creation
- The `created_by_agent` field is automatically set from your API token
- Dependencies are validated after all goals are created
- Circular dependencies are prevented by the system

## See Also

- [POST /api/tasks](post_tasks.md) - Create a single task or goal
- [GET /api/tasks](get_tasks.md) - List all tasks
- [GET /api/tasks/:id/tree](get_tasks_id_tree.md) - Get goal with all child tasks
- [PATCH /api/tasks/:id](patch_tasks_id.md) - Update a task
