# PATCH /api/tasks/:id/complete

Mark a task as complete. This moves the task to the Review column (or directly to Done if `needs_review=false`).

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id/complete`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21") |

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `after_doing_result` | object | **Yes** | Result of executing the `after_doing` hook. Must include `exit_code`, `output`, and `duration_ms`. |
| `before_review_result` | object | **Yes** | Result of executing the `before_review` hook. Must include `exit_code`, `output`, and `duration_ms`. |
| `agent_name` | string | No | Name of the agent completing the task (e.g., "Claude Sonnet 4.5"). Defaults to "Unknown". |
| `time_spent_minutes` | integer | No | Time spent on the task in minutes |
| `completion_notes` | string | No | Notes about the completion |
| `completion_summary` | string | No | JSON-encoded summary of changes made |
| `actual_complexity` | string | No | Actual complexity experienced ("small", "medium", "large") |
| `actual_files_changed` | string | No | Actual number of files changed |

**IMPORTANT:** You must execute BOTH the `after_doing` AND `before_review` hooks BEFORE calling this endpoint and include both execution results in your request.

### Hook Result Format

Both `after_doing_result` and `before_review_result` parameters must be objects with these fields:

```json
{
  "exit_code": 0,
  "output": "Hook execution output (stdout/stderr combined)",
  "duration_ms": 45678
}
```

- `exit_code`: Must be `0` for success. Non-zero exit codes will be rejected.
- `output`: String containing the output from hook execution (e.g., test results, linter output, PR creation output)
- `duration_ms`: Time taken to execute the hook in milliseconds

### Request Body Example

```json
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing.",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix format --check-formatted\nAll files formatted correctly\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  }
}
```

## Response

### Success (200 OK)

Returns the completed task and hook metadata. The number of hooks depends on the task's `needs_review` setting:

**If `needs_review=true`** (task goes to Review column):

- Returns `after_doing` hook only (both `after_doing` and `before_review` were already executed and validated)

**If `needs_review=false`** (task goes directly to Done):

- Returns `after_doing` and `after_review` hooks (`after_doing` and `before_review` were already executed; `after_review` still needs execution)

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "review",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "task",
    "column_id": 7,
    "column_name": "Review",
    "board_id": 1,
    "board_name": "Main Board",
    "assigned_to_id": 5,
    "assigned_to_name": "Agent User",
    "completed_by_agent": "ai_agent:claude-sonnet-4-5",
    "time_spent_minutes": 45,
    "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing.",
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:30:00Z"
  },
  "hooks": [
    {
      "name": "after_doing",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_DESCRIPTION": "Add JWT authentication to the API",
        "TASK_STATUS": "review",
        "TASK_COMPLEXITY": "medium",
        "TASK_PRIORITY": "high",
        "TASK_NEEDS_REVIEW": "true",
        "BOARD_ID": "1",
        "BOARD_NAME": "Main Board",
        "COLUMN_ID": "7",
        "COLUMN_NAME": "Review",
        "AGENT_NAME": "Claude Sonnet 4.5",
        "HOOK_NAME": "after_doing"
      },
      "timeout": 120000,
      "blocking": true
    },
    {
      "name": "before_review",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_STATUS": "review",
        "AGENT_NAME": "Claude Sonnet 4.5",
        "HOOK_NAME": "before_review"
      },
      "timeout": 60000,
      "blocking": true
    }
  ]
}
```

### Forbidden (403)

Trying to complete a task assigned to someone else:

```json
{
  "error": "You can only complete tasks that you are assigned to"
}
```

### Unprocessable Entity (422)

Hook validation failed (missing or invalid `after_doing_result`):

```json
{
  "error": "after_doing hook result is required",
  "hook": "after_doing",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md",
  "related_docs": [
    "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#hook-execution"
  ],
  "common_causes": [
    "Hook result not provided in request (required parameter missing)",
    "Hook result missing required fields (exit_code, output, duration_ms)",
    "Blocking hook failed with non-zero exit code",
    "Hook result is not a properly formatted map"
  ],
  "required_format": {
    "after_doing_result": {
      "exit_code": 0,
      "output": "Hook execution output",
      "duration_ms": 1234
    }
  }
}
```

Or hook execution failed with non-zero exit code:

```json
{
  "error": "after_doing is a blocking hook and failed with exit code 1. Fix the issues and try again.",
  "hook": "after_doing",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md"
}
```

Or task is not in a valid state to complete:

```json
{
  "error": "Task must be in progress or blocked to complete"
}
```

## Workflow

**CRITICAL: Hook execution is mandatory!** Follow this workflow:

1. **Complete the work** - Implement all required changes

2. **Execute the `after_doing` hook FIRST** (blocking, 120s timeout)
   - This hook typically runs tests, builds, or quality checks
   - Example: Run test suite, build project, run linters
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

3. **Execute the `before_review` hook SECOND** (blocking, 60s timeout)
   - This hook typically creates PRs, generates documentation, or prepares for review
   - Example: Create pull request, generate API docs, update changelog
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

