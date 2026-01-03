# AI Workflow Integration Guide

## What Makes This Powerful for AI Workflows

The Kanban system uses a **2-level hierarchy** optimized for AI interaction:

**Hierarchy:**
- **Goal** (G prefix) - Large initiatives containing multiple related tasks
- **Task** (W prefix) - Individual work items

**Note:** The system previously had separate Work/Defect types, but now uses a single unified "task" type for simplicity.

### Core Schema Fields

- title (string) - Task title
- description (text) - Detailed description
- status (enum: open, in_progress, blocked, review, completed)
- priority (enum: low, medium, high, critical)
- complexity (enum: trivial, low, medium, high, very_high)
- type (enum: task, goal) - Hierarchy level (task vs goal)
- identifier (string) - Human-readable ID (G1, W42, etc.)
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

**Task Creation:**
- [POST /api/tasks](../api/post_tasks.md) - Create a task or goal with nested child tasks
- [POST /api/tasks/batch](../api/post_tasks_batch.md) - Create multiple goals with nested tasks in one request

**Authentication:**
- Bearer token authentication
- Capability matching: Agent capabilities matched against task `required_capabilities`
- See [../api/README.md](../api/README.md) for authentication setup

### AI Workflow Integration

⚠️ **CRITICAL: Hook Execution Order**

Hooks MUST be executed in the exact order specified below. The most common mistake is calling `/complete` before executing `after_doing`, which breaks the workflow.

**Complete AI Workflow with Hooks (Claim → Execute → Complete → Review):**

1. **Discover tasks** - Call [GET /api/tasks/next](../api/get_tasks_next.md) to find available tasks

2. **Claim a task** - Call [POST /api/tasks/claim](../api/post_tasks_claim.md)
   - Receives `before_doing` hook metadata
   - Task moves to Doing column

3. **Execute `before_doing` hook** (blocking, 60s timeout)
   - Example: Pull latest code, setup workspace
   - **Execute this BEFORE starting work**

4. **Work on the task** - Implement changes, write code, run tests
   - Do the actual implementation work
   - Write tests, fix bugs, add features

5. **⚠️ CRITICAL: Execute `after_doing` hook FIRST** (blocking, 120s timeout)
   - Example: Run tests, build project, lint code
   - **YOU MUST EXECUTE THIS BEFORE CALLING `/complete`**
   - If this fails, DO NOT call `/complete` - fix the issues first
   - This validates your work is ready for completion

6. **Complete the task** - Call [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md)
   - **Only call this AFTER `after_doing` hook succeeds**
   - Receives `after_doing`, `before_review`, and optionally `after_review` hooks in response
   - The `after_doing` hook in the response should already be completed (see step 5)
   - Task moves to Review column (or Done if `needs_review=false`)

7. **Execute `before_review` hook** (non-blocking, 60s timeout)
   - Example: Create PR, generate documentation
   - Execute this after `/complete` succeeds

8. **⚠️ STOP HERE if `needs_review=true`**
   - **DO NOT execute `after_review` hook yet!**
   - Wait for human reviewer to approve/reject the task
   - Human reviewer sets review_status through the UI or API
   - Proceed to step 9 only when notified of approval

9. **Finalize review** - Call [PATCH /api/tasks/:id/mark_reviewed](../api/patch_tasks_id_mark_reviewed.md)
   - **Only call this after receiving human approval** (if `needs_review=true`)
   - Or call immediately after step 7 (if `needs_review=false`)
   - If approved: receives `after_review` hook, task moves to Done
   - If changes requested: task returns to Doing, repeat from step 4

10. **Execute `after_review` hook** (non-blocking, 60s timeout)
    - Example: Deploy to production, notify stakeholders
    - **Execute ONLY after `/mark_reviewed` returns approved status**
    - Or execute immediately after step 7 if `needs_review=false`

11. **Dependencies automatically unblock** - Next tasks become available

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

**⚠️ COMMON MISTAKE TO AVOID:**

**❌ WRONG ORDER:**
```
1. Claim task → receive before_doing hook
2. Execute before_doing hook
3. Do work
4. Call /complete endpoint ← TOO EARLY!
5. Receive after_doing hook
6. Try to execute after_doing hook ← Tests fail, but task already completed!
```

**✅ CORRECT ORDER:**
```
1. Claim task → receive before_doing hook
2. Execute before_doing hook
3. Do work
4. Execute after_doing hook (tests, format, lint) ← DO THIS FIRST!
5. Call /complete endpoint ← Only after step 4 succeeds
6. Receive after_doing, before_review, after_review hooks
7. Execute before_review hook
8. IF needs_review=false: Execute after_review hook immediately
   IF needs_review=true: STOP and wait for human approval
9. IF needs_review=true: Wait for approval notification
10. Call /mark_reviewed (when approved)
11. Execute after_review hook (after approval received)
```

The `/complete` endpoint returns the `after_doing` hook in its response, but you should have **already executed it** before calling `/complete`. Think of the response as a confirmation, not an instruction.

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
- See [Hook System](#hook-system) section below for details

### Task Creation Patterns

**Creating a Goal with Child Tasks:**
```json
POST /api/tasks
{
  "task": {
    "title": "Implement search feature",
    "type": "goal",
    "complexity": "very_high",
    "priority": "high",
    "tasks": [
      {
        "title": "Add search schema",
        "complexity": "medium",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Build search UI",
        "complexity": "high",
        "required_capabilities": ["code_generation"]
      },
      {
        "title": "Write search tests",
        "complexity": "medium",
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
    "type": "task",
    "complexity": "low",
    "priority": "high",
    "needs_review": true
  }
}
```

See [POST /api/tasks](../api/post_tasks.md) for complete documentation.

### Task Completion

When completing a task, use [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md):

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "Implemented JWT authentication with refresh tokens. All tests passing."
}
```

**What happens:**
1. Task moves to Review column (or Done if `needs_review=false`)
2. Server returns hook metadata for:
   - `after_doing` (blocking) - Run tests, build
   - `before_review` (non-blocking) - Create PR
   - `after_review` (non-blocking, only if `needs_review=false`)
3. Agent executes hooks in order
4. If `needs_review=true`, wait for human review
5. Call [PATCH /api/tasks/:id/mark_reviewed](../api/patch_tasks_id_mark_reviewed.md) to finalize

See [PATCH /api/tasks/:id/complete](../api/patch_tasks_id_complete.md) for complete documentation.

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
- **Blocking hooks** - Tests must pass before task completion
- **Non-blocking hooks** - Deploy/notify without blocking workflow

**Coordination:**
- **Dependencies** - Server handles blocking/unblocking automatically
- **Goal hierarchy** - Group related tasks, track overall progress
- **Unclaim mechanism** - Release tasks if blocked or unable to complete
- **Review status** - Track approved/changes_requested/rejected decisions

This creates a **Kanban board optimized for AI agents** - structured workflow with hooks, flexible collaboration with humans.

### Getting Started

1. **Read the API documentation** - [../api/README.md](../api/README.md)
2. **Set up authentication** - Create `.stride_auth.md` with your API token
3. **Configure hooks** - Create `.stride.md` with your workflow hooks
4. **Start claiming tasks** - Use the API to claim, complete, and review tasks

### Related Documentation

- [../api/README.md](../api/README.md) - Complete API documentation for agents
- Individual endpoint docs in [../api/](../api/) directory
- See CHANGELOG.md for version history and recent changes
