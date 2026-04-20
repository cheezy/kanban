# AI Workflow Integration Guide

## What Makes This Powerful for AI Workflows

The Kanban system uses a **2-level hierarchy** optimized for AI interaction:

**Hierarchy:**
- **Goal** (G prefix) - Large initiatives containing multiple related tasks
- **Work** (W prefix) - Individual work items (features, enhancements)
- **Defect** (D prefix) - Bug fixes and defect corrections

### Core Schema Fields

- title (string) - Task title
- description (text) - Detailed description
- status (enum: open, in_progress, blocked, review, completed)
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
- review_status (enum: approved, changes_requested, rejected) - Review decision
- review_report (text) - Structured review report from task-reviewer agent (optional, set at completion time)
- needs_review (boolean) - Whether task requires human review

**Dependencies & Relationships:**
- parent_goal_id (integer) - Links task to parent goal
- required_capabilities (array) - Agent capabilities required (e.g., ["code_generation", "testing"])

**Standard Fields:**
- assigned_to_id (integer) - User assigned to task
- column_id (integer) - Current kanban column
- board_id (integer) - Board this task belongs to
- created_at, updated_at - Timestamps

### Key API Endpoints for AI

**Complete API documentation is available in [../api/README.md](../api/README.md)**

**Task Discovery:**
- [GET /api/tasks/next](../api/get_tasks_next.md) - Get next available task matching agent capabilities
- [GET /api/tasks](../api/get_tasks.md) - List all tasks (optionally filter by column)
- [GET /api/tasks/:id](../api/get_tasks_id.md) - Get specific task details
- [GET /api/tasks/:id/tree](../api/get_tasks_id_tree.md) - Get task with all children (for goals)

**Task Management:**
- [POST /api/tasks/claim](../api/post_tasks_claim.md) - Claim a task and receive `before_doing` hook
- [POST /api/tasks/:id/unclaim](../api/post_tasks_id_unclaim.md) - Unclaim a task you can't complete
- [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md) - Complete a task and receive hooks
- [PATCH /api/tasks/:id/mark_reviewed](../api/patch_tasks_id_mark_reviewed.md) - Finalize review
- [PATCH /api/tasks/:id/mark_done](../api/patch_tasks_id_mark_done.md) - Bypass review and mark as done (⚠️ limited functionality)

**Task Creation:**
- [POST /api/tasks](../api/post_tasks.md) - Create a task or goal with nested child tasks
- [POST /api/tasks/batch](../api/post_tasks_batch.md) - Create multiple goals with nested tasks in one request

**Authentication:**
- Bearer token authentication
- Capability matching: Agent capabilities matched against task `required_capabilities`
- See [../api/README.md](../api/README.md) for authentication setup

### AI Workflow Integration

**Recommended: Use the Workflow Orchestrator**

For agents using Stride plugins (Claude Code, Gemini CLI, Copilot CLI, Codex CLI, OpenCode), the `stride-workflow` skill is the recommended entry point. It walks through the complete lifecycle — claiming, codebase exploration, implementation, code review, hooks, and completion — in a single skill. The orchestrator ensures no mandatory steps are skipped.

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

1. **Discover tasks** - Call [GET /api/tasks/next](../api/get_tasks_next.md) to find available tasks

2. **Execute `before_doing` hook FIRST** (blocking, 60s timeout)
   - Example: Pull latest code, setup workspace
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**

3. **Claim a task** - Call [POST /api/tasks/claim](../api/post_tasks_claim.md)
   - **REQUIRED:** Include `before_doing_result` parameter with hook execution result
   - API validates hook was executed and succeeded
   - Receives `before_doing` hook metadata (for reference)
   - Task moves to Doing column

4. **Work on the task** - Implement changes, write code, run tests
   - Do the actual implementation work
   - Write tests, fix bugs, add features

