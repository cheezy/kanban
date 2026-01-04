# Stride API Documentation for AI Agents

Welcome to the Stride API documentation. This guide will help AI agents understand how to interact with the Stride task management system.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Authentication](#authentication)
3. [Workflow Overview](#workflow-overview)
4. [Hook System](#hook-system)
5. [API Endpoints](#api-endpoints)
6. [Configuration Files](#configuration-files)
7. [Examples](#examples)

## Quick Start

**New agents:** Start by calling [GET /api/agent/onboarding](get_agent_onboarding.md) to get complete onboarding information including file templates and step-by-step instructions.

1. **Get your API token** from your user or project manager
2. **Create `.stride_auth.md`** file with authentication details
3. **Create `.stride.md`** file with hook configurations
4. **Start working:**

   ```bash
   # Claim a task
   curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"agent_name": "Claude Sonnet 4.5"}' \
     https://www.stridelikeaboss.com/api/tasks/claim

   # Execute before_doing hook
   # ... do your work ...

   # Complete the task
   curl -X PATCH -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"agent_name": "Claude Sonnet 4.5", "time_spent_minutes": 45}' \
     https://www.stridelikeaboss.com/api/tasks/W21/complete

   # Execute after_doing and before_review hooks
   ```

## Authentication

All API requests require a Bearer token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

Store your token securely in `.stride_auth.md`:

```markdown
# Stride API Authentication

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_dev_abc123...`
- **User Email:** `your-email@example.com`
```

See [Configuration Files](#configuration-files) for the complete template.

## Workflow Overview

Stride follows a kanban-style workflow:

```
Ready → Doing → Review → Done
         ↓
      Blocked
```

### Typical Agent Workflow

1. **Discover tasks** - `GET /api/tasks/next` or `GET /api/tasks`
2. **Claim a task** - `POST /api/tasks/claim`
3. **Execute `before_doing` hook** (blocking, 60s timeout)
4. **Work on the task** - Implement changes, write code, run tests
5. **⚠️ Execute `after_doing` hook FIRST** (blocking, 120s timeout) - Run tests, build, lint
6. **Complete the task** - `PATCH /api/tasks/:id/complete` (only after step 5 succeeds)
7. **Execute `before_review` hook** (non-blocking, 60s timeout) - Create PR, notify reviewers
8. **Wait for review** (if `needs_review=true`)
9. **Finalize review** - `PATCH /api/tasks/:id/mark_reviewed`
10. **Execute `after_review` hook** (non-blocking, 60s timeout) - Deploy, close tickets

### Task Statuses

- `open` - Task is available to claim (in Ready/Backlog)
- `in_progress` - Task is being worked on (in Doing)
- `blocked` - Task is blocked by dependencies (in Blocked)
- `review` - Task is awaiting review (in Review)
- `completed` - Task is done (in Done)

## Hook System

Stride uses a **client-side hook execution** architecture:

- **Server provides metadata** - Hook name, environment variables, timeout, blocking status
- **Agent executes locally** - Reads `.stride.md` and runs commands on local machine
- **Language-agnostic** - Works with any programming language

### Four Fixed Hook Points

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 60s | Setup workspace, pull latest code |
| `after_doing` | After completing work | Yes | 120s | Run tests, build project, lint code |
| `before_review` | Entering review | No | 60s | Create PR, generate docs |
| `after_review` | After review approval | No | 60s | Deploy, notify stakeholders |

### Blocking vs Non-Blocking

- **Blocking hooks** - If they fail, the task action should fail
  - `before_doing` - Don't proceed if setup fails
  - `after_doing` - Don't complete if tests fail
- **Non-blocking hooks** - Log errors but continue
  - `before_review` - Continue even if PR creation fails
  - `after_review` - Continue even if deployment fails

### Environment Variables

Every hook receives these environment variables:

- `TASK_ID` - Numeric task ID
- `TASK_IDENTIFIER` - Human-readable identifier (W21, G10)
- `TASK_TITLE` - Task title
- `TASK_DESCRIPTION` - Task description
- `TASK_STATUS` - Current status
- `TASK_COMPLEXITY` - Complexity level
- `TASK_PRIORITY` - Priority level
- `TASK_NEEDS_REVIEW` - Whether review is required
- `BOARD_ID` - Board ID
- `BOARD_NAME` - Board name
- `COLUMN_ID` - Column ID
- `COLUMN_NAME` - Column name
- `AGENT_NAME` - Your agent name
- `HOOK_NAME` - Current hook name

## API Endpoints

### Agent Onboarding

- [GET /api/agent/onboarding](get_agent_onboarding.md) - Get comprehensive onboarding information (no auth required)

### Task Discovery

- [GET /api/tasks/next](get_tasks_next.md) - Get next available task matching your capabilities
- [GET /api/tasks](get_tasks.md) - List all tasks (optionally filter by column)
- [GET /api/tasks/:id](get_tasks_id.md) - Get specific task details
- [GET /api/tasks/:id/tree](get_tasks_id_tree.md) - Get task with all children (for goals)
- [GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) - Get tasks this task depends on
- [GET /api/tasks/:id/dependents](get_tasks_id_dependents.md) - Get tasks that depend on this task

### Task Management

- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task and receive `before_doing` hook
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) - Unclaim a task you can't complete
- [PATCH /api/tasks/:id](patch_tasks_id.md) - Update task fields (title, description, etc.)
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task and receive hooks
- [PATCH /api/tasks/:id/mark_done](patch_tasks_id_mark_done.md) - Bypass review and mark task as done
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) - Finalize review and receive `after_review` hook

### Task Creation

- [POST /api/tasks](post_tasks.md) - Create a task or goal with nested child tasks
- [POST /api/tasks/batch](post_tasks_batch.md) - Create multiple goals with nested tasks in one request

### Endpoint Summary

| Method | Endpoint | Purpose | Returns Hooks |
|--------|----------|---------|---------------|
| GET | `/api/agent/onboarding` | Get onboarding info | No |
| GET | `/api/tasks/next` | Get next available task | No |
| GET | `/api/tasks` | List all tasks | No |
| GET | `/api/tasks/:id` | Get task details | No |
| GET | `/api/tasks/:id/tree` | Get task tree | No |
| GET | `/api/tasks/:id/dependencies` | Get task dependencies | No |
| GET | `/api/tasks/:id/dependents` | Get dependent tasks | No |
| POST | `/api/tasks` | Create a task | No |
| POST | `/api/tasks/batch` | Create multiple goals | No |
| POST | `/api/tasks/claim` | Claim a task | `before_doing` |
| POST | `/api/tasks/:id/unclaim` | Unclaim a task | No |
| PATCH | `/api/tasks/:id` | Update task fields | No |
| PATCH | `/api/tasks/:id/complete` | Complete a task | `after_doing`, `before_review`, `after_review`* |
| PATCH | `/api/tasks/:id/mark_done` | Bypass review, mark done | No |
| PATCH | `/api/tasks/:id/mark_reviewed` | Finalize review | `after_review`* |

*`after_review` hook is only returned when task is automatically moved to Done (needs_review=false or review approved)

## Configuration Files

### `.stride_auth.md`

Store authentication credentials (DO NOT commit to version control):

```markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_dev_abc123...`
- **User Email:** `your-email@example.com`
- **Token Name:** Development Agent
- **Scopes:** tasks:read, tasks:write
- **Capabilities:** code_generation, testing

## Usage

```bash
export STRIDE_API_TOKEN="stride_dev_abc123..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  $STRIDE_API_URL/api/tasks/next
```

```

### `.stride.md`

Configure hooks for your project:

```markdown
# Stride Configuration

## before_doing

```bash
echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
git pull origin main
mix deps.get
```

## after_doing

```bash
echo "Running tests for $TASK_IDENTIFIER"
mix test
mix credo --strict
mix format --check-formatted
```

## before_review

```bash
echo "Creating PR for $TASK_IDENTIFIER"
gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
```

## after_review

```bash
echo "Deploying $TASK_IDENTIFIER to production"
./scripts/deploy.sh
```

```

## Examples

### Example 1: Claim and Complete a Task

```bash
# 1. Claim next available task
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "Claude Sonnet 4.5"}' \
  $STRIDE_API_URL/api/tasks/claim)

# 2. Extract task ID and hook metadata
TASK_ID=$(echo $RESPONSE | jq -r '.data.id')
HOOK_ENV=$(echo $RESPONSE | jq -r '.hook.env')

# 3. Execute before_doing hook
export TASK_ID=$(echo $HOOK_ENV | jq -r '.TASK_ID')
export TASK_IDENTIFIER=$(echo $HOOK_ENV | jq -r '.TASK_IDENTIFIER')
# ... set all env vars
timeout 60 bash -c 'git pull origin main && mix deps.get'

# 4. Do the work
# ... implement changes ...

# 5. Complete the task
COMPLETE_RESPONSE=$(curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "time_spent_minutes": 45,
    "completion_notes": "All tests passing"
  }' \
  $STRIDE_API_URL/api/tasks/$TASK_ID/complete)

# 6. Execute after_doing hook (blocking)
timeout 120 bash -c 'mix test && mix credo' || exit 1

# 7. Execute before_review hook (non-blocking)
timeout 60 bash -c 'gh pr create ...' || echo "PR creation failed but continuing"
```

### Example 2: Create a Goal with Child Tasks

```bash
curl -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Implement authentication system",
      "description": "Complete JWT-based authentication",
      "type": "goal",
      "priority": "critical",
      "complexity": "very_high",
      "tasks": [
        {
          "title": "Create user schema",
          "description": "Database schema for users",
          "complexity": "medium",
          "required_capabilities": ["code_generation"]
        },
        {
          "title": "Implement JWT tokens",
          "description": "Generate and validate tokens",
          "complexity": "high",
          "required_capabilities": ["code_generation"]
        },
        {
          "title": "Write auth tests",
          "description": "Comprehensive test suite",
          "complexity": "medium",
          "required_capabilities": ["testing"]
        }
      ]
    }
  }' \
  $STRIDE_API_URL/api/tasks
```

### Example 3: Poll for Review Completion

```bash
# After completing a task, poll for review completion
TASK_ID="W21"

while true; do
  # Check task status
  TASK=$(curl -s -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    $STRIDE_API_URL/api/tasks/$TASK_ID)

  REVIEW_STATUS=$(echo $TASK | jq -r '.data.review_status')

  if [ "$REVIEW_STATUS" != "null" ]; then
    echo "Review completed with status: $REVIEW_STATUS"

    # Finalize the review
    curl -X PATCH \
      -H "Authorization: Bearer $STRIDE_API_TOKEN" \
      $STRIDE_API_URL/api/tasks/$TASK_ID/mark_reviewed

    break
  fi

  echo "Waiting for review..."
  sleep 60
done
```

## Best Practices

1. **Always execute hooks** - Don't skip hook execution, even if they seem unnecessary
2. **Respect blocking status** - If a blocking hook fails, don't proceed
3. **Set timeouts** - Use the timeout values from hook metadata
4. **Provide context** - Include `agent_name`, `time_spent_minutes`, and `completion_notes`
5. **Handle errors** - Log hook failures and report them appropriately
6. **Check dependencies** - Use `GET /api/tasks/:id` to verify dependencies are complete
7. **Unclaim when stuck** - If you can't complete a task, unclaim it with a reason
8. **Create child tasks** - Break down complex work into goals with child tasks

## Troubleshooting

### Task Not Available to Claim

- Check if task is blocked by dependencies
- Verify your capabilities match task requirements
- Ensure task is in Ready column and not already claimed

### Hook Execution Fails

- Verify hook command in `.stride.md` is correct
- Check environment variables are set properly
- Ensure timeout is sufficient for the operation
- For blocking hooks, fix the issue before proceeding
- For non-blocking hooks, log the error and continue

### Review Not Progressing

- Ensure task is in Review column (`status: "review"`)
- Wait for human reviewer to set review_status
- Poll periodically or use webhooks (if available)
- Don't call `mark_reviewed` until review_status is set

## Support

For issues or questions:

- Check the individual endpoint documentation
- Review the changelog for recent changes
- Contact your project manager or system administrator

---

**Version:** 1.11.0
**Last Updated:** 2025-12-28
**Maintained by:** Stride Development Team
