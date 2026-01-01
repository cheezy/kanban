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
| `task.complexity` | string | **Strongly Recommended** | Complexity: `small`, `medium`, `large` (default: `small`) |
| `task.needs_review` | boolean | No | Whether task requires human review (default: `true`) |

#### Task Scheduling & Dependencies

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.key_files` | array | **CRITICAL** | Files that will be modified - prevents conflicts (see format below) |
| `task.dependencies` | array | **Strongly Recommended** | Array of task identifiers that must complete first (e.g., `["W1", "W2"]`) |
| `task.parent_goal` | string | No | Identifier of parent goal (e.g., `"G1"`) if this task belongs to a goal |

#### Planning & Context

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.why` | string | **Strongly Recommended** | Why this task matters - business justification |
| `task.what` | string | **Strongly Recommended** | What needs to be done - concise summary |
| `task.where_context` | string | **Strongly Recommended** | Where in the codebase this work happens |
| `task.estimated_files` | string | **Strongly Recommended** | Estimated number of files to modify as a number or range (e.g., '2', '3-5', '5+') |

#### Implementation Guidance

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.acceptance_criteria` | string | **Strongly Recommended** | Specific, testable conditions for "done" (newline-separated) |
| `task.verification_steps` | array | **Strongly Recommended** | Array of step objects with `command` and optional `description` (see format below) |
| `task.patterns_to_follow` | string | No | Specific coding patterns to replicate (newline-separated) |
| `task.database_changes` | string | No | Database schema changes required (migrations, tables, columns) |
| `task.validation_rules` | string | No | Input validation requirements (constraints, formats, rules) |
| `task.technology_requirements` | array | No | Required technologies or libraries (array of strings) |
| `task.pitfalls` | array | No | Common mistakes to avoid (array of strings) |
| `task.out_of_scope` | array | No | What NOT to include in this task (array of strings) |

#### Observability & Error Handling

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.telemetry_event` | string | No | Telemetry events to emit (event names and metadata) |
| `task.metrics_to_track` | string | No | Metrics to instrument (counters, gauges, histograms) |
| `task.logging_requirements` | string | No | What to log for debugging (log levels, context data) |
| `task.error_user_message` | string | No | User-facing error messages to display |
| `task.error_on_failure` | string | No | How to handle failures (retry logic, fallbacks, cleanup) |

#### Quality & Security

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `task.security_considerations` | array | **Strongly Recommended** | Security concerns, vulnerabilities to avoid, or security requirements (array of strings - see format below) |
| `task.testing_strategy` | object | **Strongly Recommended** | Overall testing approach (JSON object - see format below) |
| `task.integration_points` | object | No | Systems or APIs this touches (JSON object) |

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

#### Verification Steps Format

The `verification_steps` array should contain objects with the following structure:

```json
"verification_steps": [
  {
    "step_type": "command",                    // Required: "command" or "manual"
    "step_text": "mix test test/auth_test.exs", // Required: command or instruction
    "expected_result": "All tests pass",       // Optional: what success looks like
    "position": 0                              // Required: execution order (0-indexed)
  },
  {
    "step_type": "manual",
    "step_text": "Navigate to /login and verify special characters work in password field",
    "expected_result": "Can login with password containing &, %, #",
    "position": 1
  }
]
```

#### Testing Strategy Format

The `testing_strategy` object describes the overall testing approach for the task. This is a flexible JSON object that can contain any relevant testing information. Common fields include:

```json
"testing_strategy": {
  "unit_tests": "Test each function in isolation with ExUnit",
  "integration_tests": "Test auth flow end-to-end in controller tests",
  "property_tests": "Use StreamData to verify password encoding with random special characters",
  "coverage_target": "100% for auth module",
  "test_data": "Create fixtures for valid/invalid passwords",
  "mocking": "Mock external email service for password reset tests",
  "edge_cases": [
    "Empty password",
    "Password with unicode characters",
    "Password exceeding max length"
  ],
  "performance_tests": "Login should complete in <100ms for 95th percentile"
}
```

**Common fields (all optional):**

- `unit_tests` (string) - Approach for unit testing individual functions
- `integration_tests` (string) - How to test component interactions
- `property_tests` (string) - Property-based testing strategy (e.g., StreamData)
- `coverage_target` (string) - Target code coverage percentage or scope
- `test_data` (string) - Test fixtures or data setup approach
- `mocking` (string) - What external dependencies to mock and how
- `edge_cases` (array) - Specific edge cases that must be tested
- `performance_tests` (string) - Performance criteria or benchmarks
- `manual_tests` (string) - Manual testing procedures beyond automated tests

