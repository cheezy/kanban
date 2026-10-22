# Agent Hook Execution Guide

This guide explains how AI agents should execute workflow hooks when working with Stride tasks.

## Overview

Stride uses a **client-side hook execution** architecture where:
- **Server provides metadata** - Hook name, environment variables, timeout, blocking status
- **Agent executes locally** - Reads `.stride.md` and runs commands on local machine
- **Language-agnostic** - Works with any programming language or tooling

This design allows agents to integrate with git workflows, run quality checks, and perform setup/cleanup tasks automatically.

**Recommended:** Use the `stride-workflow` orchestrator skill as your entry point. It handles hook execution as part of the complete task lifecycle (claim → explore → implement → review → complete). For platforms with automatic hook support (Claude Code, Gemini CLI, OpenCode), hooks fire automatically when API calls are made. For platforms with manual execution (Copilot CLI, Codex CLI, Cursor, Windsurf), the orchestrator guides you through each hook step.

## Platform Support

This guide provides examples for multiple platforms:

- **Unix/Linux/macOS**: Bash shell (default examples shown first)
- **Windows WSL2**: Bash shell (use Unix/Linux examples)
- **Windows PowerShell**: PowerShell scripts (alternatives provided)
- **Windows Git Bash**: Bash shell with Windows paths (use Unix/Linux examples with some limitations)

Each hook example shows both Unix/Linux and Windows PowerShell versions where they differ. For complete Windows setup instructions, see [WINDOWS-SETUP.md](WINDOWS-SETUP.md).

## Quick Start

### 1. Create `.stride.md` Configuration File

Create a `.stride.md` file at the root of your repository with hook implementations.

