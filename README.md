# Stride

> An AI-native workflow application built with Phoenix LiveView

Hosted at https://StrideLikeABoss.com

---

## 🚀 Quick Start

**New to Stride?** → **[Get Started with AI Agents](docs/GETTING-STARTED-WITH-AI.md)**

This comprehensive guide walks you through:

- Creating your first AI-optimized board
- Setting up API access for AI agents
- Configuring workflow hooks
- Understanding the human-AI collaboration workflow

### Local development setup

Before running `mix phx.server` (or any dev work that signs cookies /
LiveView tokens), export a per-developer `SECRET_KEY_BASE`. The dev
environment no longer ships with a shared signing key — every
contributor previously had the same one, which is unsafe if a dev
server is ever exposed externally (ngrok, tunneling, port forwarding).

```bash
# generate once and store it in your shell rc / direnv:
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
```

If you don't set the variable, `config/dev.exs` falls back to a
clearly-labeled placeholder so non-server tasks (`mix help`,
`mix deps.audit`, etc.) keep working — but **do not** start
`mix phx.server` against an externally-reachable network without
setting your own key first.

### Encryption key (`ENCRYPTION_KEY`)

Secrets stored in the database, such as each user's two-factor
authenticator secret, are encrypted with AES-256-GCM using
`ENCRYPTION_KEY`: 32 random bytes, base64-encoded.

```bash
# generate one key per environment:
openssl rand -base64 32
```

- **Production needs it.** A production release refuses to boot (and
  the migration release command fails) when `ENCRYPTION_KEY` is missing
  or does not decode to exactly 32 bytes. Set it as a secret on each
  deployed app before deploying, e.g.
  `fly secrets set ENCRYPTION_KEY="$(openssl rand -base64 32)" -a <app>`.
- **Each environment needs its own key.** Never copy one environment's
  key into another.
- **Keep it, and back it up.** Losing or replacing the key makes every
  stored authenticator secret unreadable, so every user who turned on
  two-factor authentication has to set it up again. After a lost or
  replaced key, clear the unreadable rows with `DELETE FROM user_totps;`
  so those users can enroll again.
- **Development and test need nothing.** `config/dev.exs` and
  `config/test.exs` use fixed, public keys.

### Metrics retention (`retention_days`)

Stored telemetry metrics (the `metrics_events` table) carry user ids, board
ids and request paths. A daily job, `Kanban.Metrics.RetentionWorker`, removes
rows older than the retention period at 03:23 UTC. The period is 90 days by
default and is set in `config/config.exs`:

```elixir
config :kanban, Kanban.Metrics.RetentionWorker, retention_days: 90, batch_size: 1_000
```

- **Change `retention_days` to keep metrics longer or shorter.** It must be a
  positive whole number of days. A missing or invalid value removes nothing
  and logs a `metrics retention skipped` warning.
- **`batch_size` is the number of rows removed per `DELETE`**, so a large
  backlog never holds one long lock on the table. The first run after an
  upgrade can take several batches.
- **The admin users page counts activity within the retention period.** Its
  per-user counts are read from `metrics_events`, so older activity drops out.
- **Audit events are not affected.** The `audit_events` table has its own
  retention rules; see [Audit log hardening](docs/audit-log-hardening.md).
- **The schedule starts on the next server start.** The job is an Oban cron
  entry, and a running server does not pick up new cron entries.