**Why testing_strategy is valuable:**

- Provides clear testing expectations beyond verification steps
- Helps agents understand the testing philosophy for this task
- Specifies coverage targets and edge cases upfront
- Documents mocking/stubbing requirements
- Can be more comprehensive than `verification_steps` which focuses on commands

**When to use testing_strategy vs verification_steps:**

- `testing_strategy` - Overall testing approach, coverage goals, edge cases to consider
- `verification_steps` - Specific commands to run and manual steps to verify completion

Use both for comprehensive guidance: `testing_strategy` tells the agent *how to think about testing*, while `verification_steps` tells them *what commands to run*.

#### Security Considerations Format

The `security_considerations` array specifies security concerns, potential vulnerabilities, and security requirements for the task. This is an array of strings, each describing a specific security aspect to address.

```json
"security_considerations": [
  "Validate and sanitize all user input to prevent XSS attacks",
  "Use parameterized queries to prevent SQL injection",
  "Hash passwords with bcrypt (cost factor 12+)",
  "Implement rate limiting on login endpoint (max 5 attempts per minute)",
  "Ensure authentication tokens expire after 24 hours",
  "Never log sensitive data (passwords, tokens, credit cards)",
  "Use HTTPS only for all authentication endpoints",
  "Implement CSRF protection for state-changing operations"
]
```

**Common security considerations by category:**

**Input Validation & Sanitization:**
- "Validate and sanitize user input to prevent XSS"
- "Escape HTML in user-generated content"
- "Validate file uploads (type, size, content)"
- "Reject invalid email formats and special characters"

**Authentication & Authorization:**
- "Hash passwords with bcrypt (cost factor 12+)"
- "Implement secure password reset flow with time-limited tokens"
- "Verify user authorization before allowing access"
- "Use secure session management"
- "Implement multi-factor authentication"

**Data Protection:**
- "Never log passwords, tokens, or sensitive data"
- "Encrypt sensitive data at rest"
- "Use HTTPS/TLS for all data transmission"
- "Implement proper access controls on sensitive resources"

**Injection Prevention:**
- "Use parameterized queries to prevent SQL injection"
- "Validate and sanitize all database inputs"
- "Prevent command injection in system calls"
- "Escape user input in dynamic queries"

**Rate Limiting & DoS Prevention:**
- "Implement rate limiting (5 requests per minute per IP)"
- "Add CAPTCHA after failed login attempts"
- "Limit file upload sizes"
- "Implement request throttling"

**CSRF & Session Security:**
- "Implement CSRF token validation"
- "Set secure cookie flags (HttpOnly, Secure, SameSite)"
- "Invalidate sessions on logout"
- "Rotate session tokens after privilege changes"

**Why security_considerations is valuable:**

- **Prevents vulnerabilities** - Explicitly reminds agents of security risks
- **OWASP awareness** - Addresses common security issues (SQL injection, XSS, CSRF, etc.)
- **Compliance** - Ensures security best practices are followed
- **Code review** - Provides security checklist for reviewers
- **Reduces risk** - Makes security a first-class concern, not an afterthought

**When to include security_considerations:**

- **Always** for tasks involving:
  - User authentication or authorization
  - User input or file uploads
  - Database operations with user data
  - API endpoints accepting external data
  - Payment or financial transactions
  - Personal or sensitive data handling
  - Session or token management

### Request Body Examples

#### Create a detailed task (recommended approach)

