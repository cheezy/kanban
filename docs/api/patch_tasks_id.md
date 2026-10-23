# PATCH /api/tasks/:id

Update an existing task's descriptive and planning fields — title, description, priority, and the full planning context.

**This endpoint does not write workflow state.** Status and the claim fields belong to `/claim`, the completion record to `/complete`, and the review record to a human reviewing in the board UI; a few more fields are set at creation and never afterwards. Naming any of them here **rejects the whole request with 422** and changes nothing — see [Fields this endpoint will not change](#fields-this-endpoint-will-not-change).

> **Changed:** these fields were previously accepted and then silently dropped, so a request to correct a completion record returned `200 OK` with the record unchanged. It now fails loudly instead. If you have a client that sends them expecting them to be ignored, remove them from the body — the editable fields in the same request are no longer applied either.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PATCH
**Endpoint:** `/api/tasks/:id`
**Content-Type:** application/json

`PUT /api/tasks/:id` is routed to the same action. It takes the same body and returns the same responses.

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range (below -9223372036854775808 or above 9223372036854775807) returns 404, the same as an ID that names no task. |

### Request Body Parameters

All parameters are optional. Only include the fields you want to update.

#### Basic Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `title` | string | Task title |
| `description` | string | Detailed task description |
| `acceptance_criteria` | string | Acceptance criteria for task completion |
| `type` | string | Task type: `work`, `defect`, or `goal`. A task that belongs to a goal cannot be changed to `goal`, because goals are never nested; that returns 422 with `errors.type` |
| `priority` | string | Priority: `low`, `medium`, `high`, `critical` |
| `needs_review` | boolean | Whether task requires human review before completion |

#### Planning & Context Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `complexity` | string | Estimated complexity: `small`, `medium`, `large` |
| `estimated_files` | string | Estimated number of files (e.g., "3-5") |
| `why` | string | Why - problem/rationale for the task |
| `what` | string | What - implementation approach |
| `where_context` | string | Where - code location/context |

#### Implementation Guidance Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `patterns_to_follow` | string | Code patterns to follow |
| `database_changes` | string | Database/schema changes needed |
| `validation_rules` | string | Validation rules to implement |

#### Observability Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `telemetry_event` | string | Telemetry event name (e.g., "[:kanban, :domain, :action]"). Stored only on a board in an Organization; see [Warnings](#warnings) |
| `metrics_to_track` | string | Metrics to track. Stored only on a board in an Organization; see [Warnings](#warnings) |
| `logging_requirements` | string | Logging requirements |

#### Error Handling Fields

| Parameter | Type | Description |
|-----------|------|-------------|
| `error_user_message` | string | User-facing error message |
| `error_on_failure` | string | What happens on failure |

#### Collections (Arrays)

| Parameter | Type | Description |
|-----------|------|-------------|
| `dependencies` | array of strings | Task identifiers that must be completed first (e.g., ["W15", "W16"]) |
| `technology_requirements` | array of strings | Required technologies/libraries |
| `pitfalls` | array of strings | Common pitfalls to avoid |
| `out_of_scope` | array of strings | Items explicitly out of scope |
| `security_considerations` | array of strings | Security considerations. An entry shaped like a real credential that the task does not already store returns 422 and nothing changes (see [Unprocessable Entity (422)](#unprocessable-entity-422)) |
| `required_capabilities` | array of strings | Required agent capabilities |
| `labels` | array of strings | Label **names** on this board. Replaces the task's labels; `[]` clears them; omitting the field leaves them unchanged. An unknown name returns 422 and nothing changes (see [Labels](#labels)) |

#### Embedded Collections

| Parameter | Type | Description |
|-----------|------|-------------|
| `key_files` | array of objects | Key files to read first. Each object has `file_path`, `note`, and `position` |
| `verification_steps` | array of objects | Verification steps. Each object has `step_type`, `step_text`, `expected_result`, and `position` |

#### Maps/Objects

| Parameter | Type | Description |
|-----------|------|-------------|
| `testing_strategy` | object | Testing strategy (JSON object). **CRITICAL**: `unit_tests`, `integration_tests`, and `manual_tests` **must be arrays of strings**. Other optional keys can be strings or arrays: `property_tests`, `coverage_target`, `test_data`, `mocking`, `edge_cases`, `performance_tests`, `regression_tests`, `security_tests`. See [POST /api/tasks](post_tasks.md#testing-strategy-format) for format details. |
| `integration_points` | object | Integration points (JSON object) with optional keys: `telemetry_events`, `pubsub_broadcasts`, `phoenix_channels`, `external_apis`. **All values must be arrays of strings**. |

### Fields this endpoint will not change

Naming any field below returns **422** and applies **nothing** — not the rejected field, and not the editable fields sent alongside it. The response names every offending field (see [Forbidden field (422)](#forbidden-field-422)).

These fields are not unwritable; they are written **somewhere else**. Use the endpoint that owns each one.

| Field | Written by |
|-------|-----------|
| `status` | The workflow endpoints — claiming, completing and reviewing move it |
| `assigned_to_id`, `claimed_at`, `claim_expires_at` | [`POST /api/tasks/claim`](post_tasks_claim.md) and [`POST /api/tasks/:id/unclaim`](post_tasks_id_unclaim.md) |
| `completed_at`, `completed_by_id`, `completed_by_agent`, `completion_summary`, `completion_notes`, `actual_complexity`, `actual_files_changed`, `time_spent_minutes`, `workflow_steps`, `explorer_result`, `reviewer_result`, `review_report` | [`PATCH /api/tasks/:id/complete`](patch_tasks_id_complete.md). `review_report` is submitted **with the completion**, despite its name — it is not written by `mark_reviewed` |
| `review_status`, `review_notes` | The review **verdict**, recorded by a human reviewing in the board UI. No API route sets it: [`mark_reviewed`](patch_tasks_id_mark_reviewed.md) *reads* `review_status` and errors when it has not been set |
| `review_requested_at` | Stamped by the server each time the task enters the Review column — when it is created straight into Review, by a completion that sends it to Review, or by a move into Review on the board. No caller sets it |
| `reviewed_at`, `reviewed_by_id` | Review **attribution**, stamped by the server when a review is recorded — by [`mark_reviewed`](patch_tasks_id_mark_reviewed.md) and by the board UI review form |
| `changed_files` | [`PUT /api/tasks/:id/changed_files`](put_tasks_id_changed_files.md), its sole writer |
| `after_goal_status`, `after_goal_result`, `after_goal_attempts` | [`PATCH /api/tasks/:id/after_goal`](patch_tasks_id_after_goal.md) |
| `archive_reason`, `archive_note`, `archived_by_id` | The archive action |
| `target_id`, `duplicate_of_id` | Set in the board UI |
| `identifier`, `parent_id`, `created_by_id`, `created_by_agent` | Set at creation and never changed. A task **cannot be reparented** — ask a human to move it in the board UI |
| `position` | Board placement — set when a task is created or moved |
| `column_id` | Board placement. This one does **not** return 422: sending the task's **current** `column_id` is accepted as a no-op, and sending a different one returns **403** (see [Column changes](#column-changes)) |
| `archived_at` | The archive action |

### Request Body Example

#### Update basic fields

```json
{
  "task": {
    "title": "Implement JWT authentication",
    "description": "Add JWT token-based authentication to the API endpoints",
    "priority": "high",
    "needs_review": true
  }
}
```

#### Replace a task's labels

```json
{
  "task": {
    "labels": ["Bug", "backend"]
  }
}
```

Send `"labels": []` to remove every label. A body carrying only `labels` is a
valid update and returns 200.

#### Update with planning context

```json
{
  "task": {
    "title": "Implement user registration",
    "complexity": "medium",
    "estimated_files": "4-6",
    "why": "Users need to create accounts to access the platform",
    "what": "Create registration form, API endpoint, and email verification flow",
    "where_context": "lib/kanban_web/controllers/auth/, lib/kanban/accounts/",
    "dependencies": ["W15"],
    "technology_requirements": ["bcrypt", "swoosh"],
    "key_files": [
      {
        "file_path": "lib/kanban/accounts/user.ex",
        "note": "User schema and validation",
        "position": 0
      },
      {
        "file_path": "lib/kanban/accounts.ex",
        "note": "Account context functions",
        "position": 1
      }
    ]
  }
}
```

#### Rejected: assignment and status

Both fields belong to the claim endpoint, so this request returns 422 and changes nothing:

```json
{
  "task": {
    "assigned_to_id": 5,
    "status": "in_progress"
  }
}
```

Use [`POST /api/tasks/claim`](post_tasks_claim.md) instead.

#### Rejected: completion metrics

These are written by the completion endpoint, so this request returns 422:

```json
{
  "task": {
    "actual_complexity": "large",
    "actual_files_changed": "8",
    "time_spent_minutes": 120,
    "completion_summary": "Implemented authentication with JWT tokens and refresh token flow"
  }
}
```

Send them in the body of [`PATCH /api/tasks/:id/complete`](patch_tasks_id_complete.md). **There is no way to correct them afterwards through this endpoint.**

Get them right the first time. Once a task is completed, the correction path depends on the field:

| Field | Correcting it afterwards |
|-------|--------------------------|
| `completion_summary`, `actual_complexity`, `actual_files_changed`, `time_spent_minutes` | Editable by a human in the board UI task form |
| `completion_notes` | **No correction path exists today.** It is rendered read-only in the board UI and has no form input, so once written it cannot be changed through any interface |

## Response

### Success (200 OK)

Returns the updated task with all fields:

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement JWT authentication",
    "description": "Add JWT token-based authentication to the API endpoints",
    "acceptance_criteria": "Users can login, logout, and refresh tokens",
    "status": "in_progress",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "work",
    "column_id": 6,
    "created_by_id": 1,
    "created_by_agent": null,
    "assigned_to_id": 5,
    "parent_id": null,
    "why": "Users need secure authentication",
    "what": "JWT-based auth with refresh tokens",
    "where_context": "lib/kanban_web/controllers/auth/",
    "dependencies": ["W15"],
    "technology_requirements": ["joken", "bcrypt"],
    "required_capabilities": ["code_generation"],
    "time_spent_minutes": null,
    "completion_summary": null,
    "actual_complexity": null,
    "actual_files_changed": null,
    "review_status": null,
    "review_notes": null,
    "review_report": null,
    "inserted_at": "2025-12-28T10:00:00Z",
    "updated_at": "2025-12-28T11:30:00Z",
    "completed_at": null
  },
  "current_skills_version": "1.0"
}
```

### Warnings

When paid plans are enforced and the board is not in an Organization's
workspace, `telemetry_event` and `metrics_to_track` are accepted but not
stored, and the 200 response adds a top-level `warnings` list naming them.
Values stored before are left unchanged. The other fields in the request are
still applied, and a request without those two fields gets no `warnings` key.
`PATCH /api/tasks/:id/complete` never stores these fields, so it ignores them
on every board.

```json
{
  "data": { "id": 123, "identifier": "W22", "title": "Add metrics dashboard" },
  "warnings": [
    "telemetry_event, metrics_to_track need a board in an Organization and were not stored."
  ],
  "current_skills_version": "1.0"
}
```

### Forbidden (403)

The token's user does not have owner or modify access to the board. This is
checked before the task is looked up, so nothing changes and the response does
not say whether the task exists:

```json
{
  "error": "Not authorized — board write access (owner or modify) required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

The body sent a `column_id` that differs from the task's current column. This
endpoint cannot move a task, and nothing changes (see
[Column Changes](#column-changes)):

```json
{
  "error": "Agents cannot move tasks between columns via update. Use the workflow endpoints (claim, complete, mark_reviewed, mark_done) to transition tasks.",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

A task on another board is never a 403. It gets the same 404 as a task that
does not exist (see [Not Found (404)](#not-found-404)).

### Forbidden field (422)

The request named one or more fields this endpoint will not change. **Nothing was applied** — including any editable fields in the same request. Every offending field is listed:

```json
{
  "error": "task update rejected",
  "failures": [
    {
      "field": "task",
      "errors": [
        {
          "field": "status",
          "message": "status cannot be changed via PATCH /api/tasks/:id — it is written by the claim and complete workflow endpoints. The request was rejected in full and no field was changed."
        },
        {
          "field": "identifier",
          "message": "identifier cannot be changed via PATCH /api/tasks/:id — it is server-managed; it is set at creation or by a dedicated action. The request was rejected in full and no field was changed."
        }
      ]
    }
  ],
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/patch_tasks_id.md",
  "common_causes": ["..."]
}
```

To recover, re-send the request with the rejected fields removed.

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

An unknown label name, or a `labels` value that is not an array of 1 to 40
character names. The labels are checked before the update is applied, so
**nothing changes** — not the labels, and not any other field in the same
request:

```json
{
  "errors": {
    "labels": ["unknown labels: \"Nope\""]
  }
}
```

A `security_considerations` entry shaped like a real credential, such as a
Stride API token, a GitHub or AWS key or a private key header. The error names
the entry by its 1-based position and never echoes the value, and **nothing
changes**:

```json
{
  "errors": {
    "security_considerations": ["entry 2 looks like it contains a credential; remove the secret value and describe the risk in words"]
  }
}
```

Only entries the request introduces are checked. A task written before this
check existed may already store a credential-shaped entry; a PATCH of any other
field, a request that sends the list back unchanged, and a request that keeps
that entry while appending new ones all still succeed. Remove the stored entry
by sending the list without it. The formats checked, and the prose that passes,
are listed under
[Security Considerations Format](post_tasks.md#security-considerations-format).

### Not Found (404)

Task not found:

```json
{
  "error": "Task not found"
}
```

A numeric ID outside the signed 64-bit range, such as `9223372036854775808`, gets
this same 404 and body. It is never a 500, and it cannot be told apart from an ID
that names no task or a task on another board. See
[404 for out-of-range numeric IDs](README.md#404-for-out-of-range-numeric-ids).

## Behavior Notes

### Priority Changes
When `priority` is updated, a task history record is automatically created tracking the change from old to new priority.

### Assignment Changes
This endpoint does not assign tasks — `assigned_to_id` is rejected. Assignment happens through [`POST /api/tasks/claim`](post_tasks_claim.md) and [`POST /api/tasks/:id/unclaim`](post_tasks_id_unclaim.md).

Note that **no task-history record is written for an API assignment.** The assignment history entry is produced only by an in-app (board UI) update; the claim path sets `assigned_to_id` in a single atomic statement and records nothing in the task's history.

### Dependency Updates
When `dependencies` array is updated:
- The task's blocking status is automatically recalculated
- If all dependencies are completed, task status changes from `blocked` to `open`
- If task has incomplete dependencies, status changes to `blocked`
- Every identifier must name a task on the task's board. An identifier with no
  task there (including one that exists only on another board) is refused with
  422 `dependencies: ["lists tasks that are not on this board: W900"]`, and the
  task is left unchanged
- Dependent tasks cannot be deleted while they are listed as dependencies

### Labels
`labels` sets the task's labels by **name**, matched case-insensitively against
the labels of the token's board (surrounding whitespace ignored; duplicates and
case variants attach a label once):
- Present, it **replaces** the task's whole set of labels.
- An empty array, `[]`, **clears** them. `null` is rejected.
- Omitted, the task's labels are **left unchanged**, whatever else the request
  updates.
- Every name is resolved before anything is written. An unknown name — including
  one that exists only on another board, which is reported in the same words —
  returns 422 and the task is not changed at all.
- Labels are never created here; manage them in the board settings.
- The response's `data.labels` lists the result as `{name, color}`, ordered by
  name ignoring case.

The [forbidden-field refusal](#forbidden-field-422) still runs first: a request
that also names a field this endpoint will not change is rejected as a whole, so
its `labels` are not applied either.

### Column Changes
This endpoint cannot move a task between columns. Sending a `column_id` that differs from the task's current column returns **403**; sending the task's current `column_id` is accepted as a no-op.

That no-op applies to `column_id` alone. **A client that echoes a whole task body back is still rejected**, because such a body also carries `status`, `identifier`, `created_by_id`, `position` and the completion fields — all of which now return 422. Send only the fields you intend to change.

Use the workflow endpoints (`claim`, `complete`, `mark_reviewed`, `mark_done`) to transition a task, or move it by hand in the board UI.

## Example Usage

### Update task title and priority

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Implement JWT authentication",
      "priority": "critical"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

### Add dependencies

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "dependencies": ["W15", "W16"]
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

### Update planning context

```bash
curl -X PATCH \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "complexity": "large",
      "why": "Users need secure authentication to access protected resources",
      "what": "Implement JWT-based authentication with access and refresh tokens",
      "where_context": "lib/kanban_web/controllers/auth/, lib/kanban/accounts/"
    }
  }' \
  https://www.stridelikeaboss.com/api/tasks/W21
```

## Use Cases

- **Update task details**: Modify title, description, or acceptance criteria
- **Change priority**: Adjust task priority based on business needs
- **Add planning context**: Add implementation guidance and context for AI agents
- **Track dependencies**: Define which tasks must be completed first
- **Add technical details**: Specify technology requirements, patterns, security considerations

Not use cases for this endpoint: assigning, moving between columns, recording completion metrics, or approving a review. Each has its own endpoint, and attempting them here fails.

## Workflow Integration

This endpoint is commonly used in these workflows:

1. **Task refinement**: Add detailed planning context before starting work
2. **Priority adjustments**: Respond to changing business priorities
3. **Dependency management**: Update task dependencies as project evolves
4. **Review feedback**: Refine a task's planning fields in response to review notes. The verdict itself is not yours to write — a human records it in the board UI, and [`mark_reviewed`](patch_tasks_id_mark_reviewed.md) then acts on it

## Notes

- You can update any combination of **editable** fields in a single request
- Only include fields you want to change in the request body
- A request naming any field from [Fields this endpoint will not change](#fields-this-endpoint-will-not-change) is rejected in full — the editable fields in that request are not applied either
- Task must belong to the board associated with your API token
- Changing `priority` creates a task history entry
- Changing `dependencies` automatically updates blocking status
- Use numeric ID or identifier (W21, G10, etc.) in the URL
- Empty arrays (`[]`) will clear existing array values
- Setting a field to `null` will clear that field's value
- This endpoint does NOT trigger workflow hooks (use specific endpoints like `/complete` for that)

## See Also

- [GET /api/tasks/:id](get_tasks_id.md) - Get task details
- [POST /api/tasks](post_tasks.md) - Create a new task
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Complete a task (triggers hooks)
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task
- [GET /api/tasks](get_tasks.md) - List tasks (filters, cursor pagination)
