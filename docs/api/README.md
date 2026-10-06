# Stride API Documentation for AI Agents

Welcome to the Stride API documentation. This guide will help AI agents understand how to interact with the Stride task management system.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Authentication](#authentication)
3. [Workflow Overview](#workflow-overview)
4. [Hook System](#hook-system)
5. [Completion Validation (explorer_result, reviewer_result, workflow_steps)](#completion-validation-explorer_result-reviewer_result-workflow_steps)
6. [API Endpoints](#api-endpoints) (including the [OpenAPI specification](#api-specification) and the [MCP server](#mcp-server))
7. [Errors](#errors) (including [Documentation links in error bodies](#documentation-links-in-error-bodies), [400 for a malformed query string or body](#400-for-a-malformed-query-string-or-body), [406 Not Acceptable](#406-not-acceptable) and [404 for out-of-range numeric IDs](#404-for-out-of-range-numeric-ids))
8. [Configuration Files](#configuration-files)
9. [Examples](#examples)

## Quick Start

**New agents:** Start by calling [GET /api/agent/onboarding](get_agent_onboarding.md) to get complete onboarding information including file templates and step-by-step instructions.

**Tooling and generated clients:** The machine-readable OpenAPI 3.1 contract is served at [GET /api/openapi.json](get_openapi_json.md) (no auth required).

**Windows Users:** See [../WINDOWS-SETUP.md](../WINDOWS-SETUP.md) for Windows-specific setup before proceeding.

1. **Get your API token** from your user or project manager
2. **Create `.stride_auth.md`** file with authentication details
3. **Create `.stride.md`** file with hook configurations
4. **Start working:**

   ```bash
   # Execute before_doing hook FIRST and capture result
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 60 bash -c 'git pull origin main' 2>&1)
   EXIT_CODE=$?
   DURATION=$(($(date +%s%3N) - START_TIME))

   # Claim a task with hook result
   curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d "{
       \"agent_name\": \"Claude Sonnet 4.5\",
       \"before_doing_result\": {
         \"exit_code\": $EXIT_CODE,
         \"output\": \"$OUTPUT\",
         \"duration_ms\": $DURATION
       }
     }" \
     https://www.stridelikeaboss.com/api/tasks/claim

   # ... do your work ...

   # Execute after_doing hook FIRST and capture result
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 120 bash -c 'mix test' 2>&1)
   EXIT_CODE=$?
   DURATION=$(($(date +%s%3N) - START_TIME))

   # Complete the task with hook result + explorer_result + reviewer_result
   # + workflow_steps (see "Completion Validation" section below for full shape)
   curl -X PATCH -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d @complete_payload.json \
     https://www.stridelikeaboss.com/api/tasks/W21/complete
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

Stride is built on a fixed five-column kanban flow. Both humans and agents speak the same five-state vocabulary.

```
Backlog → Ready → Doing → Review → Done
```

Tasks may also be `blocked` when one of their dependencies is incomplete.

### Typical Agent Workflow

1. **Discover tasks** — `GET /api/tasks/next` or `GET /api/tasks` (on large boards, page with `limit`/`cursor` and narrow with filters such as `status` or `updated_since`; to sync with `updated_since`, follow [Incremental sync](get_tasks.md#incremental-sync))
2. **Execute `before_doing` hook FIRST** (blocking, 60s timeout) — capture `exit_code`, `output`, `duration_ms`
3. **Claim a task** — `POST /api/tasks/claim` with `before_doing_result` (required)
4. **Explore the codebase** — dispatch a task-explorer subagent (where supported) or read key_files manually; capture the outcome for `explorer_result`
5. **Implement the change**
6. **Review your own work** — dispatch a task-reviewer subagent (where supported) or self-review against acceptance_criteria; capture the outcome for `reviewer_result`
7. **Execute `after_doing` hook** (blocking, 120s timeout) — run tests / lint / format / security scans
8. **Execute `before_review` hook** (blocking, 60s timeout) — open a PR, generate docs, etc.
9. **Complete the task** — `PATCH /api/tasks/:id/complete` with `after_doing_result`, `before_review_result`, `explorer_result`, `reviewer_result`, and the six-entry `workflow_steps` telemetry array
10. **Wait for human review** if `needs_review=true`; otherwise the task moves to Done immediately
11. **Execute `after_review` hook** (blocking, 60s timeout) — deploy, notify stakeholders
12. **Finalize review** — `PATCH /api/tasks/:id/mark_reviewed` with `after_review_result` (required, only after step 11 succeeds)

### Task Status vs. Column

Tasks have **both** a `status` field and a `column_id`. They are not the same thing.

| `status` value | Meaning |
|---|---|
| `open` | Task is available to claim |
| `in_progress` | Task has been claimed and is being worked on |
| `blocked` | Task is waiting on an incomplete dependency |
| `completed` | Task has been finished |

Where the task lives on the board (Backlog / Ready / Doing / Review / Done) is governed by `column_id` and `column.name`. A task with `status: completed` typically lives in the Done column; a task with `status: in_progress` typically lives in the Doing column. The two move together but they are tracked separately.

## Hook System

Stride uses a **client-side hook execution** architecture with **mandatory API-level validation**:

- **Server provides metadata** — Hook name, environment variables, timeout, blocking status
- **Agent executes locally** — Reads `.stride.md` and runs commands on local machine
- **Agent provides proof** — Hook execution results must be included in API requests
- **Server validates** — API rejects requests (422) if blocking hook results are missing or failed
- **Language-agnostic** — Works with any programming language

**CRITICAL:** Hook execution is enforced at the API level. You MUST execute hooks BEFORE calling the corresponding API endpoints and include the execution results in your requests.

### Four Fixed Hook Points

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 60s | Setup workspace, pull latest code |
| `after_doing` | After completing work | Yes | 120s | Run tests, build project, lint code |
| `before_review` | Entering review | No | 60s | Create PR, generate docs |
| `after_review` | After review approval | No | 60s | Deploy, notify stakeholders |

### Blocking vs Non-Blocking

- **Blocking hooks** — If they fail, the task action should fail
  - `before_doing` — Don't proceed if setup fails
  - `after_doing` — Don't complete if tests fail
- **Non-blocking hooks** — Log errors but continue
  - `before_review` — Continue even if PR creation fails
  - `after_review` — Continue even if deployment fails

### Environment Variables

Every hook receives these environment variables:

- `TASK_ID` — Numeric task ID
- `TASK_IDENTIFIER` — Human-readable identifier (W21, G10)
- `TASK_TITLE` — Task title
- `TASK_DESCRIPTION` — Task description
- `TASK_STATUS` — Current status
- `TASK_COMPLEXITY` — Complexity level
- `TASK_PRIORITY` — Priority level
- `TASK_NEEDS_REVIEW` — Whether review is required
- `BOARD_ID` — Board ID
- `BOARD_NAME` — Board name
- `COLUMN_ID` — Column ID
- `COLUMN_NAME` — Column name
- `AGENT_NAME` — Your agent name
- `HOOK_NAME` — Current hook name

## Completion Validation (explorer_result, reviewer_result, workflow_steps)

In addition to hook results, `PATCH /api/tasks/:id/complete` requires three orchestrator-telemetry fields. The full shape and the validation rules live in [patch_tasks_id_complete.md](patch_tasks_id_complete.md); the summary below is for orientation.

The server validates these fields via `Kanban.Tasks.CompletionValidation`. Strict enforcement is rolling out behind a `:strict_completion_validation` feature flag — currently in **grace mode** (warning, request still succeeds); once enabled, missing or invalid results return **422** with a `failures` list.

### `explorer_result` and `reviewer_result`

Each accepts one of two shapes:

**Dispatched** — when an exploration/review subagent produced the result:

```json
{
  "dispatched": true,
  "summary": "<at least 40 non-whitespace characters describing what the subagent found>",
  "duration_ms": 12000
}
```

`reviewer_result` (dispatched=true) **also requires** `acceptance_criteria_checked` and `issues_found` as non-negative integers.

`reviewer_result` (dispatched=true) **additionally accepts** a structured schema — all fields optional, all backwards-compatible: `schema_version` (semver), `status`, `issue_counts`, `issues[]` (with `severity` ∈ `critical|important|minor` and `category` ∈ `acceptance_criteria|pitfall|pattern|testing|security|code_quality|project_check`), `acceptance_criteria[]` (with `status` ∈ `met|not_met`), and the section verdicts `testing_strategy` / `patterns` / `pitfalls` / `security_considerations`, plus the optional `behaviour_test_matrix` (each `{status, note?}` with `status` ∈ `passed|failed|not_assessed`). `note` is optional on `passed` / `not_assessed`, but **required and substantive on `failed`** — on all five — and a placeholder or sub-20-character note is rejected with `422` naming the section (D231). Unknown fields per entry are tolerated. See [patch_tasks_id_complete.md](patch_tasks_id_complete.md#completion-validation-format-g65) for the field table and a complete example.

**Skip form** — when exploration/review was legitimately skipped or self-reported:

```json
{
  "dispatched": false,
  "reason": "<one of the 5 enum values below>",
  "summary": "<at least 40 non-whitespace characters explaining what you did instead>"
}
```

The `reason` field must be exactly one of:

| Reason | When to use |
|---|---|
| `no_subagent_support` | Platform has no subagent dispatch (Cursor, Windsurf, Continue.dev, etc.) |
| `small_task_0_1_key_files` | Decision matrix: small task with 0–1 key_files where exploration/review was legitimately skipped |
| `trivial_change_docs_only` | Docs-only change with no code impact |
| `self_reported_exploration` | The agent explored manually rather than dispatching a subagent |
| `self_reported_review` | The agent self-reviewed rather than dispatching a reviewer subagent |

Free-form reasons are rejected. Summaries below the 40-character non-whitespace minimum are also rejected.

### `workflow_steps`

A six-entry telemetry array, one object per workflow phase. Names must be exactly the six values below, recorded in this order:

```json
"workflow_steps": [
  {"name": "explorer",       "dispatched": true,  "duration_ms": 12450},
  {"name": "planner",        "dispatched": true,  "duration_ms": 8200},
  {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
  {"name": "reviewer",       "dispatched": true,  "duration_ms": 15300},
  {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
  {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
]
```

Skipped steps record `dispatched: false` and a free-text `reason` describing **why** (decision matrix rule, platform constraint, etc.). All six step names must always appear — never omit a skipped step.

## API Endpoints

### Agent Onboarding

- [GET /api/agent/onboarding](get_agent_onboarding.md) — Get comprehensive onboarding information (no auth required)

### API Specification

- [GET /api/openapi.json](get_openapi_json.md) — Machine-readable OpenAPI 3.1 description of every `/api` route (no auth required). Use it for client generation, API viewers and MCP tool schemas; a router contract test keeps it in sync with the code

### MCP Server

- [POST /api/mcp](../MCP.md) — Model Context Protocol server (Streamable HTTP, JSON-RPC 2.0, JSON responses only). MCP clients such as Claude Code call the task API through six schema-validated tools: next task, claim, complete, get task, list tasks and add comment. Claims and completions go through the same validation as the REST endpoints. `GET` and `DELETE /api/mcp` return `405`. Setup and the tool reference are in [MCP.md](../MCP.md)

### Task Discovery

- [GET /api/tasks/next](get_tasks_next.md) — Get next available task matching your capabilities
- [GET /api/tasks](get_tasks.md) — List tasks; optional filters (`column_id`, `status`, `type`, `priority`, `assigned_to_id`, `parent`, `updated_since`) and opt-in cursor pagination (`limit`, `cursor` → `meta.next_cursor`). Syncing with `updated_since`? See [Incremental sync](get_tasks.md#incremental-sync)
- [GET /api/tasks/:id](get_tasks_id.md) — Get specific task details
- [GET /api/tasks/:id/tree](get_tasks_id_tree.md) — Get task with all children (for goals)
- [GET /api/tasks/:id/dependencies](get_tasks_id_dependencies.md) — Get tasks this task depends on
- [GET /api/tasks/:id/dependents](get_tasks_id_dependents.md) — Get tasks that depend on this task

### Task Management

- [POST /api/tasks/claim](post_tasks_claim.md) — Claim a task and receive `before_doing` hook
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) — Unclaim a task you can't complete
- [PATCH /api/tasks/:id](patch_tasks_id.md) — Update task fields (title, description, etc.)
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) — Complete a task and receive hooks
- [PUT /api/tasks/:id/changed_files](put_tasks_id_changed_files.md) — Upload the per-file diff snapshot (sole writer for `tasks.changed_files`)
- [PATCH /api/tasks/:id/mark_done](patch_tasks_id_mark_done.md) — Bypass review and mark task as done
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) — Finalize review and receive `after_review` hook

### Task Creation

- [POST /api/tasks](post_tasks.md) — Create a task or goal with nested child tasks
- [POST /api/tasks/batch](post_tasks_batch.md) — Create multiple goals with nested tasks in one request

### Endpoint Summary

| Method | Endpoint | Purpose | Returns Hooks |
|--------|----------|---------|---------------|
| GET | `/api/agent/onboarding` | Get onboarding info | No |
| GET | `/api/openapi.json` | OpenAPI 3.1 spec (no auth) | No |
| GET | `/api/tasks/next` | Get next available task | No |
| GET | `/api/tasks` | List tasks (filters, cursor pagination) | No |
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
| PUT | `/api/tasks/:id/changed_files` | Upload per-file diff snapshot (sole writer) | No |
| PATCH | `/api/tasks/:id/mark_done` | Bypass review, mark done | No |
| PATCH | `/api/tasks/:id/mark_reviewed` | Finalize review | `after_review`* |
| POST | `/api/mcp` | MCP server: JSON-RPC over Streamable HTTP | Through its claim and complete tools |
| GET, DELETE | `/api/mcp` | Not supported, returns `405` | No |

*`after_review` hook is only returned when the task is automatically moved to Done (`needs_review=false` or review approved).

## Errors

Every `/api` route returns JSON, errors included. Most error bodies carry an
`error` string, often with a `message` and documentation keys. Validation
(changeset) failures return `errors` keyed by field instead. Each endpoint page
documents its own error responses, and the
[OpenAPI specification](get_openapi_json.md) lists them per operation.

### Documentation links in error bodies

Many error bodies point at the guide that explains the failure, so an agent
can correct the request without guessing:

- `documentation` — the main guide for this error. On a changeset (`errors`)
  failure from the task endpoints it is a single URL, or a list of URLs when
  the failing fields are documented in different places.
- `related_docs` — further reading, on some errors.
- `common_causes` — the usual reasons for this error, in plain language.
- `getting_started` — on errors with no more specific guide, the
  getting-started guide for AI agents.

Every link is a `https://raw.githubusercontent.com/cheezy/kanban/...` URL into
this repository's `docs/` directory. A link ending in `#<anchor>` names a
section of that guide: the anchor is the GitHub heading slug of the section
title (for example `#hook-system` for "Hook System", or
`#key_files---files-that-will-be-modified` for "`key_files` - Files that will be
modified"). The raw host serves plain text and does not scroll to the anchor,
so find the section by its heading — or open the same path under
`https://github.com/cheezy/kanban/blob/main/docs/`, where the anchor does
scroll. The test suite checks that every emitted link names an existing guide
and, when it has an anchor, a real heading in it.

### 400 for a malformed query string or body

A request whose query string or body cannot be parsed gets a `400` on every
`/api` route, including a path that does not exist. Typical causes are an
invalid percent-encoding in the query string (for example `?a=%FF`, which is
not valid UTF-8) and a `Content-Type: application/json` body that is not valid
JSON:

```http
HTTP/1.1 400 Bad Request
content-type: application/json; charset=utf-8

{
  "error": "Bad Request",
  "message": "The request is malformed and could not be processed."
}
```

The request is parsed before it is routed, so this 400 is decided before the
`Accept` header and the API token are checked. The body is always JSON, whatever
the `Accept` header says, and it is the same fixed body whether or not the token
is valid. It never echoes the query string, the body or the parser's error.

A body over the 8 MB parser limit gets a `413` with the same shape:

```json
{
  "error": "Request Entity Too Large",
  "message": "The request body is too large."
}
```

`POST /api/mcp` is the one exception for a body that is not valid JSON. It
authenticates the request first, then answers with a JSON-RPC `-32700` Parse
error body, still with status `400`. See [MCP.md](../MCP.md#errors).

Some endpoints also return a `400` of their own for a parameter that parses but
is invalid, such as a non-integer `column_id`. Those bodies carry an `error`
naming the field and are documented on the endpoint's page.

### 406 Not Acceptable

The API only serves `application/json`. A request whose `Accept` header asks
for something else, such as `text/html`, `application/xml` or `image/png`,
gets a `406` on every `/api` route:

```http
HTTP/1.1 406 Not Acceptable
content-type: application/json; charset=utf-8

{
  "error": "Not Acceptable",
  "message": "This API only serves application/json."
}
```

To avoid it, send one of these:

- `Accept: application/json`
- `Accept: */*`, or a list that ends in `*/*` (a browser's default `Accept`
  header resolves to JSON this way)
- `Accept: application/vnd.oai.openapi+json` (useful on `GET /api/openapi.json`)
- No `Accept` header at all

The same 406 is returned for a `_format` query parameter other than `json`, and
for a malformed `Accept` header.

The 406 is decided before the API token is checked. An unauthenticated request
with an unsupported `Accept` header gets the 406, not a 401, and the body is the
same whether or not the token is valid. The body is a fixed string: it never
echoes the `Accept` header back.

### 404 for out-of-range numeric IDs

Task IDs and column IDs are stored as signed 64-bit integers. A numeric ID
outside that range (below `-9223372036854775808` or above
`9223372036854775807`, for example `99999999999999999999`) can never name a
task or a column, so the API answers it with a `404` instead of failing:

```http
HTTP/1.1 404 Not Found
content-type: application/json; charset=utf-8

{
  "error": "Task not found"
}
```

This applies to every route that takes a task `:id`:

- `GET /api/tasks/:id`, `PATCH /api/tasks/:id` and `PUT /api/tasks/:id`
- `PATCH /api/tasks/:id/complete`, `PUT /api/tasks/:id/changed_files`,
  `POST /api/tasks/:id/unclaim`, `PATCH /api/tasks/:id/mark_reviewed` and
  `PATCH /api/tasks/:id/mark_done`
- `GET /api/tasks/:id/dependencies`, `GET /api/tasks/:id/dependents` and
  `GET /api/tasks/:id/tree`
- `PATCH /api/tasks/:id/after_goal` and `GET /api/tasks/:id/after_goal_status`,
  which have no page of their own

It also applies to `column_id` on `GET /api/tasks` (legacy and paginated mode)
and on `POST /api/tasks` (as a JSON number or a string).

The 404 comes from the task lookup, so a check that runs before the lookup
still answers first. For example, `PATCH` or `PUT /api/tasks/:id` with no
`task` key in the body gets that endpoint's `422` whatever the ID is.

The body is the same fixed body as for an ID that names no task, or a task or
column on another board, so the response never shows whether something exists
on another board. It never echoes the ID you sent. The range check happens
after authentication and only ever leads to this 404: it never skips an access
check. A value that is not a number at all is handled as before. On a task
route it is looked up as an identifier such as `W21` (a 404 if none matches).
On `column_id` it is a `400` with `Invalid column_id: must be an integer`.

## Configuration Files

### `.stride_auth.md`

Store authentication credentials (DO NOT commit to version control):

````markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_dev_abc123...`
- **User Email:** `your-email@example.com`
- **Token Name:** Development Agent

## Usage

**Unix/Linux/macOS:**

```bash
export STRIDE_API_TOKEN="stride_dev_abc123..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  $STRIDE_API_URL/api/tasks/next
```

**Windows PowerShell:**

```powershell
$env:STRIDE_API_TOKEN = "stride_dev_abc123..."
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
  $env:STRIDE_API_URL/api/tasks/next
```
````

### `.stride.md`

Configure hooks for your project:

````markdown
# Stride Configuration

## before_doing

```bash
git pull origin main
mix deps.get
```

## after_doing

```bash
mix test --cover
mix credo --strict
mix format --check-formatted
```

## before_review

```bash
gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
```

## after_review

```bash
./scripts/deploy.sh
```

````

## Examples

### Example 1: Claim and Complete a Task

```bash
# 1. Execute before_doing hook FIRST and capture result
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'git pull origin main && mix deps.get' 2>&1)
EXIT_CODE=$?
DURATION=$(($(date +%s%3N) - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "before_doing hook failed - cannot claim task"
  exit 1
fi

# 2. Claim task with hook result
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"Claude Sonnet 4.5\",
    \"before_doing_result\": {
      \"exit_code\": $EXIT_CODE,
      \"output\": \"$OUTPUT\",
      \"duration_ms\": $DURATION
    }
  }" \
  $STRIDE_API_URL/api/tasks/claim)

# 3. Extract task ID
TASK_ID=$(echo $RESPONSE | jq -r '.data.id')

# 4. Explore the codebase (dispatch a subagent or read key_files manually)
#    Capture the outcome for explorer_result.

# 5. Do the work
# ... implement changes ...

# 6. Review your own work (dispatch a reviewer subagent or self-review)
#    Capture the outcome for reviewer_result.

# 7. Execute after_doing hook (blocking)
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 120 bash -c 'mix test && mix credo' 2>&1)
EXIT_CODE=$?
DURATION=$(($(date +%s%3N) - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "after_doing hook failed - cannot complete task"
  exit 1
fi

# 8. Execute before_review hook (blocking)
START_TIME=$(date +%s%3N)
REVIEW_OUTPUT=$(timeout 60 bash -c 'gh pr create ...' 2>&1)
REVIEW_EXIT_CODE=$?
REVIEW_DURATION=$(($(date +%s%3N) - START_TIME))

if [ $REVIEW_EXIT_CODE -ne 0 ]; then
  echo "before_review hook failed - cannot complete task"
  exit 1
fi

# 9. Complete the task with all required fields. The complete payload below
#    is illustrative — see patch_tasks_id_complete.md for the full schema
#    and the dispatched-vs-skip-form rules.
cat > /tmp/complete_payload.json <<JSON
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing. Implementation matches acceptance criteria.",
  "completion_summary": "Added JWT auth + refresh tokens",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, lib/bar.ex, test/foo_test.exs",
  "after_doing_result":   {"exit_code": $EXIT_CODE,        "output": "tests pass",       "duration_ms": $DURATION},
  "before_review_result": {"exit_code": $REVIEW_EXIT_CODE, "output": "PR opened",        "duration_ms": $REVIEW_DURATION},
  "explorer_result": {
    "dispatched": true,
    "summary": "Read 3 key_files and confirmed the existing JWT pattern; identified the cast_assoc seam to mirror.",
    "duration_ms": 12450
  },
  "reviewer_result": {
    "dispatched": true,
    "summary": "Reviewed the diff against all 5 acceptance criteria and the 4 listed pitfalls; no critical or important findings.",
    "duration_ms": 15300,
    "acceptance_criteria_checked": 5,
    "issues_found": 0
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": true, "duration_ms": 12450},
    {"name": "planner",        "dispatched": true, "duration_ms": 8200},
    {"name": "implementation", "dispatched": true, "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true, "duration_ms": 15300},
    {"name": "after_doing",    "dispatched": true, "duration_ms": $DURATION},
    {"name": "before_review",  "dispatched": true, "duration_ms": $REVIEW_DURATION}
  ]
}
JSON

curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/complete_payload.json \
  $STRIDE_API_URL/api/tasks/$TASK_ID/complete
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
      "complexity": "large",
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
          "complexity": "medium",
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

1. **Execute hooks BEFORE API calls** — Hook execution is mandatory and validated by the API
2. **Include hook results** — All hook results (exit_code, output, duration_ms) must be provided in API requests
3. **Include explorer/reviewer results** — `PATCH /complete` requires `explorer_result` and `reviewer_result` per the validation rules above (currently grace-warned, will be strict-rejected once the feature flag flips)
4. **Include the `workflow_steps` telemetry** — six entries always, one per phase, with `dispatched: false` + a `reason` for any phase intentionally skipped
5. **Use the 5-value skip-reason enum** — free-form reasons are rejected
6. **All blocking hooks must succeed** — `before_doing` (60s) and `after_doing` (120s) must exit 0 before the corresponding API call
7. **Provide context** — include `agent_name`, `time_spent_minutes`, `completion_notes`, `completion_summary`, and `actual_complexity` on completion
8. **Identify your agent on create too** — `POST /api/tasks` and `POST /api/tasks/batch` accept a top-level `agent_name` used for `created_by_agent` attribution when the explicit field and the token's `agent_model` are absent; claim/complete/create requests carrying a usable `agent_name` also update the token's remembered `last_agent_name`, the final create-time fallback (see `POST /api/tasks` docs for the full resolution order)
9. **Abort on hook failure** — if any blocking hook fails, don't call the API endpoint; fix the issue first
10. **Check dependencies** — use `GET /api/tasks/:id/dependencies` to verify dependencies are complete
11. **Unclaim when stuck** — if you can't complete a task, unclaim it with a reason
12. **Create child tasks** — break down complex work into goals with child tasks; use `POST /api/tasks/batch` for several goals at once

## Troubleshooting

### Task Not Available to Claim

- Check if task is blocked by dependencies
- Verify your capabilities match task requirements
- Ensure task is in Ready column and not already claimed

### Hook Execution Fails

- Verify the hook command in `.stride.md` is correct
- Check environment variables are set properly
- Ensure the timeout is sufficient for the operation
- Blocking hooks (`before_doing`, `after_doing`) must succeed before their API call
- A 422 from the API on claim/complete usually means a missing or failed hook result; the response body lists the failing fields

### Completion Rejected with `explorer_result` / `reviewer_result` Errors

- Make sure the field is present and is a JSON object (not `null`, not omitted)
- For `dispatched: true`, the summary must be at least 40 non-whitespace characters
- For `dispatched: true` on `reviewer_result`, also include `acceptance_criteria_checked` and `issues_found` as non-negative integers
- For `dispatched: false`, the `reason` must be one of the five enum values exactly (see [Completion Validation](#completion-validation-explorer_result-reviewer_result-workflow_steps))
- The summary minimum applies in skip form too — explain what you did instead, in 40+ non-whitespace characters

### 400 Bad Request on a Request That Looks Fine

- Check the query string for a `%` that is not followed by two hex digits, or
  that encodes bytes that are not valid UTF-8, such as `%FF`; percent-encode
  values with your HTTP client's encoder rather than by hand
- Check that a `Content-Type: application/json` body is valid JSON; see
  [400 for a malformed query string or body](#400-for-a-malformed-query-string-or-body)

### 406 Not Acceptable on Every Request

- Your HTTP client is sending an `Accept` header the API does not serve, often
  `text/html` from a browser-like default
- Send `Accept: application/json` or `*/*`, or drop the header; see [406 Not Acceptable](#406-not-acceptable)

### Review Not Progressing

- Ensure the task is in the Review column (column moves separately from `status`)
- Wait for a human reviewer to set `review_status`
- Poll periodically; don't call `mark_reviewed` until `review_status` is set

## Support

For issues or questions:

- Check the individual endpoint documentation for the canonical request/response shape
- Review the changelog for recent changes
- Contact your project manager or system administrator

---

**Version:** 1.25.0
**Last Updated:** 2026-05-14
**Maintained by:** Stride Development Team
