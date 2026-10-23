# PATCH /api/tasks/:id/complete

Mark a task as complete. This moves the task to the Review column (or directly to Done if `needs_review=false`).

> **Note on `changed_files`.** The per-file diff snapshot is no longer written by this endpoint. As of W778, `changed_files` is owned exclusively by [`PUT /api/tasks/:id/changed_files`](put_tasks_id_changed_files.md) — the hook uploads it before this completion request fires. If you send `changed_files` in the completion body it is **silently ignored** at the schema cast layer (the request still 422s if the shape is malformed, via `CompletionResultGate`, but the field is dropped). New plugins should upload via the PUT endpoint and omit `changed_files` from the completion body. See the [Diff Contract](../diff-contract.md) for encoding rules.

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
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., "W21"). A numeric ID outside the signed 64-bit range (below -9223372036854775808 or above 9223372036854775807) returns 404, the same as an ID that names no task. |

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `after_doing_result` | object | **Yes** | Result of executing the `after_doing` hook. Must include `exit_code`, `output`, and `duration_ms`. |
| `before_review_result` | object | **Yes** | Result of executing the `before_review` hook. Must include `exit_code`, `output`, and `duration_ms`. |
| `explorer_result` | object | **Yes** | Exploration outcome — dispatched-subagent shape or self-reported skip-form. A present but malformed value is rejected with `422` in every mode; an absent one is rejected in strict mode (the production default) and only warned in grace mode. See [Completion Validation Format (G65)](#completion-validation-format-g65) below. |
| `reviewer_result` | object | **Yes** | Review outcome — same two shapes as `explorer_result`. The dispatched shape also requires `acceptance_criteria_checked`, `issues_found` and the **full structured block** (`schema_version`, `status` or `issue_counts`, `issues[]`, `acceptance_criteria[]`, `project_checks[]`, `testing_strategy`, `patterns`, `pitfalls`, `security_considerations`). A dispatched result without that block, or any present but malformed value, is rejected with `422` in every mode. Only an absent one, and the two consistency checks listed under **Validation modes** below, follow the strict-validation setting. See [Completion Validation Format (G65)](#completion-validation-format-g65) below and [completion-contract.md](../completion-contract.md). |
| `workflow_steps` | array | Recommended (telemetry) | Six-entry telemetry array, one object per workflow phase. Cast onto the task struct for aggregation. See [Completion Validation Format (G65)](#completion-validation-format-g65) below. |
| `agent_name` | string | No | Name of the agent completing the task (e.g., "Claude Sonnet 4.5"). Defaults to "Unknown". |
| `time_spent_minutes` | integer | **Yes** | Time spent on the task in minutes |
| `completion_notes` | string | No | Long-form completion narrative, distinct from the one-line `completion_summary`. Persisted on the task, returned by this endpoint and by `GET /api/tasks/:id`, and rendered on the Review queue — this is the channel for findings a human must read. Omitting it leaves any previously stored value unchanged. Bounded at 65535 characters. Redact credentials before writing: the value is durable and shown to humans, and the server raises a security audit event (without logging the value) when it looks credential-bearing. |
| `completion_summary` | string | **Yes** | JSON-encoded summary of changes made |
| `actual_complexity` | string | **Yes** | Actual complexity experienced ("small", "medium", "large") |
| `actual_files_changed` | string | **Yes** | Actual number of files changed |
| `review_report` | string | No | Structured review report from task-reviewer agent (persisted on the task for traceability) |

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

### Completion Validation Format (G65)

`explorer_result` and `reviewer_result` are server-validated by `Kanban.Tasks.CompletionValidation`. Each accepts two shapes.

**Dispatched shape** — use when an exploration/review subagent produced the result (e.g. Claude Code with `stride:task-explorer`):

```json
"explorer_result": {
  "dispatched": true,
  "summary": "<at least 40 non-whitespace characters>",
  "duration_ms": 12000
}
```

A dispatched `explorer_result` needs only `summary` and `duration_ms`. A dispatched `reviewer_result` needs much more: `summary`, `duration_ms`, `acceptance_criteria_checked` and `issues_found` (non-negative integers), **and the full structured block** listed in the table below. This is the smallest `reviewer_result` the server accepts, for a project with no `CODE-REVIEW.md`:

```json
"reviewer_result": {
  "dispatched": true,
  "summary": "Reviewed the diff against both acceptance criteria, the task's pitfalls and its patterns; nothing to fix.",
  "duration_ms": 8000,
  "acceptance_criteria_checked": 2,
  "issues_found": 0,
  "schema_version": "1.5",
  "status": "approved",
  "issue_counts": {"critical": 0, "important": 0, "minor": 0},
  "issues": [],
  "acceptance_criteria": [
    {"criterion": "Validator accepts arrays", "status": "met", "evidence": "test/foo_test.exs:12"},
    {"criterion": "Status enum enforced", "status": "met", "evidence": "test/foo_test.exs:30"}
  ],
  "project_checks": [],
  "testing_strategy": {"status": "passed", "note": "Both listed unit tests are present."},
  "patterns": {"status": "passed"},
  "pitfalls": {"status": "passed"},
  "security_considerations": {"status": "passed", "note": "Board-scoped query; no new input surface."}
}
```

**Structured fields (required on a dispatched review)** — a dispatched `reviewer_result` must carry every section below, in every validation mode. A legacy summary-only payload — `summary`, `duration_ms` and the two counts with no structured block — is **rejected with `422`** whatever the `:strict_completion_validation` setting is; only the skip form leaves the block out. The full rules, including the task cross-field checks, are in [completion-contract.md](../completion-contract.md), and the list of required keys is `@required_review_sections` in `lib/kanban/tasks/completion_validation/review_contract.ex`. The server shape-validates every field and tolerates unknown forward-compatible fields. Your task-reviewer subagent's structured JSON report is the source of these fields (see the `stride-workflow` plugin's `task-reviewer` agent prompt for the canonical schema).

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | string | **Yes** | Permissive semver — `MAJOR.MINOR` (e.g. `"1.0"`), `MAJOR.MINOR.PATCH`, optional pre-release (`-beta.1`) and build (`+build.7`) suffixes. The validator checks shape only; it does not gate on specific values. |
| `status` | string | **Yes**, unless `issue_counts` is sent | Top-level outcome flag (typically `"approved"` or `"changes_requested"`). Not enum-validated server-side — the agent prompt is the source of truth. A dispatched review must carry `status` or `issue_counts`, and may carry both. |
| `issue_counts` | object | **Yes**, unless `status` is sent | Per-severity count — keys mirror the severity enum: `critical`, `important`, `minor`. Missing keys are tolerated. |
| `issues[]` | array of objects | **Yes** (may be `[]`) | Per-finding detail. Each entry must be a map with valid `severity` and `category`. Both enums are required when an entry is present; unknown fields per entry are tolerated. |
| `acceptance_criteria[]` | array of objects | **Yes** | Per-criterion verdict. Each entry must be a map with a valid `status`. The status enum uses underscore form: **`met` / `not_met`** (a space form `"not met"` is rejected). The array needs at least one entry per non-blank line of the task's `acceptance_criteria`. |
| `project_checks[]` | array of objects | **Yes** (may be `[]`) | One verdict per bullet of the calling project's optional root `CODE-REVIEW.md`. The key must be present and must be a list; the list may be any length, and `[]` means the project has no checklist. The server never sees that file, so it never gates on the length. |
| `testing_strategy` | object | **Yes** | Section verdict — `{status, note?}`. Status enum: `passed` / `failed` / `not_assessed`. **`note` is the rendered key (singular)** — the review queue reads only `note`. On `passed` and `not_assessed` it is optional and may be omitted or empty. **On `"failed"` it is REQUIRED** and must name the specific violation in at least 20 non-whitespace characters; an empty string, a bare `placeholder` / `TODO` / `TBD` / `n/a`, padding built from those words, or a note that merely restates the status is rejected with `422`, naming the offending section (D231). A plural `notes` key is still shape-validated for legacy payloads but is **never rendered and never satisfies the failed-verdict requirement**. When the task supplied a `testing_strategy`, this verdict must be `passed` or `failed`, never `not_assessed`. |
| `patterns` | object | **Yes** | Same section-verdict shape as `testing_strategy`. |
| `pitfalls` | object | **Yes** | Same section-verdict shape as `testing_strategy`. |
| `security_considerations` | object | **Yes** | Same section-verdict shape as `testing_strategy`, plus an optional `considerations[]` breakdown (one `{consideration, status, evidence?, note?}` per task consideration). When the task supplied `security_considerations`, this verdict must be `passed` or `failed`, never `not_assessed`. |

Per-entry enums:

| Entry field | Enum values |
|---|---|
| `issues[].severity` | `critical`, `important`, `minor` |
| `issues[].category` | `acceptance_criteria`, `pitfall`, `pattern`, `testing`, `security`, `code_quality`, `project_check` |
| `acceptance_criteria[].status` | `met`, `not_met` |
| `testing_strategy.status`, `patterns.status`, `pitfalls.status`, `security_considerations.status` | `passed`, `failed`, `not_assessed` |
| `security_considerations.considerations[].status` | `mitigated`, `partial`, `unmitigated` |

Optional per-issue fields (all forward-compatible — not server-validated, passed through verbatim): `file`, `line`, `description`, `suggested_fix`. Optional per-criterion fields: `criterion`, `evidence`. Anything not listed above is also persisted as `:jsonb` and survives a round trip through GET — see `task_json.ex` for the verbatim pass-through contract.

Structured `reviewer_result` example for a review that found problems, with a project checklist and a security breakdown:

```json
"reviewer_result": {
  "dispatched": true,
  "summary": "Reviewed against 2 acceptance criteria and 5 pitfalls; one criterion unmet and one pattern deviation surfaced.",
  "duration_ms": 8000,
  "acceptance_criteria_checked": 2,
  "issues_found": 2,
  "schema_version": "1.5",
  "status": "changes_requested",
  "issue_counts": {"critical": 0, "important": 2, "minor": 0},
  "issues": [
    {
      "severity": "important",
      "category": "pattern",
      "file": "lib/kanban/tasks/agent_workflow.ex",
      "line": 528,
      "description": "Cast list omits the new field — payload would be silently dropped.",
      "suggested_fix": "Add the field to the cast/2 list and the changeset validation."
    },
    {
      "severity": "important",
      "category": "acceptance_criteria",
      "file": "test/kanban/tasks_test.exs",
      "description": "No test covers the status enum.",
      "suggested_fix": "Add a case that sends an unknown status and expects a 422."
    }
  ],
  "acceptance_criteria": [
    {"criterion": "Validator accepts arrays", "status": "met", "evidence": "test/foo_test.exs:12"},
    {"criterion": "Status enum enforced", "status": "not_met", "evidence": "See issues[1]"}
  ],
  "project_checks": [
    {
      "check": "Every new public function has a unit test",
      "source": "CODE-REVIEW.md",
      "status": "met",
      "evidence": "test/kanban/tasks_test.exs:88"
    }
  ],
  "testing_strategy": {"status": "passed", "note": "All 5 required test cases present in the new describe block."},
  "patterns": {"status": "failed", "note": "The cast list skips the new field, so the changeset drops it (issues[0])."},
  "pitfalls": {"status": "passed", "note": "None violated."},
  "security_considerations": {
    "status": "passed",
    "note": "Board-scoped query; no new input surface.",
    "considerations": [
      {
        "consideration": "Move query scoped to the requesting user's board",
        "status": "mitigated",
        "evidence": "lib/kanban/tasks.ex:142",
        "note": "Query filters by current_scope.user.id."
      }
    ]
  }
}
```

These two examples are the ones `GET /api/agent/onboarding` serves as `api_schema.reviewer_result_format.example` and `.structured_example`, and the server's own tests run both through the completion gate in strict mode.

**Skip form** — use when exploration/review was skipped or produced inline (for platforms without subagent dispatch, or when the task's decision matrix skipped the step):

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
| `no_subagent_support` | Platform has no subagent dispatch (Cursor, Windsurf, Continue.dev, Kimi Code). Also Codex CLI and OpenCode during graceful fallback. |
| `small_task_0_1_key_files` | Decision matrix: task is small with 0–1 `key_files` and exploration/review was legitimately skipped. |
| `trivial_change_docs_only` | Docs-only change with no code impact; exploration/review provides no value. |
| `self_reported_exploration` | You read `key_files` and analyzed the codebase manually beyond what a bare skip implies. |
| `self_reported_review` | You walked the diff against `acceptance_criteria` and `pitfalls` manually. |

Free-form reasons are rejected — the enum is the contract.

**Minimum summary length:** Summaries must contain at least **40 non-whitespace characters**. Trivial summaries like `"explored files"` or `"reviewed code"` are rejected (the 40-char threshold is counted after stripping all whitespace).

**Validation modes:** Some rules reject with `422` in **every** mode: a dispatched `reviewer_result` without the full structured block, a present but malformed `explorer_result` or `reviewer_result`, and a missing or failing hook result. The `:strict_completion_validation` application flag decides the rest — an **absent** `explorer_result` or `reviewer_result`, a malformed `changed_files` array, and the two consistency checks described in [completion-contract.md](../completion-contract.md#checks-that-follow-the-strict-validation-setting):

- **Strict (the production default):** those failures return `422` with a `failures` list. See [Completion validation failed](#completion-validation-failed) below.
- **Grace (the default in development and test):** those failures log a structured warning and the request succeeds.

The `STRIDE_STRICT_COMPLETION_VALIDATION` environment variable (`true` or `false`) overrides the default (`config/runtime.exs`).

**`workflow_steps`** is a six-entry telemetry array (one object per phase: `explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`). It is cast onto the task struct for aggregation but is not currently rejected when missing. Include it to contribute telemetry. Each entry has `{name, dispatched, duration_ms}` when the step ran, or `{name, dispatched: false, reason}` when it was skipped.

**`workflow_steps[].reason_code`** (optional, D239) — a machine-readable skip category, used only when `dispatched: false`. Supply it **alongside** `reason`, never instead of it: the code is what the compliance dashboard aggregates, and the prose is what a human reads on the task detail page.

| Code | Use when |
|---|---|
| `decision_matrix_skip` | The Step 3 decision matrix says this task's row skips this step. |
| `ran_inline` | The step's work was performed, but in the main loop rather than by a dispatched subagent. |
| `hook_body_empty` | Plugin mode: the `.stride.md` section body is empty, so the hook is a no-op. Only for `after_doing` / `before_review`. |
| `subsumed_by_task_spec` | The task specification itself already settled what this step would have decided. |
| `folded_into_prior_step` | An earlier step already produced this step's output — most often an explorer that returned a complete plan. |
| `matrix_deviation` | The matrix called for this step and it was deliberately not run. Records non-compliance rather than a sanctioned skip — do not use it to dress up a deviation as a matrix skip. |

Unlike the `explorer_result` / `reviewer_result` enum, **omitting `reason_code` is always valid**: payloads written before this field are accepted unchanged, and `reason` remains required-when-skipped and free-form. A `reason_code` outside the list above **is** rejected, so a typo opens no silent bucket.

The vocabulary was derived by classifying the 73 skipped entries persisted on the production board, not invented. `name` is deliberately **not** constrained — persisted data carries a second step vocabulary from another runtime, and rejecting it would `422` that runtime's completions mid-flight.

**Authoritative format reference:** See `GET /api/agent/onboarding` → `api_schema.explorer_result_format`, `reviewer_result_format`, `workflow_steps_format`, and `validation_modes` for the machine-readable contract. Server source of truth: `Kanban.Tasks.CompletionValidation` (`lib/kanban/tasks/completion_validation.ex`) and `Kanban.KanbanWeb.Api.CompletionResultGate` (`lib/kanban_web/controllers/api/completion_result_gate.ex`).

### Request Body Example

```json
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_summary": "Added JWT auth with refresh tokens",
  "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing.",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/my_app/auth.ex, test/my_app/auth_test.exs",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix format --check-formatted\nAll files formatted correctly\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  },
  "explorer_result": {
    "dispatched": true,
    "summary": "Explored lib/my_app/auth.ex and related tests; identified existing JWT helper pattern to reuse",
    "duration_ms": 12000
  },
  "reviewer_result": {
    "dispatched": true,
    "summary": "Reviewed the diff against both acceptance criteria and 3 pitfalls; no issues found",
    "duration_ms": 8000,
    "acceptance_criteria_checked": 2,
    "issues_found": 0,
    "schema_version": "1.5",
    "status": "approved",
    "issue_counts": {"critical": 0, "important": 0, "minor": 0},
    "issues": [],
    "acceptance_criteria": [
      {"criterion": "Access tokens expire after 15 minutes", "status": "met", "evidence": "test/my_app/auth_test.exs:24"},
      {"criterion": "A refresh token issues a new access token", "status": "met", "evidence": "test/my_app/auth_test.exs:51"}
    ],
    "project_checks": [],
    "testing_strategy": {"status": "passed", "note": "The expiry and refresh unit tests are both present."},
    "patterns": {"status": "passed"},
    "pitfalls": {"status": "passed"},
    "security_considerations": {"status": "passed", "note": "Tokens are signed and never logged; no new input surface."}
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": true,  "duration_ms": 12000},
    {"name": "planner",        "dispatched": false, "reason_code": "decision_matrix_skip",
     "reason": "Step 3 matrix row 'small, 2+ key_files' gives Plan = Skip"},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true,  "duration_ms": 8000},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}
```

Example using the self-reported skip form (for platforms without subagent dispatch — Cursor, Windsurf, Continue.dev, Kimi Code — or for small tasks where exploration/review were skipped per the decision matrix):

```json
{
  "explorer_result": {
    "dispatched": false,
    "reason": "no_subagent_support",
    "summary": "Read lib/foo.ex and test/foo_test.exs inline; identified the existing error-tuple pattern to mirror"
  },
  "reviewer_result": {
    "dispatched": false,
    "reason": "self_reported_review",
    "summary": "Walked the diff against all 5 acceptance criteria and 3 pitfalls; confirmed each criterion met"
  }
}
```

## Selecting the response view

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `response_view` | `slim` | absent (full) | `slim` returns a compact acknowledgement instead of echoing the completed task back. Any other value — including `full`, an unrecognised string, or the parameter being absent — returns the unchanged full response. |

Only the exact lowercase string `slim` opts in. `response_view` is accepted
either as a query-string parameter or as a top-level key in the JSON request
body, since Phoenix merges the two into the same params map.

**Why you would want it.** The full response echoes back everything you just
submitted — `reviewer_result` with its whole structured block, including every
`project_checks` entry, plus
`explorer_result`, `review_report`, `workflow_steps` and the completion fields.
That is the largest response in the workflow, and a response that large can
exceed an agent harness's output-truncation threshold, cutting the JSON
mid-string so `after_goal` detection silently fails and the goal-completion
push never fires. The slim view removes that condition at the source. If
you lose the response anyway,
[GET /api/tasks/:id/after_goal_status](get_tasks_id_after_goal_status.md)
answers whether the completion armed `after_goal`, and
[PATCH /api/tasks/:id/after_goal](patch_tasks_id_after_goal.md) takes its
result.

**What still rides along.** `hooks` and the skills-version keys
(`current_skills_version`, and `skills_update_required` when your
`skills_version` is stale) are present under **both** views — the hook contract
is unaffected. `response_view` changes only what is echoed: it never changes
what is validated, what is stored, or the authorization required. Error
responses (403, 404, 422) are identical under both views, because the view is
selected only after the completion succeeds.

### Success (200 OK) — `?response_view=slim`

```json
{
  "data": {
    "id": 2819,
    "identifier": "W777",
    "title": "...",
    "status": "completed",
    "parent_id": 2800,
    "needs_review": false,
    "review_status": null,
    "complexity": "small",
    "priority": "high"
  },
  "hooks": [
    { "name": "after_doing", "timeout": 600000, "blocking": true, "env": { "...": "..." } },
    { "name": "before_review", "timeout": 600000, "blocking": true, "env": { "...": "..." } },
    { "name": "after_review", "timeout": 600000, "blocking": true, "env": { "...": "..." } }
  ],
  "current_skills_version": "1.0"
}
```

The full record — including `reviewer_result`, `explorer_result`,
`review_report` and `workflow_steps` — remains readable via
`GET /api/tasks/:id`.

## Response

### Success (200 OK)

Returns the completed task and hook metadata. The hooks list depends on the task's `needs_review` setting (`Kanban.Hooks.Metadata.build_completion_hooks/4` in `lib/kanban/hooks/metadata.ex`):

**If `needs_review=true`** (task goes to Review column):

- Returns `[after_doing, before_review]`. Both were already executed and validated before this request; nothing in this list still needs to run.
- Never includes `after_review` or `after_goal`. Once a human approves the task, run the `## after_review` section first, then call [`PATCH /api/tasks/:id/mark_reviewed`](patch_tasks_id_mark_reviewed.md) with its `after_review_result` (see [AI-WORKFLOW.md](../AI-WORKFLOW.md) steps 9 and 10). The `after_goal` hook, when this task was the last open child of a goal, arrives on that `mark_reviewed` response. If the human approved from the Review queue, the task is already in Done and `mark_reviewed` returns `422`; see [When a Human Approves from the Review Queue](../REVIEW-WORKFLOW.md#when-a-human-approves-from-the-review-queue).

**If `needs_review=false`** (task goes directly to Done):

- Returns `[after_doing, before_review, after_review]`. `after_doing` and `before_review` were already executed; `after_review` still needs execution.
- Appends a fourth entry, `after_goal`, when this task was the last open child of a goal. Run the `## after_goal` section and report its result with [`PATCH /api/tasks/:id/after_goal`](patch_tasks_id_after_goal.md).

The example below is a `needs_review=true` response.

```json
{
  "data": {
    "id": 123,
    "identifier": "W21",
    "title": "Implement authentication",
    "description": "Add JWT authentication to the API",
    "status": "in_progress",
    "priority": "high",
    "complexity": "medium",
    "needs_review": true,
    "type": "work",
    "column_id": 7,
    "assigned_to_id": 5,
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
        "TASK_STATUS": "in_progress",
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
      "timeout": 600000,
      "blocking": true
    },
    {
      "name": "before_review",
      "env": {
        "TASK_ID": "123",
        "TASK_IDENTIFIER": "W21",
        "TASK_TITLE": "Implement authentication",
        "TASK_STATUS": "in_progress",
        "AGENT_NAME": "Claude Sonnet 4.5",
        "HOOK_NAME": "before_review"
      },
      "timeout": 600000,
      "blocking": true
    }
  ],
  "current_skills_version": "1.0"
}
```

### Forbidden (403)

The token's user no longer has owner or modify access to the board:

```json
{
  "error": "Not authorized — board write access (owner or modify) required",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
  "getting_started": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
}
```

This is checked before the task is looked up, so the response is the same
whether the task exists and whatever state it is in.

Trying to complete a task assigned to someone else, with write access:

```json
{
  "error": "You can only complete tasks that you are assigned to"
}
```

### Not Found (404)

No task on the token's board matches the ID or identifier. A task on another
board gets the same response:

```json
{
  "error": "Task not found"
}
```

A numeric ID outside the signed 64-bit range, such as `9223372036854775808`, gets
this same 404 and body. It is never a 500, and it cannot be told apart from an ID
that names no task or a task on another board. See
[404 for out-of-range numeric IDs](README.md#404-for-out-of-range-numeric-ids).

### Unprocessable Entity (422)

Hook validation failed (missing or invalid `after_doing_result`):

```json
{
  "error": "after_doing hook result is required",
  "hook": "after_doing",
  "documentation": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md",
  "related_docs": [
    "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#hook-system"
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

#### Completion validation failed

`explorer_result` or `reviewer_result` failed validation — for example, a dispatched `reviewer_result` sent without `project_checks`. A dispatched review that is missing a required section gets this body in every mode; an absent result and the two consistency checks get it in strict mode only (see **Validation modes** above). A present but malformed `explorer_result` or `reviewer_result` that strict mode would catch here is refused in grace mode by the task changeset instead, with the `{"errors": ..., "documentation": ...}` validation-error body.

```json
{
  "error": "completion validation failed",
  "failures": [
    {
      "field": "reviewer_result",
      "errors": [
        {
          "field": "project_checks",
          "message": "is required on a dispatched review: the structured project_checks field the review queue renders is missing"
        }
      ]
    }
  ],
  "required_format": { "...": "..." },
  "documentation": "...",
  "related_docs": [ "..." ],
  "common_causes": [ "..." ]
}
```

Values shown as `"..."` are elided. `required_format` holds one accepted payload each for `explorer_result`, a dispatched `reviewer_result` with every required section, the skip form, and `changed_files`; `documentation`, `related_docs` and `common_causes` point at the docs that explain the failure.

## Workflow

**CRITICAL: Hook execution is mandatory!** Follow this workflow:

1. **Complete the work** - Implement all required changes

2. **Execute the `after_doing` hook FIRST** (blocking, 600s timeout)
   - This hook typically runs tests, builds, or quality checks
   - Example: Run test suite, build project, run linters
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

3. **Execute the `before_review` hook SECOND** (blocking, 600s timeout)
   - This hook typically creates PRs, generates documentation, or prepares for review
   - Example: Create pull request, generate API docs, update changelog
   - Capture the exit code, output, and duration
   - If hook fails (non-zero exit code), fix the issues before proceeding

4. **Call the complete endpoint** - Include BOTH hook execution results
   - Both hooks must have succeeded (exit code 0)
   - Include both `after_doing_result` and `before_review_result` in request
   - If either hook failed, do NOT call the complete endpoint - fix the issues first

5. **Execute remaining hooks** (returned in the response):
   - `after_review` hook (blocking, 600s timeout) - only if `needs_review=false`
   - `after_goal` hook - only if `needs_review=false` and this task was the last open child of a goal

6. **Wait for review** (if `needs_review=true`)
   - A human reviewer will approve or request changes
   - Call `PATCH /api/tasks/:id/mark_reviewed` to finalize

## Example Usage

### Complete Workflow Example

These two examples show how to capture and send the hook results, so their request bodies leave out the other fields. A real request also carries `explorer_result`, `reviewer_result`, `workflow_steps` and the other required fields shown in the [Request Body Example](#request-body-example). Without `explorer_result` and `reviewer_result` it is rejected with `422` in strict mode, the production default.

The examples on this page time hooks with `$(( $(date +%s) * 1000 ))`, which is whole-second precision and works with both GNU and BSD date, and wrap them in `timeout`, which stock macOS lacks. See the [portability note in the API README](README.md#examples).

```bash
# Step 1: Execute after_doing hook FIRST
# Read hook command from .stride.md (e.g., "mix test && mix credo --strict")
START_TIME_1=$(( $(date +%s) * 1000 ))
OUTPUT_1=$(timeout 600 bash -c 'mix test && mix format --check-formatted && mix credo --strict' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(( $(date +%s) * 1000 ))
DURATION_1=$((END_TIME_1 - START_TIME_1))

# Check if after_doing succeeded before proceeding
if [ $EXIT_CODE_1 -ne 0 ]; then
  echo "after_doing hook failed. Fix issues before continuing."
  exit 1
fi

# Step 2: Execute before_review hook SECOND
# Read hook command from .stride.md (e.g., "gh pr create --title '$TASK_TITLE'")
START_TIME_2=$(( $(date +%s) * 1000 ))
OUTPUT_2=$(timeout 600 bash -c 'gh pr create --title "W21: Implement authentication" --body "Ready for review"' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(( $(date +%s) * 1000 ))
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
    \"completion_summary\": \"Added JWT auth with refresh tokens\",
    \"completion_notes\": \"All tests passing. PR created. Ready for review.\",
    \"actual_complexity\": \"medium\",
    \"actual_files_changed\": \"lib/my_app/auth.ex, test/my_app/auth_test.exs\",
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
START_TIME_1=$(( $(date +%s) * 1000 ))
OUTPUT_1=$(timeout 600 bash -c 'npm test && npm run lint && npm run build' 2>&1)
EXIT_CODE_1=$?
END_TIME_1=$(( $(date +%s) * 1000 ))
DURATION_1=$((END_TIME_1 - START_TIME_1))

# Execute before_review hook
START_TIME_2=$(( $(date +%s) * 1000 ))
OUTPUT_2=$(timeout 600 bash -c 'npm run docs:generate' 2>&1)
EXIT_CODE_2=$?
END_TIME_2=$(( $(date +%s) * 1000 ))
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

START_TIME=$(( $(date +%s) * 1000 ))
OUTPUT=$(timeout 600 bash -c './scripts/deploy.sh' 2>&1)
EXIT_CODE=$?
END_TIME=$(( $(date +%s) * 1000 ))
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
- If `needs_review=true`, task moves to the Review column and its status stays `in_progress` (there is no `review` status)
- If `needs_review=false`, task automatically moves to Done column with `completed` status
- Both `after_doing` and `before_review` hooks are **blocking** - non-zero exit codes will cause the API to reject your completion
- The `after_review` hook is also **blocking** and must be executed after API call returns (only if `needs_review=false`)
- Hook timeouts: the server sends 600 seconds (600000 milliseconds) for `after_doing`, `before_review` and `after_review`
- Agent model from your API token is automatically recorded as `completed_by_agent`
- If the task is a goal (parent task), it will only move to Done when all child tasks are complete

## See Also

- [POST /api/tasks/claim](post_tasks_claim.md) - Claim a task to start working
- [PUT /api/tasks/:id/changed_files](put_tasks_id_changed_files.md) - Upload the per-file diff snapshot (sole writer for `changed_files`)
- [PATCH /api/tasks/:id/mark_reviewed](patch_tasks_id_mark_reviewed.md) - Mark task as reviewed after completion
- [POST /api/tasks/:id/unclaim](post_tasks_id_unclaim.md) - Unclaim if you can't complete
- [Diff Contract](../diff-contract.md) - Encoding rules (truncation marker, binary placeholder, 500-line cap)