See [Telemetry Events](docs/telemetry.md#metrics-retention) for the event the
job emits.

---

## What is Stride?

Stride is a kanban board application designed from the ground up for seamless human-AI collaboration. While it provides a beautiful visual interface for humans to manage tasks and projects, its real power lies in its API-first architecture that enables AI agents to autonomously claim, complete, and manage work.

**The Vision**: AI agents handle repetitive implementation work while humans focus on architecture, design decisions, and quality oversight. Together, you achieve more than either could alone.

## Key Features

### For Humans

- **Beautiful Kanban board UI** built with Phoenix LiveView
- **Real-time updates** across all connected clients
- **AI-Optimized Boards** with standardized workflow columns
- **Review workflow** to approve or request changes on AI work
- **Task dependencies** with automatic blocking
- **Hierarchical tasks** (Goals → Tasks)
- **Mobile responsive** with modern Tailwind CSS v4 design

### For AI Agents

- **RESTful JSON API** for programmatic task management
- **Bearer token authentication** with capability-based permissions
- **Atomic task claiming** with automatic conflict prevention
- **Rich task metadata** for effective implementation:
  - `why`, `what`, `where_context` - Planning & Context
  - `key_files` - Files to modify (prevents merge conflicts)
  - `verification_steps` - Commands to verify completion
  - `testing_strategy` - Overall testing approach
  - `security_considerations` - Security requirements
  - `acceptance_criteria` - Definition of "done"
  - `patterns_to_follow` - Code patterns to replicate
  - `database_changes`, `validation_rules` - Implementation guidance
  - `telemetry_event`, `metrics_to_track`, `logging_requirements` - Observability
  - And more...
- **Client-side workflow hooks** for automation:
  - `before_doing` - Pull latest code, setup
  - `after_doing` - Run tests (blocking - must pass)
  - `before_review` - Create PR, generate docs
  - `after_review` - Merge PR, deploy
- **Dependency resolution** to find ready work
- **Continuous work loop** - agents claim and complete tasks until hitting review

## The AI Workflow

```text
1. Human or AI creates structured tasks in Backlog column
2. Human reviews and moves tasks to Ready column
3. AI queries /api/tasks/claim to get next available task
4. AI executes before_doing hook (pull latest code)
5. AI implements the task
6. AI executes after_doing hook (tests must pass)
7. AI marks complete - task moves to Review or Done:
   - IF needs_review=true → Review column (wait for human)
   - IF needs_review=false → Done column (claim next task immediately)
8. For reviewed tasks:
   - Human reviews in Stride UI and sets review_status
   - AI calls /api/tasks/:id/mark_reviewed to finalize
   - If approved → Done column, execute after_review hook
   - If changes requested → Back to Ready column for fixes
9. Dependencies automatically unblock when tasks complete
10. AI continues claiming tasks until hitting needs_review=true
```

## Task Schema: AI-Optimized

Tasks in Stride contain everything an AI needs to implement effectively:

### Core Fields

- `title` - Clear, actionable task name
- `description` - Detailed description
- `type` - `work`, `defect`, or `goal`
- `status` - `open`, `in_progress`, `completed`, `blocked`
- `priority` - `low`, `medium`, `high`, `critical`
- `complexity` - `small` (<1 hour), `medium` (1-2 hours), `large` (>2 hours)
- `needs_review` - Whether task requires human review before completion

### Planning & Context

- `why` - Why this task matters (business justification)
- `what` - What needs to be done (concise summary)
- `where_context` - Where in the codebase this work happens
- `estimated_files` - Estimated number of files to modify
- `patterns_to_follow` - Specific coding patterns to replicate
- `database_changes` - Database schema changes required
- `validation_rules` - Input validation requirements

### Implementation Guidance

- `acceptance_criteria` - Specific, testable conditions for "done"
- `key_files` - Files that will be modified (prevents conflicts)
- `verification_steps` - Commands and manual steps to verify success
- `technology_requirements` - Required technologies or libraries
- `pitfalls` - Common mistakes to avoid
- `out_of_scope` - What NOT to include

### Quality & Observability

- `testing_strategy` - Overall testing approach (JSON object)
- `security_considerations` - Security concerns and requirements
- `integration_points` - Systems or APIs this touches
- `telemetry_event` - Telemetry events to emit
- `metrics_to_track` - Metrics to instrument
- `logging_requirements` - What to log for debugging
- `error_user_message` - User-facing error messages
- `error_on_failure` - How to handle failures

### Tracking & Metadata

- `dependencies` - Task identifiers that must complete first
- `parent_id` - Parent goal (for hierarchical tasks). Read-only through the API: the server sets it only when a goal is created with nested tasks or through `POST /api/tasks/batch`, so a single create cannot attach a task to an existing goal. A human can change it in the board UI task form
- `required_capabilities` - Required agent capabilities
- `created_by_agent` - Tracks AI vs human creation
- `completed_by_agent` - Tracks AI vs human completion
- `review_status` - `approved`, `changes_requested`, `rejected`
- `review_notes` - Reviewer feedback

See the [Task Writing Guide](docs/TASK-WRITING-GUIDE.md) for details on creating effective tasks.

**✨ Claude Code Skills:** Agents receive workflow enforcement skills via the onboarding endpoint:
- `stride-claiming-tasks`: Ensures proper prerequisite verification and hook execution before claiming
- `stride-completing-tasks`: Ensures proper hook execution order and prevents quality gate bypasses
- `stride-creating-tasks`: Ensures comprehensive task specifications and prevents exploration failures
- `stride-creating-goals`: Ensures proper goal structure and prevents batch creation format errors

## API Endpoints

### Task Discovery & Management

- `GET /api/agent/onboarding` - Complete onboarding guide for AI agents
- `GET /api/openapi.json` - Machine-readable OpenAPI 3.1 description of every API route (no auth required); see [docs/api/get_openapi_json.md](docs/api/get_openapi_json.md)
- `GET /api/tasks/next` - Get next available task ready to work
- `GET /api/tasks` - List tasks, with optional filters (column, label, status, type, priority, assignee, parent goal, updated since) and cursor pagination
- `GET /api/tasks/:id` - Get task details (supports identifiers like "W14")
- `GET /api/tasks/:id/tree` - Get task tree (goals with children)
- `GET /api/tasks/:id/dependencies` - Get full dependency tree
- `GET /api/tasks/:id/dependents` - Get tasks that depend on this task
- `GET /api/tasks/:id/comments` - Read a task's most recent comments (`limit`, default 50), oldest first ([docs](docs/api/get_tasks_id_comments.md))
- `POST /api/tasks/:id/comments` - Add a comment as the token's user, attributed to your agent name ([docs](docs/api/post_tasks_id_comments.md))
- `POST /api/tasks` - Create task(s) or goal with nested tasks
- `PATCH /api/tasks/:id` - Update task fields

### Workflow Operations

- `POST /api/tasks/claim` - Claim next available task (with before_doing hook)
- `POST /api/tasks/:id/unclaim` - Release claimed task back to Ready
- `PATCH /api/tasks/:id/complete` - Complete task (with after_doing, before_review hooks)
- `PATCH /api/tasks/:id/mark_reviewed` - Finalize reviewed task (with after_review hook)

### Authentication

Bearer token with capability-based permissions:

```bash
Authorization: Bearer stride_abc123def456...
```

## Design Principles

### 1. AI-Native, Not AI-Bolted-On

Every feature considers "how will an AI agent use this?" first. The API is the primary interface, and the UI is built on top of it.

### 2. Structured Context Over Free-Form

JSON schemas for technical context make tasks machine-readable and actionable. No guessing, no assumptions.

### 3. Conflict Prevention via Key Files

Tasks specify which files they'll modify. Only one task can modify a file at a time, preventing merge conflicts automatically.

### 4. Client-Side Hook Execution

Hooks execute on the agent's machine, not the server. Agents maintain full control over their execution environment.

### 5. Capability-Based Permissions

Agents specify their capabilities (`code_generation`, `testing`, etc.) and only see tasks matching their skills.

### 6. Human-in-the-Loop Review

Humans maintain control through the review workflow. AI handles implementation, humans approve quality.

## Documentation

Start with the [documentation index](docs/README.md). It lists every doc in `docs/` by audience and marks which ones are historical records rather than current guidance. The guides for board owners, AI agent integrators and Organization admins are listed below.

### Getting Started

- **[Getting Started with AI Agents](docs/GETTING-STARTED-WITH-AI.md)** ⭐ Start here!
- [Task Writing Guide](docs/TASK-WRITING-GUIDE.md) - How to write effective tasks for AI

### Account and Board Settings

- [Two-Factor Authentication](docs/TWO-FACTOR-AUTHENTICATION.md) - Add a second sign-in factor to your account
- [Task Form Field Visibility](docs/TASK-FORM-FIELD-VISIBILITY.md) - Which fields the task form shows and how a board owner turns optional fields on or off

### Workflow & Integration

- [AI Workflow Guide](docs/AI-WORKFLOW.md) - Complete API workflow for agents
- [Agent Hook Execution Guide](docs/AGENT-HOOK-EXECUTION-GUIDE.md) - Deep dive into hooks
- [Review Workflow](docs/REVIEW-WORKFLOW.md) - Mastering the review process
- [Unclaim Tasks Guide](docs/UNCLAIM-TASKS.md) - When and how to unclaim tasks
- [Webhooks and Slack](docs/webhooks.md) - Send a board's task events to your own systems or a Slack or Discord channel, and verify webhook signatures
- [Stride MCP Server](docs/MCP.md) - Use Stride through its Model Context Protocol server instead of hand-built API calls
- [Multi-Agent Instructions](docs/MULTI-AGENT-INSTRUCTIONS.md) - Which instruction files each supported AI coding assistant uses
- [How Agents Remember Stride Context](docs/AGENT-MEMORY-SOLUTION.md) - Keeping the Stride workflow in an agent's mind between sessions
- [Windows Setup Guide](docs/WINDOWS-SETUP.md) - Running Stride agents on Windows with WSL2, PowerShell or Git Bash

### Multi-Agent Instruction Files

- [AGENTS.md instructions](docs/multi-agent-instructions/AGENTS.md) - For assistants that read an `AGENTS.md` file
- [GitHub Copilot instructions](docs/multi-agent-instructions/copilot-instructions.md) - For GitHub Copilot
- [Gemini Code Assist instructions](docs/multi-agent-instructions/GEMINI.md) - For Gemini Code Assist
- [Stride skill (single file)](docs/multi-agent-instructions/SKILL.md) - The `stride` skill as one file, for assistants such as OpenCode
- [stride-workflow skill](docs/multi-agent-instructions/skills/stride-workflow/SKILL.md) - The orchestrator that runs a task from claim to completion
- [stride-claiming-tasks skill](docs/multi-agent-instructions/skills/stride-claiming-tasks/SKILL.md) - Claiming a task
- [stride-completing-tasks skill](docs/multi-agent-instructions/skills/stride-completing-tasks/SKILL.md) - Completing a task
- [stride-creating-tasks skill](docs/multi-agent-instructions/skills/stride-creating-tasks/SKILL.md) - Creating work tasks and defects
- [stride-creating-goals skill](docs/multi-agent-instructions/skills/stride-creating-goals/SKILL.md) - Creating goals with nested tasks
- [stride-enriching-tasks skill](docs/multi-agent-instructions/skills/stride-enriching-tasks/SKILL.md) - Filling in a sparse task before work starts
- [stride-subagent-workflow skill](docs/multi-agent-instructions/skills/stride-subagent-workflow/SKILL.md) - Deciding when to dispatch subagents during a task

### Configuration & Management

- [Authentication Guide](docs/AUTHENTICATION.md) - API token setup and management
- [Agent Capabilities](docs/AGENT-CAPABILITIES.md) - Understanding capabilities
- [Estimation & Feedback](docs/ESTIMATION-FEEDBACK.md) - Improving task estimates
- [Telemetry Events](docs/telemetry.md) - Every telemetry event, its privacy rule, attaching a handler and metrics retention
- [Organizations Launch Runbook](docs/organizations-launch-runbook.md) - The ordered launch-day steps for enforcing plans, the verification checklist, rollback and the weekly locked-feature click query

### Organization Administration

- [Single Sign-On](docs/single-sign-on.md) - Let an Organization's members sign in through your identity provider
- [SCIM Provisioning](docs/scim-provisioning.md) - Manage an Organization's members from your identity provider
- [Organization Security Policies](docs/organization-security-policies.md) - Require two-factor authentication and set how long audit events are kept

### Plugin Contracts

- [Completion Review Report Contract](docs/completion-contract.md) - What a fully-populated review report on a completion payload must contain
- [Per-File Diff Contract](docs/diff-contract.md) - The shape of the per-file diff carried on a completion payload
- [Matrix Row Refusal Contract](docs/matrix-row-refusal-contract.md) - What every agent does with a behaviour/test matrix row it must not follow

### API Reference

- [API Documentation](docs/api/README.md) - Complete API reference
- [GET /api/agent/onboarding](docs/api/get_agent_onboarding.md) - Public onboarding information for a new agent
- [GET /api/boards](docs/api/get_boards.md) - List the boards a token can be used on
- [GET /api/openapi.json](docs/api/get_openapi_json.md) - Machine-readable OpenAPI description of the API
- [GET /api/tasks](docs/api/get_tasks.md) - List tasks (filters, cursor pagination)
- [GET /api/tasks/:id](docs/api/get_tasks_id.md) - Fetch one task
- [GET /api/tasks/next](docs/api/get_tasks_next.md) - Find the next task to claim
- [GET /api/tasks/:id/comments](docs/api/get_tasks_id_comments.md) - List a task's comments
- [GET /api/tasks/:id/dependencies](docs/api/get_tasks_id_dependencies.md) - List a task's dependencies
- [GET /api/tasks/:id/dependents](docs/api/get_tasks_id_dependents.md) - List the tasks that depend on a task
- [GET /api/tasks/:id/tree](docs/api/get_tasks_id_tree.md) - Fetch a goal or task with its children
- [PATCH /api/tasks/:id](docs/api/patch_tasks_id.md) - Update a task
- [PATCH /api/tasks/:id/complete](docs/api/patch_tasks_id_complete.md) - Complete tasks
- [PATCH /api/tasks/:id/mark_done](docs/api/patch_tasks_id_mark_done.md) - Move a task from Review straight to Done
- [PATCH /api/tasks/:id/mark_reviewed](docs/api/patch_tasks_id_mark_reviewed.md) - Record the outcome of a human review
- [POST /api/tasks](docs/api/post_tasks.md) - Create tasks
- [POST /api/tasks/batch](docs/api/post_tasks_batch.md) - Create several goals in one request
- [POST /api/tasks/claim](docs/api/post_tasks_claim.md) - Claim tasks
- [POST /api/tasks/:id/comments](docs/api/post_tasks_id_comments.md) - Add a comment to a task
- [POST /api/tasks/:id/unclaim](docs/api/post_tasks_id_unclaim.md) - Release a claimed task
- [PUT /api/tasks/:id/changed_files](docs/api/put_tasks_id_changed_files.md) - Upload the per-file diff snapshot for a task

## Project Guidelines

See [AGENTS.md](AGENTS.md) for detailed development guidelines including:

- Phoenix/LiveView patterns
- Ecto best practices
- Testing strategies
- Security considerations
- UI/UX conventions

## Philosophy

**Tasks are conversations.** When a human creates a task for AI, or AI creates a task for review, the task itself contains all the context needed for implementation. No back-and-forth, no assumptions, no guessing.

**AI is a collaborator, not a tool.** Stride treats AI agents as first-class participants in the development workflow, capable of planning, creating, and managing work independently.

**Structure enables autonomy.** By embedding rich, structured context in tasks, we enable AI to work more autonomously while maintaining quality and alignment.

**Humans focus on what matters.** Instead of writing every line of code, humans focus on architecture, design decisions, code review, and quality oversight. AI handles the repetitive implementation work.

## What Makes Stride Different?

Traditional project management tools were built for humans first, with AI integration as an afterthought. Stride flips this model:

- **Atomic Task Claiming** - Agents claim tasks atomically with automatic conflict prevention
- **Client-Side Hooks** - Full control over execution environment (tests, builds, PRs)
- **Rich Task Metadata** - 20+ fields of structured context for effective implementation
- **Capability Matching** - Agents only see tasks they're qualified to handle
- **Continuous Work Loop** - Agents work continuously until hitting review
- **File Conflict Prevention** - `key_files` ensures only one task modifies a file at a time
- **Dependency-Aware** - Tasks know what blocks them and what they block

## Contributing

Stride welcomes contributions! Whether you're human or AI, if you're improving the codebase, you're contributing.

See [AGENTS.md](AGENTS.md) for development guidelines.

## License

Stride is released under the MIT License. See [LICENSE](LICENSE).

---

**Built with Phoenix. Designed for AI. Made for humans.**
