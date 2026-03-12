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
- **before_review** (60s, blocking) - Execute BEFORE calling complete endpoint (create PR, docs)
- **after_review** (60s, blocking) - Execute after approval (merge, deploy)

**CRITICAL:** Execute BOTH `after_doing` AND `before_review` hooks BEFORE calling the task completion endpoint. The API requires both `after_doing_result` and `before_review_result` in the completion request. Hook validation failures must prevent task completion.

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

### 5. Calling Complete Endpoint Before Executing BOTH Hooks

**DON'T:**
1. Finish work
2. Call `PATCH /api/tasks/:id/complete`
3. Execute hooks afterward

**DO:**
1. Finish work
2. Execute `after_doing` hook (tests, lint, build) — capture result
3. Execute `before_review` hook (create PR, docs) — capture result
4. Only if BOTH hooks succeed, call `PATCH /api/tasks/:id/complete` WITH both results

**WHY:** The API REQUIRES both `after_doing_result` and `before_review_result` parameters. Requests without them are rejected with 422 errors.

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

# 2. Execute before_doing hook FIRST (from .stride.md ## before_doing section)
# Capture exit_code, output, and duration_ms

# 3. Only if before_doing succeeds, claim the task WITH hook result
curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "identifier": "W47",
    "agent_name": "OpenCode",
    "skills_version": "1.0",
    "before_doing_result": {
      "exit_code": 0,
      "output": "Already up to date.\nAll dependencies are up to date",
      "duration_ms": 1500
    }
  }'

# 4. Begin implementation work immediately
```

### Completing a Task

```bash
# 1. Finish your work

# 2. Execute after_doing hook (from .stride.md ## after_doing section)
# Capture exit_code, output, duration_ms
# If hook fails, DO NOT proceed — fix issues and retry

# 3. Execute before_review hook (from .stride.md ## before_review section)
# Capture exit_code, output, duration_ms
# If hook fails, DO NOT proceed — fix issues and retry

# 4. Only if BOTH hooks succeed, mark complete WITH both results
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/123/complete \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "OpenCode",
    "time_spent_minutes": 45,
    "completion_notes": "Implemented feature. All tests passing.",
    "completion_summary": "Added JWT auth with refresh tokens",
    "actual_complexity": "medium",
    "actual_files_changed": "lib/my_app/auth.ex, test/my_app/auth_test.exs",
    "skills_version": "1.0",
    "after_doing_result": {
      "exit_code": 0,
      "output": "Running tests...\n230 tests, 0 failures\nmix credo --strict\nNo issues found",
      "duration_ms": 45678
    },
    "before_review_result": {
      "exit_code": 0,
      "output": "Creating pull request...\nPR #123 created",
      "duration_ms": 2340
    }
  }'
```

**Complete endpoint required fields:**
- `agent_name` (string) - Name of the completing agent
- `time_spent_minutes` (integer) - Actual time spent
- `completion_notes` (string) - Summary of what was done
- `completion_summary` (string) - Brief summary for tracking
- `actual_complexity` (enum) - `"small"`, `"medium"`, or `"large"`
- `actual_files_changed` (string) - Comma-separated file paths (NOT an array)
- `after_doing_result` (object) - Hook result with `exit_code`, `output`, `duration_ms`
- `before_review_result` (object) - Hook result with `exit_code`, `output`, `duration_ms`

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

**Workflow:** before_doing hook → claim WITH result → work → after_doing hook → before_review hook → complete WITH both results → [if needs_review=false: after_review hook → claim next, else: stop]

**API Base:** https://www.stridelikeaboss.com

**Authentication:** Authorization: Bearer YOUR_TOKEN

**Never commit:** .stride_auth.md (contains secrets)

**Always commit:** .stride.md (contains hooks)
