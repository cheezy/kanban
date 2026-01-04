# Agent Hook Execution Guide

This guide explains how AI agents should execute workflow hooks when working with Stride tasks.

## Overview

Stride uses a **client-side hook execution** architecture where:
- **Server provides metadata** - Hook name, environment variables, timeout, blocking status
- **Agent executes locally** - Reads `.stride.md` and runs commands on local machine
- **Language-agnostic** - Works with any programming language or tooling

This design allows agents to integrate with git workflows, run quality checks, and perform setup/cleanup tasks automatically.

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

```markdown
# Stride Configuration

## before_doing

Executes before starting work on a task (blocking, 60s timeout).

```bash
echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
git pull origin main
```

## after_doing

Executes after completing work (blocking, 120s timeout).
If this fails, task completion should fail.

```bash
echo "Running tests for $TASK_IDENTIFIER"
mix test
mix credo --strict
```

## before_review

Executes when task enters review (non-blocking, 60s timeout).

```bash
echo "Creating PR for $TASK_IDENTIFIER"
gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
```

## after_review

Executes after review approval (non-blocking, 60s timeout).

```bash
echo "Task $TASK_IDENTIFIER complete"
```
```

### 2. Commit `.stride.md` to Version Control

This file should be committed so all agents and developers can see the configured hooks.

## Four Fixed Hook Points

Stride defines exactly four hook points in the task lifecycle:

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 60s | Pull latest code, setup workspace |
| `after_doing` | After completing work | Yes | 120s | Run tests, build project, lint code |
| `before_review` | Entering review | No | 60s | Create PR, generate documentation |
| `after_review` | After review approval | No | 60s | Merge PR, deploy to production |

### Blocking vs Non-Blocking

**Blocking Hooks** (`before_*`):
- If hook fails, the task action is aborted
- Task remains in previous state
- Error returned to agent
- Example: If `after_doing` tests fail, task completion is blocked

**Non-Blocking Hooks** (`after_*`):
- If hook fails, action still completes
- Error logged but workflow continues
- Example: If `before_review` PR creation fails, task still moves to review

## Hook Execution Workflow

### Example: Claiming and Completing a Task

```bash
# 1. Claim a task
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "Claude Sonnet 4.5"}' \
  $STRIDE_API_URL/api/tasks/claim)

# 2. Extract task details and hook metadata
TASK_ID=$(echo $RESPONSE | jq -r '.data.id')
TASK_IDENTIFIER=$(echo $RESPONSE | jq -r '.data.identifier')
TASK_TITLE=$(echo $RESPONSE | jq -r '.data.title')

# 3. Check if before_doing hook is provided
HOOK=$(echo $RESPONSE | jq -r '.hook')
if [ "$HOOK" != "null" ]; then
  HOOK_NAME=$(echo $HOOK | jq -r '.name')
  HOOK_TIMEOUT=$(echo $HOOK | jq -r '.timeout')

  # 4. Set environment variables from hook metadata
  export TASK_ID=$TASK_ID
  export TASK_IDENTIFIER=$TASK_IDENTIFIER
  export TASK_TITLE="$TASK_TITLE"
  # ... set other variables from hook.env

  # 5. Execute hook from .stride.md
  timeout $((HOOK_TIMEOUT/1000)) bash -c '
    git pull origin main
  '

  # 6. Check hook execution result
  if [ $? -ne 0 ]; then
    echo "Hook execution failed"
    exit 1
  fi
fi

# 7. Do your work on the task
# ... implement changes ...

# 8. Complete the task
COMPLETE_RESPONSE=$(curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "Claude Sonnet 4.5",
    "time_spent_minutes": 45,
    "completion_notes": "All tests passing"
  }' \
  $STRIDE_API_URL/api/tasks/$TASK_IDENTIFIER/complete)

# 9. Execute hooks returned from completion
HOOKS=$(echo $COMPLETE_RESPONSE | jq -r '.hooks[]')
# Execute after_doing (blocking), before_review (non-blocking), after_review (if provided)
```

## Environment Variables

All hooks receive these environment variables:

