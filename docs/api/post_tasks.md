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

#### Basic Fields

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.title` | string | Yes | Clear, specific task title |
| `task.description` | string | **Strongly Recommended** | Detailed description with WHY, WHAT, and WHERE |
| `task.type` | string | **Strongly Recommended** | Type: `work` (new features) or `defect` (bug fixes) |
| `task.priority` | string | No | Priority: `low`, `medium`, `high`, `critical` (default: `medium`) |
| `task.complexity` | string | **Strongly Recommended** | Complexity: `trivial`, `low`, `medium`, `high`, `very_high` (default: `medium`) |
| `task.estimated_hours` | number | **Strongly Recommended** | Realistic time estimate in hours |
| `task.needs_review` | boolean | No | Whether task requires human review (default: `true`) |

#### Task Scheduling & Dependencies

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.key_files` | array | **CRITICAL** | Files that will be modified - prevents conflicts (see format below) |
| `task.dependencies` | array | **Strongly Recommended** | Array of task identifiers that must complete first (e.g., `["W1", "W2"]`) |
| `task.parent_goal` | string | No | Identifier of parent goal (e.g., `"G1"`) if this task belongs to a goal |

#### Implementation Guidance

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.acceptance_criteria` | array | **Strongly Recommended** | Specific, testable conditions for "done" |
| `task.test_scenarios` | array | **Strongly Recommended** | Exact tests to write |
| `task.verification_steps` | array | **Strongly Recommended** | Commands to run to verify success |
| `task.reference_files` | array | No | Existing code files to learn patterns from |
| `task.patterns_to_follow` | array | No | Specific coding patterns to replicate |
| `task.constraints` | array | No | What NOT to do or change |

#### Technical Details

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.technical_notes` | string | No | Database changes, integrations, gotchas |
| `task.observability` | string | No | Logging, metrics, telemetry requirements |
| `task.error_handling` | string | No | How to handle failures |
| `task.context` | string | No | Additional background information |
| `task.security_considerations` | string | No | Security concerns or requirements |
| `task.testing_strategy` | string | No | Overall testing approach |
| `task.integration_points` | string | No | Systems or APIs this touches |
| `task.pitfalls` | string | No | Common mistakes to avoid |
| `task.out_of_scope` | string | No | What NOT to include in this task |