4. **Call the complete endpoint** - Include BOTH hook execution results
   - Both hooks must have succeeded (exit code 0)
   - Include both `after_doing_result` and `before_review_result` in request
   - If either hook failed, do NOT call the complete endpoint - fix the issues first

5. **Execute remaining hooks** (returned in the response):
   - `after_review` hook (blocking, 60s timeout) - only if `needs_review=false`

6. **Wait for review** (if `needs_review=true`)
   - A human reviewer will approve or request changes
   - Call `PATCH /api/tasks/:id/mark_reviewed` to finalize

## Example Usage

### Complete Workflow Example

```bash
# Step 1: Execute after_doing hook FIRST
# Read hook command from .stride.md (e.g., "mix test && mix credo --strict")
START_TIME_1=$(date +%s%3N)
OUTPUT_1=$(timeout 120 bash -c 'mix test && mix format --check-formatted && mix credo --strict' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(date +%s%3N)
DURATION_1=$((END_TIME_1 - START_TIME_1))

# Check if after_doing succeeded before proceeding
if [ $EXIT_CODE_1 -ne 0 ]; then
  echo "after_doing hook failed. Fix issues before continuing."
  exit 1
fi

# Step 2: Execute before_review hook SECOND
# Read hook command from .stride.md (e.g., "gh pr create --title '$TASK_TITLE'")
START_TIME_2=$(date +%s%3N)
OUTPUT_2=$(timeout 60 bash -c 'gh pr create --title "W21: Implement authentication" --body "Ready for review"' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(date +%s%3N)
DURATION_2=$((END_TIME_2 - START_TIME_2))

# Check if before_review succeeded before proceeding
if [ $EXIT_CODE_2 -ne 0 ]; then
  echo "before_review hook failed. Fix issues before continuing."
  exit 1
fi

# Step 3: If both hooks succeeded, complete the task with both results
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"Claude Sonnet 4.5\",
    \"time_spent_minutes\": 45,
    \"completion_notes\": \"All tests passing. PR created. Ready for review.\",
    \"after_doing_result\": {
      \"exit_code\": $EXIT_CODE_1,
      \"output\": \"$OUTPUT_1\",
      \"duration_ms\": $DURATION_1
    },
    \"before_review_result\": {
      \"exit_code\": $EXIT_CODE_2,
      \"output\": \"$OUTPUT_2\",
      \"duration_ms\": $DURATION_2
    }
  }" \
  https://www.stridelikeaboss.com/api/tasks/W21/complete
```

### Complete task by ID with both hooks validated

```bash
# Execute after_doing hook
START_TIME_1=$(date +%s%3N)
OUTPUT_1=$(timeout 120 bash -c 'npm test && npm run lint && npm run build' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(date +%s%3N)
DURATION_1=$((END_TIME_1 - START_TIME_1))

# Execute before_review hook
START_TIME_2=$(date +%s%3N)
OUTPUT_2=$(timeout 60 bash -c 'npm run docs:generate' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(date +%s%3N)
DURATION_2=$((END_TIME_2 - START_TIME_2))

# Complete with both results
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"Claude Sonnet 4.5\",
    \"after_doing_result\": {
      \"exit_code\": $EXIT_CODE_1,
      \"output\": \"$OUTPUT_1\",
      \"duration_ms\": $DURATION_1
    },
    \"before_review_result\": {
      \"exit_code\": $EXIT_CODE_2,
      \"output\": \"$OUTPUT_2\",
      \"duration_ms\": $DURATION_2
    }
  }" \
  https://www.stridelikeaboss.com/api/tasks/123/complete
```

## Hook Execution Example

After completing the task, execute remaining hooks from the response:

```bash
# The API response may include after_review hook (only if needs_review=false)
# Execute this AFTER the complete endpoint returns successfully

# If needs_review=false, execute after_review hook (BLOCKING)
export TASK_ID="123"
export TASK_IDENTIFIER="W21"
export HOOK_NAME="after_review"
# ... set all env vars from response

START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c './scripts/deploy.sh' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "after_review hook failed with exit code $EXIT_CODE"
  echo "Output: $OUTPUT"
  # Handle failure - task may need manual intervention
fi
```

## Notes

- Both `after_doing_result` and `before_review_result` parameters are **required**
- You MUST execute BOTH the `after_doing` AND `before_review` hooks BEFORE calling this endpoint
- Both hooks must complete successfully (exit code 0) or the completion will be rejected
- You can only complete tasks that are assigned to you
- Task must be in `in_progress` or `blocked` status
- If `needs_review=true`, task moves to Review column with `review` status
- If `needs_review=false`, task automatically moves to Done column with `completed` status
- Both `after_doing` and `before_review` hooks are **blocking** - non-zero exit codes will cause the API to reject your completion
- The `after_review` hook is also **blocking** and must be executed after API call returns (only if `needs_review=false`)
- Hook timeouts: `after_doing` is 120 seconds, `before_review` is 60 seconds, `after_review` is 60 seconds
- Agent model from your API token is automatically recorded as `completed_by_agent`
- If the task is a goal (parent task), it will only move to Done when all child tasks are complete

## See Also

- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) - Mark task as reviewed after completion
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) - Unclaim if you can't complete
