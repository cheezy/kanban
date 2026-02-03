---
name: stride
description: Integration instructions for Stride kanban platform with AI-human collaboration workflows, client-side hooks, and task management API
license: MIT
compatibility: opencode
metadata:
  platform: stride
  api_base: https://www.stridelikeaboss.com
---

## What I do

I provide comprehensive integration instructions for working with Stride, a kanban-based task management platform designed for AI-human collaboration. I cover:

- Client-side hook execution (before_doing, after_doing, before_review, after_review)
- Task claiming, completion, and creation workflows
- API endpoint usage and authentication
- Common mistakes to avoid
- Required task field structures
- Configuration file management

## When to use me

Use this skill when you need to:
- Claim and complete tasks from Stride boards
- Create new tasks or goals with proper structure
- Execute workflow hooks at the right time
- Understand Stride's task schema and API
- Set up Stride configuration files (.stride.md, .stride_auth.md)

## Hook Execution (MANDATORY)

Stride enforces workflow discipline through four client-side hooks that execute on your machine:

- **before_doing** (60s, blocking) - Execute before starting work (pull code, setup)
- **after_doing** (120s, blocking) - Execute after work, BEFORE calling complete endpoint (tests, lint)
- **before_review** (60s, non-blocking) - Execute when entering review (create PR, docs)
- **after_review** (60s, non-blocking) - Execute after approval (merge, deploy)

**CRITICAL:** Always execute the `after_doing` hook BEFORE calling the task completion endpoint. Hook validation failures must prevent task completion.

## Top 5 Critical Mistakes to Avoid

### 1. Specifying Identifiers When Creating Tasks

**DON'T:**
```json
{"identifier": "W47", "title": "Add dark mode", "type": "work"}
```

**DO:**
```json
{"title": "Add dark mode", "type": "work"}
```

**WHY:** Identifiers are auto-generated (G1, W47, D12). Specifying them causes API rejection.

### 2. Using String Arrays for verification_steps

**DON'T:**
```json
{"verification_steps": ["Run mix test", "Check coverage"]}
```

**DO:**
```json
{
  "verification_steps": [
    {
      "step_type": "command",
      "step_text": "mix test path/to/test.exs",
      "expected_result": "All tests pass",
      "position": 0
    }
  ]
}
```

**WHY:** `verification_steps` must be array of objects with `step_type`, `step_text`, `expected_result`, and `position`.

### 3. Using Non-Array Values for testing_strategy Fields

**DON'T:**
```json
{
  "testing_strategy": {
    "unit_tests": "Test the auth flow",
    "integration_tests": "Test end-to-end"
  }
}
```

**DO:**
```json
{
  "testing_strategy": {
    "unit_tests": ["Test JWT generation", "Test token validation"],
    "integration_tests": ["Full auth flow with database"],
    "manual_tests": ["Verify login form works"],
    "edge_cases": ["Expired tokens", "Invalid credentials"],
    "coverage_target": "100% for auth module"
  }
}
```

**WHY:** `unit_tests`, `integration_tests`, and `manual_tests` must be arrays of strings.

### 4. Using Wrong Type Values

**DON'T:**
```json
{"type": "task"}
```

**DO:**
```json
{"type": "work"}
```

**WHY:** `type` must be exactly `"work"`, `"defect"`, or `"goal"` as strings.

### 5. Calling Complete Endpoint Before Executing after_doing Hook

**DON'T:**
1. Finish work
2. Call `PATCH /api/tasks/:id/complete`
3. Execute `after_doing` hook

**DO:**
1. Finish work
2. Execute `after_doing` hook (tests, lint, build)
3. Only if hook succeeds, call `PATCH /api/tasks/:id/complete`

**WHY:** Hook validation failures must prevent task completion. Calling complete first bypasses quality gates.

## Essential Task Fields

**Required:**
- `type` - Exactly `"work"`, `"defect"`, or `"goal"`
- `title` - Clear, specific description

**Critical:**
- `key_files` - Prevents merge conflicts by marking which files are modified
- `dependencies` - Controls execution order using task identifiers or array indices
- `verification_steps` - Array of objects with proper structure
- `testing_strategy` - Must have arrays for unit/integration/manual tests

**Strongly Recommended:**
- `description` - WHY this matters and WHAT needs to be done
- `complexity` - `"small"`, `"medium"`, or `"large"`
- `priority` - `"low"`, `"medium"`, `"high"`, or `"critical"`
- `needs_review` - Boolean controlling review requirement
- `pitfalls` - Array of what NOT to do
- `patterns_to_follow` - Code patterns to replicate (newline-separated string)
- `acceptance_criteria` - Definition of done (newline-separated string)
- `why` - Problem/value explanation
- `what` - Specific change description
- `where_context` - Location in code/UI