5. **⚠️ CRITICAL: Execute `after_doing` hook FIRST** (blocking, 120s timeout)
   - Example: Run tests, build project, lint code
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/complete` - fix the issues first
   - This validates your work is ready for completion

6. **⚠️ CRITICAL: Execute `before_review` hook SECOND** (blocking, 60s timeout)
   - Example: Create PR, generate documentation
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/complete` - fix the issues first
   - This prepares the task for review

7. **Complete the task** - Call [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md)
   - **REQUIRED:** Include BOTH `after_doing_result` AND `before_review_result` parameters
   - **REQUIRED (G65):** Include `explorer_result` and `reviewer_result` — dispatched-subagent shape or self-reported skip-form with enum `reason` and 40+ non-whitespace-char `summary`. See [Completion Validation](#completion-validation) below.
   - **Recommended:** Include `workflow_steps` — six-entry telemetry array, one object per phase (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`).
   - **Only call this AFTER both hooks succeed**
   - API validates both hooks were executed and succeeded
   - Task moves to Review column (or Done if `needs_review=false`)

8. **⚠️ STOP HERE if `needs_review=true`**
   - **DO NOT execute `after_review` hook yet!**
   - Wait for human reviewer to approve/reject the task
   - Human reviewer sets review_status through the UI or API
   - Proceed to step 9 only when notified of approval

9. **Execute `after_review` hook FIRST** (blocking, 60s timeout)
   - Example: Deploy to production, notify stakeholders
   - Capture exit_code, output, and duration_ms
   - **Hook must succeed (exit_code 0) to proceed**
   - If this fails, DO NOT call `/mark_reviewed` - fix the issues first

10. **Finalize review** - Call [PATCH /api/tasks/:id/mark_reviewed](../api/patch_tasks_id_mark_reviewed.md)
    - **REQUIRED:** Include `after_review_result` parameter with hook execution result
    - **Only call this AFTER `after_review` hook succeeds** (if `needs_review=true`)
    - API validates hook was executed and succeeded
    - If approved: task moves to Done
    - If changes requested: task returns to Doing, repeat from step 4

11. **Dependencies automatically unblock** - Next tasks become available

---

### Completion Validation

Starting with G65 (April 2026), the `/complete` endpoint validates three additional top-level fields alongside `after_doing_result` and `before_review_result`:

| Field | Required | Shape |
|---|---|---|
| `explorer_result` | Yes (grace-warned, strict-rejected) | Dispatched-subagent shape **OR** self-reported skip-form |
| `reviewer_result` | Yes (grace-warned, strict-rejected) | Same two shapes as `explorer_result`; dispatched shape additionally requires `acceptance_criteria_checked` and `issues_found` |
| `workflow_steps` | Recommended (telemetry) | Six-entry array: `explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review` |

**Rollout modes** (controlled by the `:strict_completion_validation` application flag):

- **Grace mode (current default):** Missing or invalid `explorer_result` / `reviewer_result` log a structured warning and the request succeeds. Emit the fields correctly now to prepare for the flip.
- **Strict mode (post-rollout):** Missing or invalid results return HTTP `422` with a `failures` list. Any agent not emitting valid fields is locked out of completion.

**Skip form** — for platforms without subagent dispatch (Cursor, Windsurf, Continue.dev, Kimi Code) or when the decision matrix legitimately skipped the step:

```json
{
  "dispatched": false,
  "reason": "no_subagent_support",
  "summary": "Read lib/foo.ex and test/foo_test.exs inline; identified the existing error-tuple pattern to mirror."
}
```

The `reason` field must be one of five enum values: `no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`. The `summary` must contain at least 40 non-whitespace characters.

**Full specification:** See [PATCH /api/tasks/:id/complete — Completion Validation Format (G65)](../api/patch_tasks_id_complete.md#completion-validation-format-g65) for the complete shape, rejection example, and authoritative schema references.

---

**⚠️ CRITICAL: after_review Hook Timing - Two Different Paths**

The `after_review` hook execution depends on whether the task requires human review:

**Path 1: needs_review=true (Human Review Required)**
```
1. Execute before_review hook
2. STOP and WAIT for human reviewer
3. Human reviews and decides: approve/changes_requested/reject
4. Call /mark_reviewed endpoint with review decision
5. IF approved: Execute after_review hook ← ONLY AFTER APPROVAL!
6. Task moves to Done column
```

**Path 2: needs_review=false (Auto-Approved)**
```
1. Execute before_review hook
2. Execute after_review hook immediately ← No waiting required
3. Task moves to Done column
```

**Common Mistake:**
```
❌ WRONG: Execute after_review immediately after before_review when needs_review=true
✅ CORRECT: Wait for /mark_reviewed approval before executing after_review
```

---

**✅ CORRECT WORKFLOW:**
```
1. Execute before_doing hook ← FIRST! Capture exit_code, output, duration_ms
2. Claim task WITH before_doing_result parameter ← API validates hook succeeded
3. Do work
4. Execute after_doing hook ← FIRST! Capture exit_code, output, duration_ms
5. Call /complete WITH after_doing_result parameter ← API validates hook succeeded
6. Receive before_review, after_review hooks
7. Execute before_review hook
8. IF needs_review=false: Execute after_review hook immediately
   IF needs_review=true: STOP and wait for human approval
9. IF needs_review=true: Wait for approval notification
10. Call /mark_reviewed (when approved)
11. Execute after_review hook (after approval received)
```

**Important Requirements:**
- `before_doing_result` is a **REQUIRED** parameter for POST /api/tasks/claim
- `after_doing_result` is a **REQUIRED** parameter for PATCH /api/tasks/:id/complete
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
7. Execute before_review hook (create PR)
8. STOP and wait for human reviewer
9. Receive approval notification
10. Call /mark_reviewed endpoint
11. Execute after_review hook (git commit) ← Only after approval
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

See [POST /api/tasks](../api/post_tasks.md) for complete documentation.

**✨ Stride Plugin Skills Available:**
- Use `stride-workflow` for the complete task lifecycle (recommended entry point)
- Use `stride-creating-tasks` for individual tasks and defects
- Use `stride-creating-goals` for goals with nested tasks or batch creation

These skills are available via the Stride plugin for Claude Code, Gemini CLI, Copilot CLI, Codex CLI, and OpenCode.

### Task Completion

**✨ Stride Plugin Available:** Use the `stride-workflow` orchestrator (recommended) or the `stride-completing-tasks` skill before calling PATCH /api/tasks/:id/complete. These ensure proper hook execution order and prevent quality gate bypasses.

You MUST execute BOTH the `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint and include both results in your request.

When completing a task, use [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md):

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing. PR created.",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix format --check-formatted\nAll files formatted correctly",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  }
}
```

**What happens:**
1. API validates that BOTH `after_doing_result` and `before_review_result` are present and hooks succeeded (exit_code 0)
2. Task moves to Review column (or Done if `needs_review=false`)
3. If `needs_review=false`, server returns `after_review` hook metadata
4. If `needs_review=true`, wait for human review
5. Call [PATCH /api/tasks/:id/mark_reviewed](../api/patch_tasks_id_mark_reviewed.md) to finalize (with `after_review_result`)

**Important:** If either the `after_doing` or `before_review` hook fails (non-zero exit code), DO NOT call the complete endpoint. Fix the issues first, then re-execute the hooks and try again.

See [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md) for complete documentation.

### ⚠️ CRITICAL: mark_done Endpoint Limitations

The [PATCH /api/tasks/:id/mark_done](../api/patch_tasks_id_mark_done.md) endpoint exists as a bypass mechanism for administrative or emergency situations, but **agents should NOT use it** in normal workflows due to critical limitations:

**What mark_done Does:**
- Moves task from Review column directly to Done column
- Sets `status` to `completed`
- Sets `completed_at` timestamp

**What mark_done Does NOT Do:**
- ❌ **Does NOT execute any workflow hooks** (no `after_review`, etc.)
- ❌ **Does NOT set completion metadata** (`completed_by_agent`, `completion_summary`, `time_spent_minutes`)
- ❌ **Does NOT automatically unblock dependent tasks** (this is critical!)
- ❌ **Does NOT track who completed the task**

**Why This Matters:**

If you use `mark_done` instead of the proper workflow, dependent tasks will remain blocked indefinitely because the system won't trigger the automatic unblocking logic. This breaks the dependency chain.

**Correct Approach:**
```
✅ Use PATCH /api/tasks/:id/mark_reviewed with status "approved"
   - Executes after_review hook
   - Sets completion metadata
   - Automatically unblocks dependent tasks
   - Tracks completion properly