**Note:** Examples below use Unix/Linux/macOS bash syntax. For Windows PowerShell equivalents, see [WINDOWS-SETUP.md](WINDOWS-SETUP.md#powershell-hook-examples).

````markdown
# Stride Configuration

## before_doing

Executes before starting work on a task (blocking).

```bash
echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
git pull origin main
```

## after_doing

Executes after completing work (blocking).
If this fails, task completion should fail.

```bash
echo "Running tests for $TASK_IDENTIFIER"
mix test
mix credo --strict
```

## before_review

Executes when task enters review (blocking).

```bash
echo "Creating PR for $TASK_IDENTIFIER"
gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
```

## after_review

Executes after review approval (blocking).

```bash
echo "Task $TASK_IDENTIFIER complete"
```

## after_goal

Executes once the last child task of a goal is done (blocking).

```bash
echo "Goal finished after $TASK_IDENTIFIER"
git push origin main
```
````

### 2. Commit `.stride.md` to Version Control

This file should be committed so all agents and developers can see the configured hooks.

## Four Fixed Hook Points

Stride defines four hook points in the task lifecycle, plus a fifth, `after_goal`, that runs when a goal's last child task is done:

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 600s | Pull latest code, setup workspace |
| `after_doing` | After completing work | Yes | 600s | Run tests, build project, lint code |
| `before_review` | Entering review | Yes | 600s | Create PR, generate documentation |
| `after_review` | After review approval | Yes | 600s | Merge PR, deploy to production |
| `after_goal` | After a goal's last child task is done | Yes | 600s | Push the goal's work, release |

The server sends each hook's `blocking` flag and its `timeout` in milliseconds in the hook metadata. Today every hook is sent as `"blocking": true` with a `"timeout"` of `600000`. Use the value the server sends rather than a number from this guide.

**Where each hook arrives:**

| Hook | Delivered in | Result reported in |
|------|--------------|--------------------|
| `before_doing` | The claim response's `hook` object | `before_doing_result` on [POST /api/tasks/claim](api/post_tasks_claim.md) |
| `after_doing` | The `/complete` response's `hooks` list | `after_doing_result` on [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md) |
| `before_review` | The `/complete` response's `hooks` list | `before_review_result` on `/complete` |
| `after_review` | The `/complete` response's `hooks` list when `needs_review=false`; the approving `/mark_reviewed` response when `needs_review=true` | `after_review_result` on [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md); not reported when `needs_review=false` |
| `after_goal` | Appended to the `hooks` list of the `/complete` or approving `/mark_reviewed` response that finished the goal's last child | [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md), against the goal |

You run `after_doing` and `before_review` before calling `/complete`, and `after_review` before calling `/mark_reviewed`: their entries in the response describe hooks you have already run.

### The after_goal Hook

When a completion finishes the last open child task of a goal, the server arms the goal's `after_goal` hook and appends an `after_goal` entry to that response's `hooks` list. That is the `/complete` response when the child went straight to Done (`needs_review=false`), or the `/mark_reviewed` response that approved it.

1. Run the `## after_goal` section of `.stride.md`, capturing `exit_code`, `output` and `duration_ms`. An empty section did no work; report it as `{"exit_code": 0, "output": "", "duration_ms": 0}`.
2. Report the result with [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md), where `:id` is the goal, not the child task.
3. An `exit_code` of `0` moves the goal to Done. Any other exit code is recorded and the goal stays where it is, so fix the problem, run the section again and send a new report.

The goal does not wait forever: completing its last child also starts a five-minute grace window, and if no successful report has arrived when it ends, the server moves the goal to Done itself, even when the latest report failed.

The `after_goal` entry in `hooks` carries the completed child's `TASK_*` variables, with `HOOK_NAME` set to `after_goal`. To learn the goal's own ID and identifier, or whether a completion armed the hook at all, call [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md) — see [Goal Information (after_goal only)](#goal-information-after_goal-only).

`PATCH /api/tasks/:id/mark_done` never arms or delivers `after_goal`.

### Blocking Hooks

**ALL hooks are now blocking:**
- If hook fails (non-zero exit code), the task action is aborted
- Task remains in previous state
- Error returned to agent with 422 status
- Agent must fix the issue and retry

**Examples:**
- If `after_doing` tests fail, task completion is blocked
- If `before_review` PR creation fails, task completion is blocked
- If `after_review` deployment fails, mark_reviewed is blocked
- If `after_goal` fails, the goal stays out of Done until a successful report or the end of the grace window

For the `422` bodies each endpoint returns, see its page under [api/](api/), for example [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md#unprocessable-entity-422).

## Hook Execution Workflow

⚠️ **CRITICAL: Hook validation is mandatory!** You MUST execute hooks BEFORE calling API endpoints and include the execution results.

### Example: Claiming and Completing a Task

```bash
# 1. Execute before_doing hook FIRST
# Read hook command from .stride.md. 600 seconds is the timeout the server sends today.
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 600 bash -c 'echo "Starting task..."; git pull origin main' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

# Check if hook succeeded
if [ $EXIT_CODE -ne 0 ]; then
  echo "Hook execution failed - cannot claim task"
  exit 1
fi

# 2. Claim task with hook result (jq builds the JSON, so quotes and newlines
#    in the hook output cannot break the request body)
RESPONSE=$(jq -n \
  --arg agent "Claude Sonnet 4.5" \
  --arg out "$OUTPUT" --argjson code "$EXIT_CODE" --argjson dur "$DURATION" \
  '{agent_name: $agent,
    before_doing_result: {exit_code: $code, output: $out, duration_ms: $dur}}' |
  curl -s -X POST \
    -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    "$STRIDE_API_URL/api/tasks/claim")

# 3. Extract task details
TASK_ID=$(echo "$RESPONSE" | jq -r '.data.id')
TASK_IDENTIFIER=$(echo "$RESPONSE" | jq -r '.data.identifier')
TASK_TITLE=$(echo "$RESPONSE" | jq -r '.data.title')

# 4. Do your work on the task
# ... implement changes ...

# 5. Execute after_doing hook FIRST
START_TIME_1=$(date +%s%3N)
OUTPUT_1=$(timeout 600 bash -c 'mix test && mix credo --strict' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(date +%s%3N)
DURATION_1=$((END_TIME_1 - START_TIME_1))

if [ $EXIT_CODE_1 -ne 0 ]; then
  echo "Tests failed - cannot complete task"
  exit 1
fi

# 6. Execute before_review hook SECOND
START_TIME_2=$(date +%s%3N)
OUTPUT_2=$(timeout 600 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(date +%s%3N)
DURATION_2=$((END_TIME_2 - START_TIME_2))

if [ $EXIT_CODE_2 -ne 0 ]; then
  echo "PR creation failed - cannot complete task"
  exit 1
fi

# 7. Complete the task with BOTH hook results and the other required fields.
#    explorer_result and reviewer_result use the self-reported skip form here;
#    see "Related: Completion Validation (G65)" below for the dispatched form.
COMPLETE_RESPONSE=$(jq -n \
  --arg agent "Claude Sonnet 4.5" \
  --arg out1 "$OUTPUT_1" --argjson code1 "$EXIT_CODE_1" --argjson dur1 "$DURATION_1" \
  --arg out2 "$OUTPUT_2" --argjson code2 "$EXIT_CODE_2" --argjson dur2 "$DURATION_2" \
  '{agent_name: $agent,
    completion_summary: "Added refresh-token rotation to the session controller.",
    actual_complexity: "medium",
    actual_files_changed: "lib/my_app/auth.ex, test/my_app/auth_test.exs",
    time_spent_minutes: 45,
    completion_notes: "All tests passing, PR created",
    after_doing_result: {exit_code: $code1, output: $out1, duration_ms: $dur1},
    before_review_result: {exit_code: $code2, output: $out2, duration_ms: $dur2},
    explorer_result: {dispatched: false, reason: "self_reported_exploration",
      summary: "Read the key files and their tests inline; the change follows the existing context pattern."},
    reviewer_result: {dispatched: false, reason: "self_reported_review",
      summary: "Re-read the diff against every acceptance criterion and pitfall; no issues found."}}' |
  curl -s -X PATCH \
    -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    "$STRIDE_API_URL/api/tasks/$TASK_IDENTIFIER/complete")

# 8. The response's hooks list names what to run next: after_review when
#    needs_review=false, and after_goal when this task was a goal's last open
#    child (see "The after_goal Hook" above)
```

## Environment Variables

All hooks receive these environment variables:

### Task Information
- `TASK_ID` - Numeric task ID (e.g., `42`)
- `TASK_IDENTIFIER` - Human-readable identifier (e.g., `W21`, `G10`)
- `TASK_TITLE` - Task title
- `TASK_DESCRIPTION` - Task description
- `TASK_STATUS` - Current status (`open`, `in_progress`, `blocked`, `completed`)
- `TASK_COMPLEXITY` - Complexity level (`small`, `medium`, `large`)
- `TASK_PRIORITY` - Priority level (`low`, `medium`, `high`, `critical`)
- `TASK_NEEDS_REVIEW` - Whether review is required (`true`/`false`)

### Board/Column Information
- `BOARD_ID` - Board ID
- `BOARD_NAME` - Board name
- `COLUMN_ID` - Column ID
- `COLUMN_NAME` - Column name

### Agent Information
- `AGENT_NAME` - Your agent name (e.g., `Claude Sonnet 4.5`)
- `HOOK_NAME` - Current hook name (`before_doing`, `after_doing`, etc.)

### Goal Information (after_goal only)

The `after_goal` entry in a `hooks` list carries the same fourteen variables as the other hooks, describing the **child task** whose completion finished the goal, with `HOOK_NAME` set to `after_goal`. The goal's own details come from [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md), whose `env` object holds:

- `GOAL_ID` - The goal's numeric ID, the `:id` to report against
- `GOAL_IDENTIFIER` - The goal's identifier (e.g., `G10`)
- `GOAL_TITLE` - The goal's title
- `GOAL_DESCRIPTION` - The goal's description
- `BOARD_ID` - Board ID
- `BOARD_NAME` - Board name
- `HOOK_NAME` - Always `after_goal`

**Platform Note:** In bash, access variables with `$VARIABLE_NAME`. In PowerShell, use `$env:VARIABLE_NAME`.

## Example Hook Implementations

### Git Workflow Integration

**Unix/Linux/macOS/WSL2 (bash):**

```bash
# Pull latest code and create feature branch
git fetch origin main
git checkout -b "task-$TASK_IDENTIFIER-$(echo $TASK_TITLE | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" origin/main
echo "Created branch for $TASK_IDENTIFIER"
```

**Windows PowerShell:**

```powershell
# Pull latest code and create feature branch
git fetch origin main
$branchName = "task-$env:TASK_IDENTIFIER-$($env:TASK_TITLE.ToLower() -replace ' ', '-' -replace '[^a-z0-9\-]', '')"
git checkout -b $branchName origin/main
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Created branch for $env:TASK_IDENTIFIER"
```

**Unix/Linux/macOS/WSL2 (after_doing):**

```bash
# Run quality checks before completion
mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix test || exit 1
mix dialyzer || exit 1
echo "All quality checks passed ✓"
```

**Unix/Linux/macOS/WSL2 (before_review):**

```bash
# Commit and push changes, create PR
git add .
git commit -m "Complete task $TASK_IDENTIFIER: $TASK_TITLE

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

git push origin HEAD

# Create pull request
gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER

## Changes
- Implemented $TASK_TITLE

## Testing
- All tests passing
- Quality checks passed"
```

**Unix/Linux/macOS/WSL2 (after_review):**

```bash
# Merge PR and clean up
gh pr merge --auto --squash
git checkout main
git pull origin main
git branch -d "task-$TASK_IDENTIFIER-*"
```

### Quality Gate Enforcement

````markdown
## after_doing
```bash
# Comprehensive quality checks - task cannot complete if these fail
set -e  # Exit on any error

echo "Running test suite..."
mix test || exit 1

echo "Running linter..."
mix credo --strict || exit 1

echo "Checking code format..."
mix format --check-formatted || exit 1

echo "Running security checks..."
mix sobelow --config || exit 1

echo "Checking test coverage..."
mix coveralls || exit 1

echo "✓ All quality gates passed"
```
````

### Environment Setup and Cleanup

````markdown
## before_doing
```bash
# Ensure environment is ready
echo "Setting up environment for $TASK_IDENTIFIER"

# Update dependencies
mix deps.get
npm install

# Verify database is up to date
mix ecto.migrate

echo "✓ Environment ready"
```

## before_review
```bash
# Generate documentation
mix docs

# Update changelog
echo "- $TASK_TITLE (#$TASK_IDENTIFIER)" >> CHANGELOG.md

# Create PR
gh pr create --title "$TASK_TITLE" \
  --body "## Summary
$TASK_DESCRIPTION

## Test Plan
- All tests passing
- Manual testing completed

Closes $TASK_IDENTIFIER"
```
````

## Error Handling

### Handling Blocking Hook Failures

**Unix/Linux/macOS/WSL2:**

```bash
# Execute after_doing hook (blocking), within the server's 600s timeout
timeout 600 bash -c 'mix test'
HOOK_EXIT_CODE=$?

if [ $HOOK_EXIT_CODE -ne 0 ]; then
  echo "ERROR: Tests failed - cannot complete task"
  echo "Task remains in 'in_progress' status"
  echo "Fix failing tests and try again"
  exit 1
fi
```

**Windows PowerShell:**

```powershell
# Execute after_doing hook (blocking) with timeout
$job = Start-Job -ScriptBlock { mix test }
$completed = Wait-Job $job -Timeout 600

if (-not $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Error "ERROR: Tests timed out after 600 seconds"
    Write-Error "Task remains in 'in_progress' status"
    exit 1
}

$result = Receive-Job $job
Remove-Job $job

if ($LASTEXITCODE -ne 0) {
    Write-Error "ERROR: Tests failed - cannot complete task"
    Write-Error "Task remains in 'in_progress' status"
    Write-Error "Fix failing tests and try again"
    exit 1
}
```

### Hook Execution Pattern

**Unix/Linux/macOS/WSL2:**

```bash
# Execute before_review hook (BLOCKING - must succeed)
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 600 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "ERROR: before_review hook failed with exit code $EXIT_CODE"
  echo "Fix the issue before calling /complete endpoint"
  exit 1
fi
```

**Windows PowerShell:**

```powershell
# Execute before_review hook (BLOCKING - must succeed) with timeout
$startTime = Get-Date
# The job's last output is the command's exit code
$job = Start-Job -ScriptBlock { gh pr create --title "$env:TASK_TITLE" 2>&1 | Out-String; $LASTEXITCODE }
$completed = Wait-Job $job -Timeout 600

if (-not $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Error "ERROR: before_review hook timed out after 600 seconds"
    Write-Error "Fix the issue before calling /complete endpoint"
    exit 1
}

$results = @(Receive-Job $job)
Remove-Job $job
$exitCode = $results[-1]

if ($exitCode -ne 0) {
    Write-Error "ERROR: before_review hook failed"
    Write-Error "Fix the issue before calling /complete endpoint"
    exit 1
}
```

### Timeout Handling

All hooks have timeouts to prevent hanging:

```bash
# Use timeout command to enforce hook timeout
HOOK_TIMEOUT=600  # seconds: the hook metadata's timeout (600000 ms) divided by 1000

timeout $HOOK_TIMEOUT bash -c '
  # Hook commands here
  mix test
' || {
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "ERROR: Hook timed out after ${HOOK_TIMEOUT}s"
  else
    echo "ERROR: Hook failed with exit code $EXIT_CODE"
  fi
  exit $EXIT_CODE
}
```

## Best Practices

### 1. Always Execute Hooks

Don't skip hook execution, even if they seem unnecessary. Hooks enforce quality gates and maintain consistency.

### 2. Respect Blocking Status

If a blocking hook fails, **do not proceed** with the action. The hook failed for a reason.

### 3. Use Provided Timeouts

Use the `timeout` value from the hook metadata. It is in milliseconds, and today it is `600000` (600 seconds) for every hook.

### 4. Log Hook Execution

Log hook execution for debugging and observability:

```bash
echo "[$(date)] Executing hook: $HOOK_NAME for task $TASK_IDENTIFIER"
# ... execute hook ...
echo "[$(date)] Hook $HOOK_NAME completed with exit code $?"
```

### 5. Handle Environment Variables Safely

Environment variables are provided by the API and should be trusted, but always quote them:

```bash
# Good - variables are quoted
git commit -m "Complete task $TASK_IDENTIFIER: $TASK_TITLE"

# Bad - may break with special characters
git commit -m Complete task $TASK_IDENTIFIER: $TASK_TITLE
```

### 6. Provide Meaningful Output

Hook output is captured and logged. Provide clear output:

```bash
echo "Running tests for task $TASK_IDENTIFIER..."
mix test
echo "✓ Tests passed (42 tests, 0 failures)"
```

### 7. Exit with Appropriate Codes

Use exit codes to indicate success/failure:

```bash
# Exit 0 for success
mix test && exit 0

# Exit non-zero for failure
mix test || exit 1

# Or use set -e to exit on any error
set -e
mix test
mix credo
# Will exit immediately if either command fails
```

## Troubleshooting

### Hook Execution Fails

**Problem:** Hook commands fail with errors

**Solution:**
- Check `.stride.md` syntax is correct
- Verify environment variables are set properly
- Ensure commands are available (git, mix, npm, etc.)
- Check timeout is sufficient for the operation
- All hooks are blocking - fix any failures before proceeding with API calls

### Commands Not Found

**Problem:** `mix: command not found` or similar errors

**Solution:**
- Ensure required tools are installed
- Check PATH environment variable includes tool locations
- Use absolute paths if necessary: `/usr/local/bin/mix test`

### Timeout Too Short

**Problem:** Hook times out before completing

**Solution:**
- Every hook gets the `timeout` the server sends in the hook metadata: `600000` ms (600 seconds) today, for every hook
- The server sets the value, so a hook cannot ask for more time; make the commands faster, for example by caching dependencies and build output between runs. Never drop a test, lint or security check from a blocking hook just to fit the timeout
- Check that your own runner is not cutting the hook off sooner than the server's timeout

### Variables Not Substituted

**Problem:** Hook sees literal `$TASK_ID` instead of actual value

**Solution:**
- Variables should be exported before executing hook commands
- Check that hook metadata includes the `env` object with all variables
- Use double quotes in bash to allow variable expansion

## Complete Example: Full Task Workflow

```bash
#!/bin/bash
set -e  # Exit on error

# Configuration
STRIDE_API_URL="https://www.stridelikeaboss.com"
STRIDE_API_TOKEN="stride_dev_xxx"  # placeholder: read yours from .stride_auth.md
AGENT_NAME="Claude Sonnet 4.5"

# Function to execute hook
execute_hook() {
  local hook_data="$1"
  local hook_name=$(echo "$hook_data" | jq -r '.name')
  local hook_timeout=$(echo "$hook_data" | jq -r '.timeout')
  local hook_blocking=$(echo "$hook_data" | jq -r '.blocking')

  echo "Executing hook: $hook_name (timeout: ${hook_timeout}ms, blocking: $hook_blocking)"

  # Set environment variables from hook.env
  local env_vars=$(echo "$hook_data" | jq -r '.env | to_entries[] | "\(.key)=\(.value)"')
  while IFS= read -r var; do
    export "$var"
  done <<< "$env_vars"

  # Read hook command from .stride.md
  # (In practice, parse .stride.md to get command for $hook_name)
  local hook_command=$(get_hook_command "$hook_name")

  # Execute with timeout
  timeout $((hook_timeout/1000)) bash -c "$hook_command"
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Hook $hook_name failed with exit code $exit_code"
    if [ "$hook_blocking" = "true" ]; then
      echo "Blocking hook failed - aborting action"
      exit $exit_code
    else
      echo "Non-blocking hook failed - continuing"
    fi
  fi
}

# 1. Execute before_doing hook FIRST (600s is the timeout the server sends today)
echo "Executing before_doing hook..."
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 600 bash -c 'echo "Starting task..."; git pull origin main' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "ERROR: Hook execution failed - cannot claim task"
  exit 1
fi

# 2. Claim task with hook result (jq builds the JSON safely)
echo "Claiming next task..."
CLAIM_RESPONSE=$(jq -n \
  --arg agent "$AGENT_NAME" \
  --arg out "$OUTPUT" --argjson code "$EXIT_CODE" --argjson dur "$DURATION" \
  '{agent_name: $agent,
    before_doing_result: {exit_code: $code, output: $out, duration_ms: $dur}}' |
  curl -s -X POST \
    -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    "$STRIDE_API_URL/api/tasks/claim")

# 3. Get task identifier
TASK_IDENTIFIER=$(echo "$CLAIM_RESPONSE" | jq -r '.data.identifier')
echo "Working on task: $TASK_IDENTIFIER"

# 4. Do the work
# ... your task implementation here ...

# 5. Execute after_doing hook FIRST
echo "Executing after_doing hook..."
START_TIME_1=$(date +%s%3N)
OUTPUT_1=$(timeout 600 bash -c 'mix test && mix credo --strict' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(date +%s%3N)
DURATION_1=$((END_TIME_1 - START_TIME_1))

if [ $EXIT_CODE_1 -ne 0 ]; then
  echo "ERROR: Tests failed - cannot complete task"
  exit 1
fi

# 6. Execute before_review hook SECOND
echo "Executing before_review hook..."
START_TIME_2=$(date +%s%3N)
OUTPUT_2=$(timeout 600 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(date +%s%3N)
DURATION_2=$((END_TIME_2 - START_TIME_2))

if [ $EXIT_CODE_2 -ne 0 ]; then
  echo "ERROR: PR creation failed - cannot complete task"
  exit 1
fi

# 7. Complete the task with BOTH hook results and the other required fields
echo "Completing task..."
COMPLETE_RESPONSE=$(jq -n \
  --arg agent "$AGENT_NAME" \
  --arg out1 "$OUTPUT_1" --argjson code1 "$EXIT_CODE_1" --argjson dur1 "$DURATION_1" \
  --arg out2 "$OUTPUT_2" --argjson code2 "$EXIT_CODE_2" --argjson dur2 "$DURATION_2" \
  '{agent_name: $agent,
    completion_summary: "Added refresh-token rotation to the session controller.",
    actual_complexity: "medium",
    actual_files_changed: "lib/my_app/auth.ex, test/my_app/auth_test.exs",
    time_spent_minutes: 45,
    completion_notes: "All tests passing, PR created",
    after_doing_result: {exit_code: $code1, output: $out1, duration_ms: $dur1},
    before_review_result: {exit_code: $code2, output: $out2, duration_ms: $dur2},
    explorer_result: {dispatched: false, reason: "self_reported_exploration",
      summary: "Read the key files and their tests inline; the change follows the existing context pattern."},
    reviewer_result: {dispatched: false, reason: "self_reported_review",
      summary: "Re-read the diff against every acceptance criterion and pitfall; no issues found."}}' |
  curl -s -X PATCH \
    -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    "$STRIDE_API_URL/api/tasks/$TASK_IDENTIFIER/complete")

# 8. Run the hooks the response still needs: after_review is in the list only
#    when needs_review=false, and after_goal only when this task finished its
#    goal. after_doing and before_review are in the list too, but already ran.
for HOOK in after_review after_goal; do
  HOOK_DATA=$(echo "$COMPLETE_RESPONSE" | jq -c --arg n "$HOOK" '.hooks[]? | select(.name == $n)')
  if [ -n "$HOOK_DATA" ]; then
    execute_hook "$HOOK_DATA"
    # For after_goal, also report the result to PATCH /api/tasks/:id/after_goal,
    # where :id is the goal (see "The after_goal Hook" above)
  fi
done

# 9. Check if task needs review
NEEDS_REVIEW=$(echo "$COMPLETE_RESPONSE" | jq -r '.data.needs_review')
if [ "$NEEDS_REVIEW" = "false" ]; then
  echo "✓ Task completed and moved to Done"
  echo "Claiming next task..."
  # Loop back to step 1
else
  echo "✓ Task completed and moved to Review"
  echo "Waiting for human review..."
fi
```

## Automatic Hook Execution via Claude Code Hooks (Stride Plugin v1.5.0)

Starting with Stride Plugin v1.5.0, Claude Code users can have `.stride.md` hooks execute **automatically without permission prompts**. This is an alternative to the manual agent-executed approach described above.

### The Problem

When agents execute hook commands through Claude's Bash tool, the CLI's permission system prompts the user for every command — `git pull`, `mix test`, `mix credo`, `git commit`, etc. This happens regardless of CLAUDE.md instructions because the prompting occurs in the CLI harness, not in the LLM.

### The Solution

The Stride plugin ships Claude Code hooks (`hooks/hooks.json` and `hooks/stride-hook.sh`) that detect Stride API calls in Bash tool commands and automatically execute the corresponding `.stride.md` section as a shell process on the harness. No tool call means no permission prompt.

### How It Works

The plugin registers PreToolUse and PostToolUse hooks on Bash commands. When a Stride API call is detected, the `stride-hook.sh` script:

1. Reads the Bash command from the Claude Code hook JSON input
2. Determines which `.stride.md` section to execute based on the API endpoint
3. Parses that section with `awk` and executes each uncommented command
4. Exits 2 on failure to block the tool call (in PreToolUse context)

**Hook routing:**

| Claude Code Event | API Pattern | Stride Hook |
|---|---|---|
| PostToolUse (Bash) | `/api/tasks/claim` | `before_doing` |
| PreToolUse (Bash) | `/api/tasks/:id/complete` | `after_doing` (blocks completion on failure) |
| PostToolUse (Bash) | `/api/tasks/:id/complete` | `before_review` |
| PostToolUse (Bash) | `/api/tasks/:id/mark_reviewed` | `after_review` |

### Environment Variables

When the `before_doing` hook runs after a successful claim, the script extracts task metadata from the API response and caches it to `.stride-env-cache`. All subsequent hooks load this cache, so commands in `.stride.md` can reference `$TASK_IDENTIFIER`, `$TASK_TITLE`, `$TASK_ID`, `$TASK_STATUS`, `$TASK_COMPLEXITY`, and `$TASK_PRIORITY`.

The cache is cleaned up automatically after the `after_review` hook completes. Add `.stride-env-cache` to your `.gitignore`.

### Structured JSON Diagnostics

On failure, the script emits structured JSON to stdout:

```json
{
  "hook": "after_doing",
  "status": "failed",
  "failed_command": "mix test --cover",
  "command_index": 0,
  "exit_code": 1,
  "stdout": "...",
  "stderr": "...",
  "commands_completed": [],
  "commands_remaining": ["mix credo --strict", "mix sobelow --config"]
}
```

On success, a summary is emitted:

```json
{
  "hook": "after_doing",
  "status": "success",
  "commands_completed": ["mix test --cover", "mix credo --strict"],
  "duration_seconds": 45
}
```

The `stride:hook-diagnostician` agent accepts both this structured JSON format and the raw text output from the manual execution approach described earlier in this guide.

### Setup

Install or update the Stride plugin:

```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

Or update an existing installation:

```
/plugin update stride
```

The hooks activate automatically when the plugin is enabled. No changes to your `.claude/settings.json` are needed.

### Comparing the Two Approaches

| Aspect | Manual (Agent-Executed) | Automatic (Claude Code Hooks) |
|---|---|---|
| Permission prompts | Yes, per command | None |
| Visibility | Each command as a tool call | Command output on stderr |
| Failure diagnosis | Agent sees full output | Structured JSON + diagnostician |
| Environment variables | Agent sets via `export` | Cached from API response |
| Blocking semantics | Agent decides to proceed or not | PreToolUse exit 2 blocks deterministically |
| Platform support | All platforms | Claude Code only |

The automatic approach is recommended for Claude Code users. Other platforms (Copilot, Gemini CLI, Cursor, etc.) should continue using the manual agent-executed approach documented above.

## Automatic Hook Execution via OpenCode Plugin

OpenCode users can install the `stride-opencode` npm plugin, which provides automatic hook execution similar to Claude Code hooks but implemented as a native TypeScript plugin.

**How it works:**

The plugin subscribes to OpenCode's `tool.execute.before` and `tool.execute.after` events:

| OpenCode Event | API Pattern | Stride Hook |
|---|---|---|
| `tool.execute.after` | `/api/tasks/claim` | `before_doing` |
| `tool.execute.before` | `/api/tasks/:id/complete` | `after_doing` (blocks completion on failure) |
| `tool.execute.after` | `/api/tasks/:id/complete` | `before_review` |
| `tool.execute.after` | `/api/tasks/:id/mark_reviewed` | `after_review` |

**Installation:**

Add to `opencode.json`:
```json
{
  "plugin": ["github:cheezy/stride-opencode"]
}
```

**Advantages over shell-based hooks:**
- Cross-platform (macOS, Linux, Windows) without separate shell scripts
- Native JSON parsing (no `jq` dependency)
- Environment variable caching from claim responses
- Structured error reporting on hook failures

See [stride-opencode](https://github.com/cheezy/stride-opencode) for details.

## Manual Hook Execution for Codex CLI

Codex CLI has no automatic hook interception system. The agent must execute `.stride.md` hooks directly via shell commands. The `stride-codex` skills are specifically adapted for this — they instruct the agent to:

1. Read the corresponding `## section` from `.stride.md`
2. Execute each command one at a time via shell
3. Never prompt for permission — hooks are pre-authorized
4. Stop on first failure and fix before proceeding

Install the Codex skills:
```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash
```

See [stride-codex](https://github.com/cheezy/stride-codex) for details.

## Related: Completion Validation (G65)

**Hooks and completion validation are separate systems.** This guide covers hook execution (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`) — commands that run on your machine and whose results are submitted to the server. Besides the two hook results, `/complete` also requires `completion_summary`, `actual_complexity`, `actual_files_changed` and `time_spent_minutes`, plus the `explorer_result` and `reviewer_result` fields. Those two report on exploration and review work your agent did (via subagent dispatch or inline) — they are not derived from any hook. `workflow_steps` is optional, but its shape is checked when you send it. The `after_goal` result is not part of `/complete` at all: it goes to [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md).

Completing a task with valid hook results but a missing `explorer_result` or `reviewer_result` returns HTTP `422` wherever `:strict_completion_validation` is on, which is the default in production; elsewhere it logs a warning and succeeds. In every mode, a malformed `explorer_result`, `reviewer_result` or `workflow_steps` is rejected with `422`, and so is a dispatched `reviewer_result` that does not carry the full report in [completion-contract.md](completion-contract.md).

- [PATCH /api/tasks/:id/complete — Completion Validation Format (G65)](api/patch_tasks_id_complete.md#completion-validation-format-g65) — full field specification, shapes, enum values
- [AI Workflow Guide — Completion Validation](AI-WORKFLOW.md#completion-validation) — workflow integration

## See Also

- [API Documentation](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md) - Complete API reference
- [AI Workflow Guide](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md) - Agent workflow patterns
- [Task Writing Guide](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md) - How to write effective tasks