```json
{
  "task": {
    "title": "Fix login bug with special characters in password",
    "type": "defect",
    "description": "Users cannot log in when their password contains special characters like & or %.",
    "why": "Users cannot authenticate when using strong passwords with special characters, blocking access to their accounts",
    "what": "Fix password encoding in login form to properly handle special characters",
    "where_context": "Authentication controller and login form validation",
    "priority": "high",
    "complexity": "small",
    "estimated_files": "2",
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
    "acceptance_criteria": "Users can log in with passwords containing &, %, #, and @ characters\nPassword validation works correctly with special chars\nNo regression in normal password login",
    "verification_steps": [
      {
        "step_type": "command",
        "step_text": "mix test test/kanban_web/controllers/auth_controller_test.exs",
        "expected_result": "All tests pass",
        "position": 0
      },
      {
        "step_type": "manual",
        "step_text": "Create user with password 'Test&Pass%123' and login",
        "expected_result": "Login succeeds with special characters in password",
        "position": 1
      }
    ],
    "database_changes": null,
    "validation_rules": "Password must be URL-encoded before transmission to server",
    "testing_strategy": {
      "unit_tests": "Test password encoding function with various special characters",
      "integration_tests": "Test full login flow with passwords containing &, %, #, @",
      "edge_cases": [
        "Password with only special characters",
        "Password with unicode characters",
        "Empty password",
        "Very long password with special chars"
      ],
      "coverage_target": "100% for modified auth functions"
    },
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
    "description": "Complete authentication system with JWT tokens, password hashing, and session management.",
    "why": "Application needs secure user authentication to protect user data and restrict access",
    "what": "Complete authentication system with JWT tokens, password hashing, and session management",
    "where_context": "New auth module and controllers",
    "type": "goal",
    "priority": "critical",
    "complexity": "large",
    "estimated_files": "10+",
    "tasks": [
      {
        "title": "Create database schema for users",
        "type": "work",
        "description": "Add users table with email, password_hash, and metadata fields.",
        "why": "Need secure storage for user credentials and authentication data",
        "what": "Add users table with email, password_hash, and metadata fields",
        "where_context": "New migration and User schema module",
        "priority": "critical",
        "complexity": "medium",
        "estimated_files": "2",
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
        "acceptance_criteria": "Migration creates users table with email, password_hash, inserted_at, updated_at\nEmail has unique constraint\nSchema validates email format and password length",
        "verification_steps": [
          {
            "step_type": "command",
            "step_text": "mix ecto.migrate",
            "expected_result": "Migration runs successfully",
            "position": 0
          },
          {
            "step_type": "command",
            "step_text": "mix test test/kanban/accounts/user_test.exs",
            "expected_result": "All tests pass",
            "position": 1
          }
        ],
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Implement JWT token generation and validation",
        "type": "work",
        "description": "Add JWT library, create token generation and validation functions.",
        "why": "Need secure token-based authentication for stateless API access",
        "what": "Add JWT library, create token generation and validation functions",
        "where_context": "Auth context module",
        "priority": "critical",
        "complexity": "medium",
        "estimated_files": "2-3",
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
        "acceptance_criteria": "generate_token/1 creates valid JWT with user_id claim\nverify_token/1 validates token signature and expiry\nTokens expire after 24 hours\nInvalid tokens return error tuple",
        "verification_steps": [
          {
            "step_type": "command",
            "step_text": "mix test test/kanban/accounts/auth_test.exs",
            "expected_result": "All tests pass",
            "position": 0
          }
        ],
        "technology_requirements": ["Joken library"],
        "database_changes": null,
        "validation_rules": "Tokens must use HS256 algorithm and expire after 24 hours",
        "security_considerations": [
          "Store JWT secret in environment variable, never in code",
          "Use HS256 algorithm for token signing",
          "Ensure tokens expire after 24 hours"
        ],
        "testing_strategy": {
          "unit_tests": "Test token generation and validation functions independently",
          "integration_tests": "Not needed - covered by auth controller tests",
          "edge_cases": [
            "Expired token",
            "Invalid signature",
            "Missing user_id claim",
            "Malformed token string"
          ],
          "coverage_target": "100% for token module"
        },
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Write comprehensive authentication tests",
        "type": "work",
        "description": "Test suite covering all auth flows and edge cases.",
        "why": "Ensure auth system is secure and reliable before deploying to production",
        "what": "Test suite covering all auth flows and edge cases",
        "where_context": "Test files for auth modules",
        "priority": "high",
        "complexity": "medium",
        "estimated_files": "3-4",
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
        "acceptance_criteria": "100% code coverage for auth module\nAll happy path scenarios tested\nAll error cases tested\nTests run in < 1 second",
        "verification_steps": [
          {
            "step_type": "command",
            "step_text": "mix test test/kanban/accounts/",
            "expected_result": "All tests pass",
            "position": 0
          },
          {
            "step_type": "command",
            "step_text": "mix test --cover --export-coverage default",
            "expected_result": "Coverage report generated",
            "position": 1
          },
          {
            "step_type": "command",
            "step_text": "mix test.coverage",
            "expected_result": "100% coverage for auth module",
            "position": 2
          }
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

- `small` - Less than 1 hour (default)
- `medium` - 1-2 hours
- `large` - More than 2 hours

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