#### Agent & System Fields

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.required_capabilities` | array | No | Required agent capabilities (e.g., `["code_generation", "testing"]`) |
| `task.column_id` | integer | No | Column ID where task should be created (default: Ready) |
| `task.tasks` | array | No | Array of child task objects (for goals only) |

#### Key Files Format

The `key_files` array should contain objects with the following structure:

```json
"key_files": [
  {
    "file_path": "lib/path/to/file.ex",  // Required: relative path from project root
    "note": "Why this file is modified",  // Optional: context
    "position": 0                          // Required: order of modification (0-indexed)
  }
]
```

**Why key_files is CRITICAL:**

- Prevents merge conflicts - only one task can modify a file at a time
- Tasks with overlapping key_files cannot be claimed simultaneously
- If Task A is working on `lib/auth.ex`, Task B listing the same file will be blocked until Task A completes

### Request Body Examples

#### Create a detailed task (recommended approach)

```json
{
  "task": {
    "title": "Fix login bug with special characters in password",
    "type": "defect",
    "description": "WHY: Users cannot log in when their password contains special characters like & or %. WHAT: Fix password encoding in login form. WHERE: Authentication controller and login form.",
    "priority": "high",
    "complexity": "low",
    "estimated_hours": 1.5,
    "needs_review": true,
    "key_files": [
      {
        "file_path": "lib/kanban_web/controllers/auth_controller.ex",
        "note": "Fix password encoding before validation",
        "position": 0
      },
      {
        "file_path": "test/kanban_web/controllers/auth_controller_test.exs",
        "note": "Add test for special characters",
        "position": 1
      }
    ],
    "acceptance_criteria": [
      "Users can log in with passwords containing &, %, #, and @ characters",
      "Password validation works correctly with special chars",
      "No regression in normal password login"
    ],
    "test_scenarios": [
      "Login with password containing &",
      "Login with password containing %",
      "Login with password containing multiple special chars",
      "Verify failed login still returns proper error"
    ],
    "verification_steps": [
      "mix test test/kanban_web/controllers/auth_controller_test.exs",
      "Manual test: create user with password 'Test&Pass%123' and login"
    ],
    "technical_notes": "Issue is likely URL encoding - passwords need to be properly encoded before sending to server",
    "required_capabilities": ["code_generation", "testing"]
  }
}
```

#### Create a minimal task (not recommended - lacks context)

```json
{
  "task": {
    "title": "Fix login bug",
    "description": "Users can't log in with special characters in password",
    "priority": "high",
    "complexity": "low"
  }
}
```

**Note:** While the minimal example above is valid, it lacks critical information that would help an agent (or developer) implement it efficiently. Always prefer the detailed approach.

#### Create a goal with detailed child tasks

```json
{
  "task": {
    "title": "Implement user authentication system",
    "description": "WHY: Application needs secure user authentication. WHAT: Complete authentication system with JWT tokens, password hashing, and session management. WHERE: New auth module and controllers.",
    "type": "goal",
    "priority": "critical",
    "complexity": "very_high",
    "estimated_hours": 12,
    "tasks": [
      {
        "title": "Create database schema for users",
        "type": "work",
        "description": "WHY: Need secure storage for user credentials. WHAT: Add users table with email, password_hash, and metadata fields. WHERE: New migration and schema.",
        "priority": "critical",
        "complexity": "medium",
        "estimated_hours": 2,
        "key_files": [
          {
            "file_path": "priv/repo/migrations/*_create_users.exs",
            "note": "Create users table migration",
            "position": 0
          },
          {
            "file_path": "lib/kanban/accounts/user.ex",
            "note": "User schema with validations",
            "position": 1
          }
        ],
        "acceptance_criteria": [
          "Migration creates users table with email, password_hash, inserted_at, updated_at",
          "Email has unique constraint",
          "Schema validates email format and password length"
        ],
        "test_scenarios": [
          "Valid user changeset",
          "Invalid email format rejected",
          "Duplicate email rejected",
          "Password less than 8 chars rejected"
        ],
        "verification_steps": [
          "mix ecto.migrate",
          "mix test test/kanban/accounts/user_test.exs"
        ],
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Implement JWT token generation and validation",
        "type": "work",
        "description": "WHY: Need secure token-based authentication. WHAT: Add JWT library, create token generation and validation functions. WHERE: Auth context module.",
        "priority": "critical",
        "complexity": "medium",
        "estimated_hours": 3,
        "dependencies": ["W1"],
        "key_files": [
          {
            "file_path": "lib/kanban/accounts/auth.ex",
            "note": "Token generation and validation logic",
            "position": 0
          },
          {
            "file_path": "mix.exs",
            "note": "Add joken dependency",
            "position": 1
          }
        ],
        "acceptance_criteria": [
          "generate_token/1 creates valid JWT with user_id claim",
          "verify_token/1 validates token signature and expiry",
          "Tokens expire after 24 hours",
          "Invalid tokens return error tuple"
        ],
        "test_scenarios": [
          "Generate token for valid user",
          "Verify valid token returns user_id",
          "Expired token returns error",
          "Invalid signature returns error"
        ],
        "verification_steps": [
          "mix test test/kanban/accounts/auth_test.exs"
        ],
        "technical_notes": "Use Joken library with HS256 algorithm. Store secret in environment variable.",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Write comprehensive authentication tests",
        "type": "work",
        "description": "WHY: Ensure auth system is secure and reliable. WHAT: Test suite covering all auth flows and edge cases. WHERE: Test files for auth modules.",
        "priority": "high",
        "complexity": "medium",
        "estimated_hours": 2.5,
        "dependencies": ["W2"],
        "key_files": [
          {
            "file_path": "test/kanban/accounts/auth_test.exs",
            "note": "Auth context tests",
            "position": 0
          },
          {
            "file_path": "test/kanban/accounts/user_test.exs",
            "note": "User schema tests",
            "position": 1
          }
        ],
        "acceptance_criteria": [
          "100% code coverage for auth module",
          "All happy path scenarios tested",
          "All error cases tested",
          "Tests run in < 1 second"
        ],
        "test_scenarios": [
          "User registration with valid data",
          "User registration with invalid data",
          "Login with correct credentials",
          "Login with incorrect credentials",
          "Token validation success and failure cases"
        ],
        "verification_steps": [
          "mix test test/kanban/accounts/",
          "mix test --cover --export-coverage default",
          "mix test.coverage"
        ],
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