## Code Patterns

### Claiming a Task

```bash
# 1. Get next available task
curl -X GET https://www.stridelikeaboss.com/api/tasks/next \
  -H "Authorization: Bearer YOUR_TOKEN"

# 2. Claim the task (returns before_doing hook)
curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task_id": 123,
    "agent_name": "OpenCode",
    "before_doing_result": {
      "exit_code": 0,
      "stdout": "Pulled latest code",
      "stderr": "",
      "duration_ms": 1500
    }
  }'

# 3. Execute before_doing hook FIRST
# Read hook from .stride.md under ## before_doing section
# Execute with environment variables from claim response

# 4. Begin implementation work
```

### Completing a Task

```bash
# 1. Finish your work

# 2. Execute after_doing hook FIRST (from .stride.md)
# If hook fails, DO NOT proceed to step 3

# 3. Only if after_doing succeeds, mark complete
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/123/complete \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "OpenCode",
    "time_spent_minutes": 45,
    "completion_notes": "Implemented feature. All tests passing.",
    "after_doing_result": {
      "exit_code": 0,
      "stdout": "Tests passed",
      "stderr": "",
      "duration_ms": 30000
    }
  }'
```

### Creating a Task

```json
{
  "type": "work",
  "title": "[Verb] [What] [Where/Context]",
  "description": "Clear explanation of WHY this matters and WHAT needs to be done",
  "complexity": "medium",
  "priority": "high",
  "needs_review": true,
  "key_files": [
    {
      "file_path": "lib/my_app/auth.ex",
      "note": "Add JWT validation",
      "position": 0
    }
  ],
  "dependencies": ["W45", "W46"],
  "verification_steps": [
    {
      "step_type": "command",
      "step_text": "mix test test/auth_test.exs",
      "expected_result": "All tests pass",
      "position": 0
    }
  ],
  "testing_strategy": {
    "unit_tests": ["Test JWT generation", "Test token validation"],
    "integration_tests": ["Full auth flow with database"],
    "manual_tests": ["Verify login form works"],
    "edge_cases": ["Expired tokens", "Invalid credentials"],
    "coverage_target": "100% for auth module"
  },
  "acceptance_criteria": "Users can log in with email/password\nJWT tokens are generated correctly\nExpired tokens are rejected",
  "patterns_to_follow": "Follow existing auth patterns in lib/my_app/auth/*.ex",
  "pitfalls": ["Don't hardcode secrets", "Don't skip token validation"],
  "why": "Users need secure authentication to access protected resources",
  "what": "Implement JWT-based authentication system",
  "where_context": "lib/my_app/auth/ directory and related controllers"
}
```

### Creating a Goal with Nested Tasks

```json
{
  "type": "goal",
  "title": "Implement User Authentication System",
  "description": "Complete authentication system with JWT, password reset, and 2FA",
  "complexity": "large",
  "tasks": [
    {
      "type": "work",
      "title": "Create user schema and migration",
      "complexity": "small",
      "key_files": [{"file_path": "priv/repo/migrations/xxx_create_users.exs", "note": "User table", "position": 0}],
      "dependencies": []
    },
    {
      "type": "work",
      "title": "Implement JWT authentication",
      "complexity": "medium",
      "key_files": [{"file_path": "lib/my_app/auth.ex", "note": "JWT logic", "position": 0}],
      "dependencies": [0]
    },
    {
      "type": "work",
      "title": "Add password reset functionality",
      "complexity": "medium",
      "dependencies": [1]
    }
  ]
}
```

## Stride Configuration Files

Your project should have these files:

1. **`.stride_auth.md`** (NEVER commit - add to .gitignore)
   - Contains API URL and bearer token
   - Template available from onboarding endpoint

2. **`.stride.md`** (commit to version control)
   - Contains hook execution scripts
   - Four sections: before_doing, after_doing, before_review, after_review

## Documentation Links

- **Onboarding:** https://www.stridelikeaboss.com/api/agent/onboarding
- **Task Writing Guide:** https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md
- **API Reference:** https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md
- **Hook Execution:** https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md
- **AI Workflow:** https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md

## Quick Reference

**Workflow:** claim → before_doing hook → work → after_doing hook → complete → [if needs_review=false: claim next, else: stop]

**API Base:** https://www.stridelikeaboss.com

**Authentication:** Authorization: Bearer YOUR_TOKEN

**Never commit:** .stride_auth.md (contains secrets)

**Always commit:** .stride.md (contains hooks)