```

**Incorrect Approach:**
```
❌ Use PATCH /api/tasks/:id/mark_done
   - Skips hooks
   - No completion metadata
   - Dependent tasks stay blocked forever
   - No audit trail
```

**When mark_done is Appropriate:**
- Emergency administrative override by humans
- Cleaning up old stuck tasks
- External review that happened outside the system

**Agents should use the complete workflow** (claim → work → complete → mark_reviewed) to ensure proper hook execution, completion tracking, and dependency management.

See [PATCH /api/tasks/:id/mark_done](../api/patch_tasks_id_mark_done.md) for complete documentation.

### Hook System

The hook system enables agents to execute custom workflows at key points in the task lifecycle.

**Four Fixed Hook Points:**

| Hook | When | Blocking | Timeout | Typical Use |
|------|------|----------|---------|-------------|
| `before_doing` | Before starting work | Yes | 60s | Setup workspace, pull code |
| `after_doing` | After completing work | Yes | 120s | Run tests, build project |
| `before_review` | Entering review | No | 60s | Create PR, generate docs |
| `after_review` | After review approval | No | 60s | Deploy, notify stakeholders |

**Client-Side Execution:**
- Server provides metadata (name, env vars, timeout, blocking status)
- Agent reads `.stride.md` configuration file
- Agent executes hooks locally on their machine
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
```markdown
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
```

See [../api/README.md](../api/README.md) for complete hook system documentation and examples.

### Key Benefits for AI Agents

**Efficiency Gains:**
- **Atomic claiming** - No race conditions between agents
- **Capability matching** - Only see tasks you can complete
- **Real-time updates** - PubSub broadcasts keep all agents in sync
- **Hook automation** - Execute custom workflows at each lifecycle stage

**Quality Improvements:**
- **Completion tracking** - Time spent, notes, agent attribution
- **Review workflow** - Optional human review with approve/reject
- **Mandatory hook validation** - All four hooks are blocking and must succeed
- **API-level enforcement** - Server validates hook execution before state changes

**Coordination:**
- **Dependencies** - Server handles blocking/unblocking automatically
- **Goal hierarchy** - Group related tasks, track overall progress
- **Unclaim mechanism** - Release tasks if blocked or unable to complete
- **Review status** - Track approved/changes_requested/rejected decisions

This creates a **Kanban board optimized for AI agents** - structured workflow with hooks, flexible collaboration with humans.

### Getting Started

1. **Install the Stride plugin** for your AI agent platform (Claude Code, Gemini CLI, Copilot CLI, Codex CLI, or OpenCode)
2. **Set up authentication** - Create `.stride_auth.md` with your API token
3. **Configure hooks** - Create `.stride.md` with your workflow hooks
4. **Activate `stride-workflow`** - The orchestrator walks through claim → explore → implement → review → complete
5. **Read the API documentation** - [../api/README.md](../api/README.md) for endpoint details

### Related Documentation

- [../api/README.md](../api/README.md) - Complete API documentation for agents
- Individual endpoint docs in [../api/](../api/) directory
- See CHANGELOG.md for version history and recent changes
