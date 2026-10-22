# AI Workflow Integration Guide

## What Makes This Powerful for AI Workflows

The Kanban system uses a **2-level hierarchy** optimized for AI interaction:

**Hierarchy:**
- **Goal** (G prefix) - Large initiatives containing multiple related tasks
- **Work** (W prefix) - Individual work items (features, enhancements)
- **Defect** (D prefix) - Bug fixes and defect corrections

A goal contains work and defect tasks only. Goals are never nested: a child task
of type `goal` is rejected with HTTP 422.

### Core Schema Fields

- title (string) - Task title
- description (text) - Detailed description
- status (enum: open, in_progress, blocked, completed)
- priority (enum: low, medium, high, critical)
- complexity (enum: small, medium, large)
- type (enum: work, defect, goal) - Type of task (work, defect, or goal)
- identifier (string) - Human-readable ID (G1, W42, D5, etc.)
- needs_review (boolean) - Whether task requires human review before completion

### Additional Fields

**Lifecycle Tracking:**
- created_by_id (integer) - User who created task
- created_by_agent (string) - AI agent name if AI-created (e.g., "ai_agent:claude-sonnet-4-5")
- completed_by_agent (string) - AI agent name if AI-completed
- completed_at (timestamp) - When task was completed
- time_spent_minutes (integer) - Time spent on task
- completion_notes (text) - Notes about the completion

**Review Workflow:**
- review_status (enum: pending, approved, changes_requested, rejected) - Review decision. A human records it in the board UI; the API cannot set it
- review_report (text) - Structured review report from task-reviewer agent (optional, set at completion time)
- needs_review (boolean) - Whether task requires human review

**Dependencies & Relationships:**
- parent_id (integer) - ID of the parent goal (null for a standalone task or a goal). Read-only through the API: the server sets it when a goal is created with nested tasks or via `POST /api/tasks/batch`; it cannot be set on a single create or changed via PATCH (a human can change it in the board UI)
- required_capabilities (array) - Agent capabilities required (e.g., ["code_generation", "testing"])

**Standard Fields:**
- assigned_to_id (integer) - User assigned to task
- column_id (integer) - Current kanban column
- board_id (integer) - Board this task belongs to
- created_at, updated_at - Timestamps

### Key API Endpoints for AI

**Complete API documentation is available in [api/README.md](api/README.md)**

**Machine-readable contract:** [GET /api/openapi.json](api/get_openapi_json.md) serves an OpenAPI 3.1 description of every endpoint, with no authentication required — point a client generator, an API viewer or MCP tooling at it.