### Task Information
- `TASK_ID` - Numeric task ID (e.g., `42`)
- `TASK_IDENTIFIER` - Human-readable identifier (e.g., `W21`, `G10`)
- `TASK_TITLE` - Task title
- `TASK_DESCRIPTION` - Task description
- `TASK_STATUS` - Current status (`open`, `in_progress`, `review`, `completed`)
- `TASK_COMPLEXITY` - Complexity level (`trivial`, `low`, `medium`, `high`, `very_high`)
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

## after_review
```bash
# Merge PR and clean up
gh pr merge --auto --squash
git checkout main
git pull origin main
git branch -d "task-$TASK_IDENTIFIER-*"
```
```

### Quality Gate Enforcement

```markdown
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
```

### Environment Setup and Cleanup

```markdown
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
```

## Error Handling

### Handling Blocking Hook Failures

**Unix/Linux/macOS/WSL2:**

```bash
# Execute after_doing hook (blocking)
timeout 120 bash -c 'mix test'
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
$completed = Wait-Job $job -Timeout 120

if (-not $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Error "ERROR: Tests timed out after 120 seconds"
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

### Handling Non-Blocking Hook Failures

**Unix/Linux/macOS/WSL2:**

```bash
# Execute before_review hook (non-blocking)
timeout 60 bash -c 'gh pr create --title "$TASK_TITLE"' || {
  echo "WARNING: PR creation failed, but task moved to review"
  echo "Create PR manually"
}

# Continue with workflow even if hook failed
echo "Task moved to Review column"
```

**Windows PowerShell:**

```powershell
# Execute before_review hook (non-blocking) with timeout
$job = Start-Job -ScriptBlock { gh pr create --title "$env:TASK_TITLE" }
$completed = Wait-Job $job -Timeout 60

if (-not $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Warning "WARNING: PR creation timed out, but task moved to review"
    Write-Warning "Create PR manually"
} elseif ($LASTEXITCODE -ne 0) {
    Write-Warning "WARNING: PR creation failed, but task moved to review"
    Write-Warning "Create PR manually"
}

if ($job) { Remove-Job $job -ErrorAction SilentlyContinue }

# Continue with workflow even if hook failed
Write-Host "Task moved to Review column"
```

### Timeout Handling

All hooks have timeouts to prevent hanging:

```bash
# Use timeout command to enforce hook timeout
HOOK_TIMEOUT=60  # seconds

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

Use the timeout values from hook metadata. Different hooks have different timeout requirements.

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
- For blocking hooks, fix the issue before proceeding
- For non-blocking hooks, log the error and continue

### Commands Not Found

**Problem:** `mix: command not found` or similar errors

**Solution:**
- Ensure required tools are installed
- Check PATH environment variable includes tool locations
- Use absolute paths if necessary: `/usr/local/bin/mix test`

### Timeout Too Short

**Problem:** Hook times out before completing

**Solution:**
- Long-running operations may need longer timeouts
- `after_doing` defaults to 120s for running tests
- If consistently timing out, optimize the hook commands or request timeout increase

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
STRIDE_API_TOKEN="your_token_here"
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

# 1. Claim task
echo "Claiming next task..."
CLAIM_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"agent_name\": \"$AGENT_NAME\"}" \
  "$STRIDE_API_URL/api/tasks/claim")

# 2. Execute before_doing hook
HOOK=$(echo "$CLAIM_RESPONSE" | jq -r '.hook')
if [ "$HOOK" != "null" ]; then
  execute_hook "$HOOK"
fi

# 3. Get task identifier
TASK_IDENTIFIER=$(echo "$CLAIM_RESPONSE" | jq -r '.data.identifier')
echo "Working on task: $TASK_IDENTIFIER"

# 4. Do the work
# ... your task implementation here ...

# 5. Complete the task
echo "Completing task..."
COMPLETE_RESPONSE=$(curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"$AGENT_NAME\",
    \"time_spent_minutes\": 45,
    \"completion_notes\": \"All tests passing\"
  }" \
  "$STRIDE_API_URL/api/tasks/$TASK_IDENTIFIER/complete")

# 6. Execute hooks from completion response
HOOKS=$(echo "$COMPLETE_RESPONSE" | jq -c '.hooks[]')
while IFS= read -r hook; do
  execute_hook "$hook"
done <<< "$HOOKS"

# 7. Check if task needs review
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

## See Also

- [API Documentation](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md) - Complete API reference
- [AI Workflow Guide](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md) - Agent workflow patterns
- [Task Writing Guide](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md) - How to write effective tasks