**Task Discovery:**
- [GET /api/tasks/next](api/get_tasks_next.md) - Get next available task matching agent capabilities
- [GET /api/tasks](api/get_tasks.md) - List tasks; optional filters (`column_id`, `status`, `type`, `priority`, `assigned_to_id`, `parent`, `updated_since`, `label`) and opt-in cursor pagination (`limit`, `cursor` → `meta.next_cursor`). Syncing with `updated_since`? See [Incremental sync](api/get_tasks.md#incremental-sync)
- [GET /api/tasks/:id](api/get_tasks_id.md) - Get specific task details
- [GET /api/tasks/:id/tree](api/get_tasks_id_tree.md) - Get task with all children (for goals)
- [GET /api/tasks/:id/comments](api/get_tasks_id_comments.md) - Read a task's comments, such as feedback a human left on the board. `GET /api/tasks/:id` carries a `comment_count`

**Task Management:**
- [POST /api/tasks/claim](api/post_tasks_claim.md) - Claim a task and receive `before_doing` hook
- [POST /api/tasks/:id/unclaim](api/post_tasks_id_unclaim.md) - Unclaim a task you can't complete
- [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md) - Complete a task and receive hooks
- [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md) - Finalize review
- [PATCH /api/tasks/:id/mark_done](api/patch_tasks_id_mark_done.md) - Bypass review and mark as done (⚠️ limited functionality)
- [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md) - Report the result of a goal's `after_goal` hook
- [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md) - Find out whether a completion armed its goal's `after_goal` hook
- [POST /api/tasks/:id/comments](api/post_tasks_id_comments.md) - Leave a comment humans can read in the UI, attributed to your agent name

**Task Creation:**
- [POST /api/tasks](api/post_tasks.md) - Create a task or goal with nested child tasks
- [POST /api/tasks/batch](api/post_tasks_batch.md) - Create multiple goals with nested tasks in one request

**Authentication:**
- Bearer token authentication
- Capability matching: Agent capabilities matched against task `required_capabilities`
- See [api/README.md](api/README.md) for authentication setup

### AI Workflow Integration

**Supported AI Coding Agents**

Stride ships a per-agent plugin for each supported AI coding agent. Each plugin packages the same Stride lifecycle skills (claim → explore → implement → review → complete) adapted to the host agent's skill-loading and hook-interception model.

| Agent | Plugin | Install |
|---|---|---|
| Claude Code | [`stride`](https://github.com/cheezy/stride) | `/plugin marketplace add cheezy/stride-marketplace` then `/plugin install stride@stride-marketplace` |
| Gemini CLI | [`stride-gemini`](https://github.com/cheezy/stride-gemini) | `gemini extensions install https://github.com/cheezy/stride-gemini` |
| Copilot CLI | [`stride-copilot`](https://github.com/cheezy/stride-copilot) | `copilot plugin install https://github.com/cheezy/stride-copilot` |
| Codex CLI | [`stride-codex`](https://github.com/cheezy/stride-codex) | `curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh \| bash` |
| OpenCode | [`stride-opencode`](https://github.com/cheezy/stride-opencode) | See plugin README |
| Pi Coding Agent | [`stride-pi`](https://github.com/cheezy/stride-pi) | `curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh \| bash` |

The Pi edition ships the same 11 lifecycle skills as the other plugins plus two Pi-specific TypeScript extensions: `hook-bridge` (automatic `.stride.md` hook execution intercepting Pi's `tool_call` events) and `subagent-dispatch` (inline sub-agent skill dispatch). See the [stride-pi v1.0.0 release notes](https://github.com/cheezy/stride-pi/releases/tag/v1.0.0) for the feature matrix.

**In-app onboarding picker**

New users don't have to hunt for these commands: after confirming their email, the account-confirmation page's "Getting started" checklist includes an **Install the Stride plugin** step with a per-agent picker. Selecting an agent (Claude Code, Copilot, Gemini, Codex, OpenCode, or Pi) shows that agent's workflow-plugin install command with a copy button and a link to its marketplace/repository, plus a recommended **ideation-plugin** install command and link where one exists. Pi is shown as an individual-repository install with no marketplace, and — because it has no separate ideation port yet — its panel notes that no ideation plugin is available. The picker is driven by a single source-of-truth registry, so these instructions always match the table above.

**Recommended: Use the Workflow Orchestrator**

For agents using Stride plugins (Claude Code, Gemini CLI, Copilot CLI, Codex CLI, OpenCode, Pi Coding Agent), the `stride-workflow` skill is the recommended entry point. It walks through the complete lifecycle — claiming, codebase exploration, implementation, code review, hooks, and completion — in a single skill. The orchestrator ensures no mandatory steps are skipped.

**The workflow IS the automation. Every step exists because skipping it caused failures. Following every step IS the fast path.**

**Hook Validation**

Hook execution is enforced at the API level. You MUST execute hooks and include the execution results in your API requests. The server will reject requests without valid hook results.

**Required Hook Result Format:**
```json
{
  "exit_code": 0,
  "output": "Hook execution output (stdout/stderr combined)",
  "duration_ms": 1234
}
```

**Hook Execution Order**

Hooks MUST be executed in the exact order specified below. The API validates hook execution results and rejects requests that don't include them.

**Complete AI Workflow with Hooks (Claim → Explore → Implement → Review → Complete):**

**✨ Stride Plugin Available:** Use the `stride-workflow` orchestrator skill for the complete lifecycle. It handles hook execution, codebase exploration, code review, and all required API fields automatically. Individual skills (`stride-claiming-tasks`, `stride-completing-tasks`) remain available for standalone use.

1. **Discover tasks** - Call [GET /api/tasks/next](api/get_tasks_next.md) to find available tasks

2. **Execute `before_doing` hook FIRST** (blocking; see [Hook System](#hook-system))
   - Example: Pull latest code, setup workspace
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**

3. **Claim a task** - Call [POST /api/tasks/claim](api/post_tasks_claim.md)
   - **REQUIRED:** Include `before_doing_result` parameter with hook execution result
   - API validates hook was executed and succeeded
   - Receives `before_doing` hook metadata (for reference)
   - Task moves to Doing column

4. **Work on the task** - Implement changes, write code, run tests
   - Do the actual implementation work
   - Write tests, fix bugs, add features

5. **⚠️ CRITICAL: Execute `after_doing` hook FIRST** (blocking; see [Hook System](#hook-system))
   - Example: Run tests, build project, lint code
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/complete` - fix the issues first
   - This validates your work is ready for completion

6. **⚠️ CRITICAL: Execute `before_review` hook SECOND** (blocking; see [Hook System](#hook-system))
   - Example: Create PR, generate documentation
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/complete` - fix the issues first
   - This prepares the task for review

7. **Complete the task** - Call [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md)
   - **REQUIRED:** `completion_summary`, `actual_complexity` (`small`, `medium` or `large`), `actual_files_changed` and `time_spent_minutes`
   - **REQUIRED:** BOTH `after_doing_result` AND `before_review_result`
   - **REQUIRED (G65):** Include `explorer_result` and `reviewer_result` — dispatched-subagent shape or self-reported skip-form with enum `reason` and 40+ non-whitespace-char `summary`. A dispatched `reviewer_result` must carry the full review report described in [completion-contract.md](completion-contract.md). See [Completion Validation](#completion-validation) below.
   - **Optional:** `workflow_steps` — six-entry telemetry array, one object per phase (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`). The server checks its shape when you send it. On a skipped entry, add the optional `reason_code` next to `reason` so the skip aggregates on the compliance dashboard instead of fragmenting.
   - **Only call this AFTER both hooks succeed**
   - API validates both hooks were executed and succeeded
   - Task moves to Review column, or to Done if `needs_review=false`
   - The response's `hooks` list names the hooks for this step: `after_doing` and `before_review` always, `after_review` too when `needs_review=false`, and `after_goal` when this task was the last open child of a goal. See [Hook System](#hook-system)

8. **⚠️ STOP HERE if `needs_review=true`**
   - **DO NOT execute `after_review` hook yet!**
   - Wait for human reviewer to approve/reject the task
   - The human reviewer records `review_status` in the board UI: the Review queue's **Approve** and **Request changes** buttons, or the task's Review Status field. The API cannot set it
   - Proceed to step 9 only when notified of approval

9. **Execute `after_review` hook FIRST** (blocking; see [Hook System](#hook-system))
   - Example: Deploy to production, notify stakeholders
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/mark_reviewed` - fix the issues first

10. **Finalize review** - Call [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md)
    - **REQUIRED:** Include `after_review_result` parameter with hook execution result. It is the only body field: there is no `status` parameter, because the call acts on the `review_status` the human recorded
    - **Only call this AFTER `after_review` hook succeeds** (if `needs_review=true`)
    - API validates hook was executed and succeeded, before it looks at the review decision
    - If approved: task moves to Done
    - If changes requested or rejected: task returns to Doing, repeat from step 4. The request still needs an `after_review_result`
    - If the human used **Approve** in the Review queue, the server has already moved the task to Done, and this call returns `422` because the task is no longer in Review. See [When a Human Approves from the Review Queue](REVIEW-WORKFLOW.md#when-a-human-approves-from-the-review-queue)

11. **Dependencies automatically unblock** - Next tasks become available once the task reaches Done

12. **Run `after_goal` if it arrived** - When the `hooks` list from step 7 or step 10 includes `after_goal`, this task was the last open child of its goal. Run your `after_goal` section and report its result with [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md), using the goal's ID

---

### Claiming Tasks

A claim (step 3 above) succeeds only for a task that is available to you. The main conditions — each one is checked by the server — are:

- **It is in the Ready column.** Tasks created through the API land in Backlog, which is never claimable — a human must promote the task to Ready in the board UI.
- **It is a `work` or `defect` task.** Goals are never claimed; their child tasks are. A task marked as a human task, or an archived task, is never offered to an agent either.
- **It is not already claimed.** Its status is `open`, or an earlier claim on it has expired (claims expire after 60 minutes). An expired claim is not released on its own: the claimed task stays in Doing, still assigned, and its user gets a notification (on a paid board, or anywhere while paid plans are not enforced). It can be claimed again only once it is back in Ready, either because its agent unclaimed it (see [UNCLAIM-TASKS.md](UNCLAIM-TASKS.md)) or because a person moved it there.
- **Every task in its `dependencies` is completed.**
- **Your API token's capabilities include every entry in its `required_capabilities`.** A token with no capabilities configured skips this check.
- **It is not assigned to a different user.** A task pre-assigned to someone else (in the UI, or cascaded from its goal) can only be claimed by that user.
- **When you claim without an `identifier`** (and for `GET /api/tasks/next`), a task is also skipped while any of its `key_files` is listed by a task currently in Doing or Review, so two agents never edit the same file at once. A claim that names an `identifier` does not apply this check.

When the claim fails, the error response names the likely causes in `common_causes`:

| Response | Meaning | What to do |
|----------|---------|------------|
| `409 Conflict` without an `identifier` in the request | No task in Ready meets every condition above | Wait for tasks to be promoted to Ready or for dependencies to complete |
| `409 Conflict` for a named `identifier` | That task is blocked, already claimed, needs capabilities you lack, is not in Ready, or does not exist on this board | Check the task's column, `dependencies` and `required_capabilities`, or claim a different task |
| `403 Forbidden`, task assigned to a different user | The task is assigned to someone else | Skip it and call `GET /api/tasks/next` again — your queue already excludes tasks assigned to others |
| `403 Forbidden`, no write access | Your API token's user cannot write to this board | Ask a board owner for write access |
| `422 Unprocessable Entity` | `before_doing_result` is missing, malformed, or reports a non-zero exit code | Run the `before_doing` hook first and send its result — see [Hook System](#hook-system) |

---

### Completion Validation

Every `/complete` request needs `completion_summary`, `actual_complexity` (`small`, `medium` or `large`), `actual_files_changed`, `time_spent_minutes`, `after_doing_result` and `before_review_result`; a request without one of them is rejected with HTTP `422`. Starting with G65 (April 2026), the endpoint also validates three more top-level fields:

| Field | Required | Shape |
|---|---|---|
| `explorer_result` | Yes (absent: grace-warned, strict-rejected; malformed: always rejected) | Dispatched-subagent shape **OR** self-reported skip-form |
| `reviewer_result` | Yes (absent: grace-warned, strict-rejected; malformed: always rejected) | Same two shapes as `explorer_result`. The dispatched shape additionally requires `acceptance_criteria_checked` and `issues_found`, and must carry the full structured review report: every section listed in [completion-contract.md](completion-contract.md), plus `status` or `issue_counts`. A dispatched report that leaves one out, that leaves a section the task supplied (`testing_strategy`, `security_considerations`) unassessed, or that checks fewer acceptance criteria than the task lists, is rejected in every mode |
| `workflow_steps` | Optional (telemetry); its shape is checked when you send it | Six-entry array: `explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`. A skipped entry may carry an optional `reason_code` alongside its free-text `reason` — see [reason_code](api/patch_tasks_id_complete.md) |

**Rollout modes** (controlled by the `:strict_completion_validation` application flag):

- **Strict mode (the default in production):** A missing `explorer_result` or `reviewer_result`, a review that checks more acceptance criteria than the task lists, or another check the flag governs returns HTTP `422` with a `failures` list. Production runs in strict mode unless the deployment sets `STRIDE_STRICT_COMPLETION_VALIDATION=false`.
- **Grace mode (the default everywhere else):** Those same failures log a structured warning and the request succeeds. Setting `STRIDE_STRICT_COMPLETION_VALIDATION=true` turns strict mode on outside production.
- **In both modes:** An `explorer_result`, `reviewer_result` or `workflow_steps` that is present but malformed is rejected with `422`, and so is a dispatched `reviewer_result` that falls short of [completion-contract.md](completion-contract.md). Grace mode forgives a missing result and a few consistency checks: a review that checks more acceptance criteria than the task lists, and a `security_considerations` breakdown that marks an item `partial` or `unmitigated` beside a verdict that is not `failed`. Those two are rejected in strict mode.

**Skip form** — for platforms without subagent dispatch (Cursor, Windsurf, Continue.dev, Kimi Code) or when the decision matrix legitimately skipped the step:

```json
{
  "dispatched": false,
  "reason": "no_subagent_support",
  "summary": "Read lib/foo.ex and test/foo_test.exs inline; identified the existing error-tuple pattern to mirror."
}
```

The `reason` field must be one of five enum values: `no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`. The `summary` must contain at least 40 non-whitespace characters.

**Full specification:** See [PATCH /api/tasks/:id/complete — Completion Validation Format (G65)](api/patch_tasks_id_complete.md#completion-validation-format-g65) for the complete shape, rejection example, and authoritative schema references, and its [422 section](api/patch_tasks_id_complete.md#unprocessable-entity-422) for the error bodies.

---

**⚠️ CRITICAL: after_review Hook Timing - Two Different Paths**

The `after_review` hook execution depends on whether the task requires human review:

**Path 1: needs_review=true (Human Review Required)**
```
1. Execute before_review hook, then call /complete
2. STOP and WAIT for human reviewer
3. Human reviews and records approve/changes_requested/reject in the board UI
4. IF approved and the task is still in Review: Execute after_review hook ← ONLY AFTER APPROVAL!
5. Call /mark_reviewed with after_review_result
6. Task moves to Done column (approved) or back to Doing (changes_requested, rejected)
```

If the human approved from the Review queue, the task is already in Done and step 5 returns `422`; see [When a Human Approves from the Review Queue](REVIEW-WORKFLOW.md#when-a-human-approves-from-the-review-queue).

**Path 2: needs_review=false (Auto-Approved)**
```
1. Execute before_review hook, then call /complete
2. Task moves to Done column
3. Execute after_review hook from the response's hooks list ← No waiting required
```

On this path nothing reports the `after_review` result back to the server.

**Common Mistake:**
```
❌ WRONG: Execute after_review immediately after before_review when needs_review=true
✅ CORRECT: Wait for the human's approval before executing after_review
```

---

**✅ CORRECT WORKFLOW:**
```
1. Execute before_doing hook ← FIRST! Capture exit_code, output, duration_ms
2. Claim task WITH before_doing_result parameter ← API validates hook succeeded
3. Do work
4. Execute after_doing hook ← Capture exit_code, output, duration_ms
5. Execute before_review hook ← Capture exit_code, output, duration_ms
6. Call /complete WITH after_doing_result AND before_review_result ← API validates both succeeded
7. IF needs_review=false: the task is in Done; execute after_review from the response's hooks list
   IF needs_review=true: STOP and wait for the human's decision
8. IF needs_review=true and approved: execute after_review, then call /mark_reviewed WITH after_review_result
9. IF the hooks list from step 6 or step 8 includes after_goal: execute it and report it with PATCH /api/tasks/:id/after_goal
```

**Important Requirements:**
- `before_doing_result` is a **REQUIRED** parameter for POST /api/tasks/claim
- `after_doing_result` and `before_review_result` are **REQUIRED** parameters for PATCH /api/tasks/:id/complete
- `after_review_result` is a **REQUIRED** parameter for PATCH /api/tasks/:id/mark_reviewed
- API validates hook was executed and succeeded (exit_code 0)
- API returns 422 error if hook result is missing or hook failed

**⚠️ WRONG: Premature after_review Execution**
```
❌ INCORRECT for needs_review=true:
7. Execute before_review hook (create PR)
8. Execute after_review hook (git commit) ← TOO EARLY!
   Problem: Task not approved yet, changes committed prematurely
```

**✅ CORRECT: Wait for Approval**
```
✅ CORRECT for needs_review=true:
7. Execute before_review hook (create PR), then call /complete
8. STOP and wait for human reviewer
9. Receive approval notification
10. Execute after_review hook (git commit) ← Only after approval
11. Call /mark_reviewed endpoint WITH after_review_result
```

**Hook System:**
- Server provides hook **metadata only** (name, env vars, timeout, blocking status)
- Agent reads `.stride.md` and executes hooks **locally on their machine**
- Hooks are language-agnostic - work with any environment
- **Windows users:** See [WINDOWS-SETUP.md](WINDOWS-SETUP.md) for PowerShell hook examples
- See [Hook System](#hook-system) section below for details

### Task Creation Patterns

**Creating a Goal with Child Tasks:**
```json
POST /api/tasks
{
  "task": {
    "title": "Implement search feature",
    "type": "goal",
    "complexity": "large",
    "priority": "high",
    "tasks": [
      {
        "title": "Add search schema",
        "type": "work",
        "complexity": "medium",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Build search UI",
        "type": "work",
        "complexity": "medium",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Write search tests",
        "type": "work",
        "complexity": "small",
        "required_capabilities": ["testing"]
      }
    ]
  }
}
```

**Creating Individual Tasks:**
```json
POST /api/tasks
{
  "task": {
    "title": "Fix login bug",
    "description": "Users can't log in with special characters",
    "type": "defect",
    "complexity": "small",
    "priority": "high",
    "needs_review": true
  }
}
```

**WIP limits on creation:** a `work` or `defect` task created on its own is
checked against its target column's WIP limit (Backlog by default). When the
column is full the request returns HTTP 422 with an `error` naming the WIP
limit, plus `documentation` and `common_causes`, and nothing is created. Goals,
and the child tasks nested under a goal (including every goal sent to
`POST /api/tasks/batch`), are never checked against WIP limits when they are
created, though nested work and defect tasks count toward the column's limit
once they exist. A limit of `0` means unlimited.
Retrying immediately returns the same 422: wait for a task to leave the column
or ask a board owner to raise the limit.

See [POST /api/tasks](api/post_tasks.md) for complete documentation.

**✨ Stride Plugin Skills Available:**
- Use `stride-workflow` for the complete task lifecycle (recommended entry point)
- Use `stride-creating-tasks` for individual tasks and defects
- Use `stride-creating-goals` for goals with nested tasks or batch creation

These skills are available via the Stride plugin for Claude Code, Gemini CLI, Copilot CLI, Codex CLI, OpenCode, and Pi Coding Agent.

### Task Completion

**✨ Stride Plugin Available:** Use the `stride-workflow` orchestrator (recommended) or the `stride-completing-tasks` skill before calling PATCH /api/tasks/:id/complete. These ensure proper hook execution order and prevent quality gate bypasses.

You MUST execute BOTH the `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint and include both results in your request.

When completing a task, use [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md). This is the smallest body every mode accepts; it reports exploration and review in the self-reported skip form:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Sonnet 4.5",
  "completion_summary": "Added refresh-token rotation to the session controller.",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/my_app/auth.ex, test/my_app/auth_test.exs",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing. PR created.",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...",
    "duration_ms": 2340
  },
  "explorer_result": {
    "dispatched": false,
    "reason": "self_reported_exploration",
    "summary": "Read the key files and their tests inline; the change follows the existing context pattern."
  },
  "reviewer_result": {
    "dispatched": false,
    "reason": "self_reported_review",
    "summary": "Re-read the diff against every acceptance criterion and pitfall; no issues found."
  }
}
```

When a subagent did the exploring or reviewing, send the dispatched shape instead. A dispatched `reviewer_result` must carry the full review report in [completion-contract.md](completion-contract.md), or the request is rejected in every mode. The field-by-field schema is in [Completion Validation Format (G65)](api/patch_tasks_id_complete.md#completion-validation-format-g65); this guide does not repeat it.

**What happens:**
1. API validates that BOTH `after_doing_result` and `before_review_result` are present and hooks succeeded (exit_code 0)
2. API validates the completion fields — see [Completion Validation](#completion-validation). A rejection is a `422` whose body names each failing field; see [the 422 section](api/patch_tasks_id_complete.md#unprocessable-entity-422)
3. Task moves to Review column (or Done if `needs_review=false`)
4. The response's `hooks` list carries `after_doing` and `before_review`, plus `after_review` if `needs_review=false`, plus `after_goal` if this task was the last open child of a goal
5. If `needs_review=true`, wait for human review
6. Call [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md) to finalize (with `after_review_result`)

**Important:** If either the `after_doing` or `before_review` hook fails (non-zero exit code), DO NOT call the complete endpoint. Fix the issues first, then re-execute the hooks and try again.

See [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md) for complete documentation.

### ⚠️ CRITICAL: mark_done Endpoint Limitations

The [PATCH /api/tasks/:id/mark_done](api/patch_tasks_id_mark_done.md) endpoint exists as a bypass mechanism for administrative or emergency situations, but **agents should NOT use it** in normal workflows due to critical limitations:

**What mark_done Does:**
- Requires the task to be in the Review column; anywhere else it returns `422`
- Moves task from Review column directly to Done column
- Sets `status` to `completed`
- Sets `completed_at` timestamp
- Unblocks dependent tasks, as any move to Done does

**What mark_done Does NOT Do:**
- ❌ **Does NOT execute or return any workflow hooks** (no `after_review`, and no `after_goal` even when the task is a goal's last child)
- ❌ **Does NOT take a hook result** — no `after_review_result` is checked
- ❌ **Does NOT look at `review_status`** — it completes the task whatever the human reviewer decided
- ❌ **Does NOT set review metadata** — `review_status`, `reviewed_at` and `reviewed_by_id` are left as they are

**Why This Matters:**

If you use `mark_done` instead of the review workflow, your `after_review` hook never runs and the human's review decision is ignored: a task the reviewer sent back with changes requested still lands in Done.

**Correct Approach:**
```
✅ Wait for the human's decision, then use PATCH /api/tasks/:id/mark_reviewed
   - Requires after_review_result, so your after_review hook has run
   - Acts on the review_status the human recorded (there is no status parameter)
   - approved: moves the task to Done and unblocks dependent tasks
   - changes_requested / rejected: moves the task back to Doing
   - Returns after_review (and after_goal for a goal's last child) in its hooks list
```

**Incorrect Approach:**
```
❌ Use PATCH /api/tasks/:id/mark_done
   - Skips hooks
   - Ignores the review decision
   - Never delivers after_goal
```

**When mark_done is Appropriate:**
- Emergency administrative override by humans
- Cleaning up old stuck tasks
- External review that happened outside the system

**Agents should use the complete workflow** (claim → work → complete → mark_reviewed) to ensure proper hook execution, completion tracking, and dependency management.

See [PATCH /api/tasks/:id/mark_done](api/patch_tasks_id_mark_done.md) for complete documentation.

### Hook System

The hook system enables agents to execute custom workflows at key points in the task lifecycle.

**Four Fixed Hook Points:**

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 600s | Setup workspace, pull code |
| `after_doing` | After completing work | Yes | 600s | Run tests, build project |
| `before_review` | Entering review | Yes | 600s | Create PR, generate docs |
| `after_review` | After review approval | Yes | 600s | Deploy, notify stakeholders |

The server sends each hook's `blocking` flag and its `timeout` in milliseconds. Today every hook is sent as `"blocking": true` with a `"timeout"` of `600000`. A blocking hook must succeed before you make the request that reports it: `before_doing_result` on the claim, `after_doing_result` and `before_review_result` on `/complete`, `after_review_result` on `/mark_reviewed`. A missing result, or one with a non-zero `exit_code`, is rejected with `422`.

**Where each hook arrives:**
- `before_doing` — the claim response's `hook` object
- `after_doing` and `before_review` — the `/complete` response's `hooks` list. You run both before calling `/complete`
- `after_review` — the `/complete` response's `hooks` list when `needs_review=false` (its result is not reported anywhere), or the `/mark_reviewed` response when the review was approved

**The fifth hook, `after_goal`:** when a completion finishes the last open child of a goal, the server appends an `after_goal` entry to that response's `hooks` list — the `/complete` response when the task went straight to Done, or the approving `/mark_reviewed` response. It is blocking with a 600s timeout, like the other four. Run your `## after_goal` section and report `{exit_code, output, duration_ms}` with [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md), using the goal's ID. An `exit_code` of `0` moves the goal to Done; any other exit code is recorded and the goal waits for another report. If no successful report arrives within the five-minute grace window, the server moves the goal to Done itself. The `after_goal` entry carries the completed child's `TASK_*` variables; the goal's own ID, identifier, title and description come from [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md).

**Client-Side Execution:**
- Server provides metadata (name, env vars, timeout, blocking status)
- Agent reads `.stride.md` configuration file
- Agent executes hooks locally on their machine, within the `timeout` the server sent
- Language-agnostic - works with any environment

**Configuration Files:**

`.stride_auth.md` (DO NOT commit - contains secrets):
```markdown
# Stride API Authentication

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_dev_abc123...`
- **User Email:** `your-email@example.com`
```

`.stride.md` (version controlled - project hooks):
````markdown
# Stride Configuration

## before_doing
```bash
git pull origin main
mix deps.get
```

## after_doing
```bash
mix test
mix credo --strict
```

## before_review
```bash
gh pr create --title "$TASK_TITLE"
```

## after_review
```bash
./scripts/deploy.sh
```

## after_goal
```bash
git push origin main
```
````

See [api/README.md](api/README.md) for complete hook system documentation and examples.

### Key Benefits for AI Agents

**Efficiency Gains:**
- **Atomic claiming** - No race conditions between agents
- **Capability matching** - Only see tasks you can complete
- **Real-time updates** - PubSub broadcasts keep all agents in sync
- **Hook automation** - Execute custom workflows at each lifecycle stage

**Quality Improvements:**
- **Completion tracking** - Time spent, notes, agent attribution
- **Review workflow** - Optional human review with approve/reject
- **Mandatory hook validation** - All five hooks are blocking and must succeed
- **API-level enforcement** - Server validates hook execution before state changes

**Coordination:**
- **Dependencies** - Server handles blocking/unblocking automatically
- **Goal hierarchy** - Group related tasks, track overall progress
- **Unclaim mechanism** - Release tasks if blocked or unable to complete
- **Review status** - Track approved/changes_requested/rejected decisions

This creates a **Kanban board optimized for AI agents** - structured workflow with hooks, flexible collaboration with humans.

### Getting Started

1. **Install the Stride plugin** for your AI agent platform (Claude Code, Gemini CLI, Copilot CLI, Codex CLI, OpenCode, or Pi Coding Agent)
2. **Set up authentication** - Create `.stride_auth.md` with your API token
3. **Configure hooks** - Create `.stride.md` with your workflow hooks
4. **Activate `stride-workflow`** - The orchestrator walks through claim → explore → implement → review → complete
5. **Read the API documentation** - [api/README.md](api/README.md) for endpoint details

### Related Documentation

- [api/README.md](api/README.md) - Complete API documentation for agents
- Individual endpoint docs in [api/](api/) directory
- See CHANGELOG.md for version history and recent changes
