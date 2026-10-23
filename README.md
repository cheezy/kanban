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

To run Stride itself on your machine you need:

- **Erlang/OTP 28.5.0.2 and Elixir 1.20.2**, the versions pinned in
  `.tool-versions`. asdf and mise read that file.
- **PostgreSQL** on `localhost`, with user `postgres` and password
  `postgres`. The development database is `kanban_dev`. CI uses
  PostgreSQL 16.
- **Node.js and npm**, to install the JavaScript packages in
  `assets/package.json`. `mix setup` does not install them.
- **Google Chrome**, which Stride starts headless to export metrics as PDFs. The
  test suite uses it too.

Then, from the repository root:

```bash
# JavaScript packages the asset build bundles:
npm install --prefix assets

# deps.get, ecto.setup (create, migrate, seed), assets.setup and assets.build:
mix setup
```

Before running `mix phx.server` (or any dev work that signs cookies /
LiveView tokens), export a per-developer `SECRET_KEY_BASE`. The dev
environment no longer ships with a shared signing key — every
contributor previously had the same one, which is unsafe if a dev
server is ever exposed externally (ngrok, tunneling, port forwarding).

```bash
# generate once and store it in your shell rc / direnv:
export SECRET_KEY_BASE="$(mix phx.gen.secret)"

# start the server at http://localhost:4000 (set PORT to use another port):
mix phx.server
```

Without the variable, `mix phx.server`, `iex -S mix phx.server` and any
run with `PHX_SERVER` set refuse to start and tell you to set it. So does
any other command whose arguments include `phx.server`, such as
`mix help phx.server`. Other Mix tasks (`mix help`, `mix deps.audit`,
etc.) keep working on a clearly-labeled placeholder in `config/dev.exs`.

The seed file creates no data. Register an account at `/users/register`
and confirm it from the development mailbox at `/dev/mailbox`.

Run the test suite with `mix test`, which creates and migrates the test
database first, and run `mix precommit` before you commit. It compiles,
formats, checks translations and dark-mode colours, runs the tests and
runs Credo.

### Encryption key (`ENCRYPTION_KEY`)

Secrets stored in the database are encrypted with AES-256-GCM using
`ENCRYPTION_KEY`: 32 random bytes, base64-encoded. Today that covers
each user's two-factor authenticator secret and each Organization's
OIDC single sign-on client secret. Two-factor recovery codes are stored
only as an HMAC keyed from it.

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
  so those users can enroll again. Unused recovery codes stop matching,
  and stored OIDC client secrets become unreadable too.
- **Webhook secrets use `SECRET_KEY_BASE`, not this key.** Webhook
  endpoint URLs and signing secrets are encrypted with a key derived
  from `SECRET_KEY_BASE`, so replacing that value makes them unreadable
  and each endpoint has to be set up again.
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
- **MCP server** at `POST /api/mcp`, using the same Bearer token, for
  agents that speak the Model Context Protocol
  ([Stride MCP Server](docs/MCP.md))
- **Bearer token authentication** with a board token or a
  [workspace token](docs/AUTHENTICATION.md#workspace-tokens); the
  token's capabilities decide which tasks it is offered
  ([Authentication Guide](docs/AUTHENTICATION.md))
- **Atomic task claiming**: a claim succeeds for one agent only, and
  expires after 60 minutes if the task is not completed. An expired
  claim stays in Doing until it is unclaimed or moved back to Ready
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
- **Client-side workflow hooks** for automation. All five are blocking,
  and Stride gives each a 10-minute timeout:
  - `before_doing` - Pull latest code, setup
  - `after_doing` - Run tests (must pass)
  - `before_review` - Create PR, generate docs
  - `after_review` - Merge PR, deploy
  - `after_goal` - Runs once after the last task of a goal is done; the
    goal moves to Done when it reports success
- **Dependency resolution** to find ready work
- **Continuous work loop** - agents claim and complete tasks until hitting review

### For Organizations

- **Organizations and workspaces**: a site admin creates an Organization,
  and its org-admins manage shared workspaces (members, boards,
  invitations and [workspace tokens](docs/AUTHENTICATION.md#workspace-tokens))
  from the workspace settings. Boards outside an Organization live in each
  user's own personal workspace. See the
  [Organizations Launch Runbook](docs/organizations-launch-runbook.md) for
  turning on paid plans
- **[Workspace export](docs/workspace-export.md)**: an org-admin can
  download a zip of an Organization workspace (boards, columns, labels,
  tasks, comments, task history and memberships) from the Export section
  of the workspace settings. Each archive stays downloadable for 7 days.
  Personal workspaces have no export
- **[Webhooks, Slack and Discord](docs/webhooks.md)**: send a board's
  task events to your own systems or a chat channel
- **[Single sign-on](docs/single-sign-on.md)** through OIDC or SAML 2.0,
  and **[SCIM provisioning](docs/scim-provisioning.md)** of members from
  your identity provider
- **[Two-factor authentication](docs/TWO-FACTOR-AUTHENTICATION.md)**,
  which an Organization can require of its members
  ([Organization Security Policies](docs/organization-security-policies.md))

The Organization plan's paid features are notifications, the
Organization audit log, single sign-on, workspaces, bulk actions,
integrations (webhooks, Slack and Discord), the task telemetry fields
and the MCP server. Workspaces, single sign-on and the audit log always
need an Organization, because they belong to one. The others are
open to everyone until a deployment sets `STRIDE_PLANS_ENFORCED=true`;
from then on they need an Organization, and a board gets them only when
it is in an Organization workspace.
[What a free board cannot do](docs/organizations.md#what-a-free-board-cannot-do)
says what each lock does.

## The AI Workflow

```text
1. Human or AI creates structured tasks in Backlog column
2. Human reviews and moves tasks to Ready column
3. AI executes the before_doing hook (pull latest code), then calls
   POST /api/tasks/claim with its result to claim the next available
   task, or one named by identifier (GET /api/tasks/next only looks)
4. AI implements the task
5. AI executes the after_doing hook (tests must pass) and the
   before_review hook, then calls PATCH /api/tasks/:id/complete with
   both results - task moves to Review or Done:
   - IF needs_review=true → Review column (wait for human)
   - IF needs_review=false → Done column (claim next task immediately)
6. For reviewed tasks:
   - Human reviews in Stride UI and records review_status
   - If the human clicks Approve in the Review queue, the review is
     finished: the task is already in Done and the AI does not call
     mark_reviewed (it would get a 422)
   - Otherwise the task stays in Review, and the AI finalizes it with
     PATCH /api/tasks/:id/mark_reviewed:
   - If approved → the AI executes the after_review hook first and
     sends its result; the task moves to Done
   - If changes requested or rejected → the AI does NOT execute the
     after_review hook and sends a placeholder after_review_result
     (exit_code 0); the task goes back to the Doing column, still
     claimed, for fixes
7. When the last task of a goal is done, AI executes the after_goal
   hook and reports it with PATCH /api/tasks/:id/after_goal; the goal
   moves to Done when it succeeds, or after a grace window if no
   report arrives
8. Dependencies automatically unblock when tasks complete
9. AI continues claiming tasks until hitting needs_review=true

Stride refuses a claim, completion or review call whose hook result is
missing or has a non-zero exit code.
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
- `estimated_files` - Estimated number of files to modify, as text such as `2`, `3-5` or `5+`
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
- `metrics_to_track` - Metrics to instrument. While paid plans are
  enforced, only boards in an Organization workspace store this field and
  `telemetry_event`; other boards accept and drop them
- `logging_requirements` - What to log for debugging
- `error_user_message` - User-facing error messages
- `error_on_failure` - How to handle failures

### Tracking & Metadata

- `dependencies` - Task identifiers that must complete first
- `parent_id` - Parent goal (for hierarchical tasks). Read-only through the API: the server sets it only when a goal is created with nested tasks or through `POST /api/tasks/batch`, so a single create cannot attach a task to an existing goal. A human can change it in the board UI task form
- `required_capabilities` - Required agent capabilities
- `created_by_agent` - Tracks AI vs human creation
- `completed_by_agent` - Tracks AI vs human completion
- `review_status` - `pending`, `approved`, `changes_requested`, `rejected`
- `review_notes` - Reviewer feedback

See the [Task Writing Guide](docs/TASK-WRITING-GUIDE.md) for details on creating effective tasks.

**✨ Claude Code Skills:** Claude Code agents get the workflow skills from the Stride plugin. Run `/plugin marketplace add cheezy/stride-marketplace`, then `/plugin install stride@stride-marketplace`; the onboarding endpoint gives the same instructions ([Install the Stride Plugin (Claude Code)](docs/GETTING-STARTED-WITH-AI.md#install-the-stride-plugin-claude-code)). The plugin includes seven skills:
- `stride-workflow`: The orchestrator that runs a task from claim to completion and calls the skills below
- `stride-claiming-tasks`: Ensures proper prerequisite verification and hook execution before claiming
- `stride-completing-tasks`: Ensures proper hook execution order and prevents quality gate bypasses
- `stride-creating-tasks`: Ensures comprehensive task specifications and prevents exploration failures
- `stride-creating-goals`: Ensures proper goal structure and prevents batch creation format errors
- `stride-enriching-tasks`: Fills in a sparse task before work starts
- `stride-subagent-workflow`: Decides when to dispatch subagents during a task

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
- `GET /api/boards` - List the boards the token can be used on ([docs](docs/api/get_boards.md))
- `POST /api/tasks` - Create a task, or a goal with nested tasks
- `POST /api/tasks/batch` - Create several goals with their tasks in one request (root key `goals`) ([docs](docs/api/post_tasks_batch.md))
- `PATCH /api/tasks/:id` - Update task fields (`PUT /api/tasks/:id` does the same)

### Workflow Operations

- `POST /api/tasks/claim` - Claim the next available task, or the one named by `identifier` (with before_doing hook result)
- `POST /api/tasks/:id/unclaim` - Release claimed task back to Ready
- `PATCH /api/tasks/:id/complete` - Complete task (with after_doing, before_review hook results)
- `PATCH /api/tasks/:id/mark_reviewed` - Finalize reviewed task (with the after_review hook result on an approval, or a placeholder result on changes requested or rejected — see [docs](docs/api/patch_tasks_id_mark_reviewed.md))
- `PATCH /api/tasks/:id/mark_done` - Move a task from Review straight to Done ([docs](docs/api/patch_tasks_id_mark_done.md))
- `PUT /api/tasks/:id/changed_files` - Upload the per-file diff snapshot for a task ([docs](docs/api/put_tasks_id_changed_files.md))
- `PATCH /api/tasks/:id/after_goal` - Report the after_goal hook result for a goal whose last task is done
- `GET /api/tasks/:id/after_goal_status` - Read a goal's after_goal status

### MCP

- `POST /api/mcp` - The Model Context Protocol endpoint, authenticated with the same Bearer token ([Stride MCP Server](docs/MCP.md)). `GET` and `DELETE` on the same path answer `405`

The [API Documentation](docs/api/README.md) is the full reference, with a page for most endpoints.

### Authentication

Every endpoint except `GET /api/agent/onboarding` and `GET /api/openapi.json` needs a Bearer token. The token's capabilities decide which tasks it is offered:

```bash
Authorization: Bearer stride_dev_xxx
```

## Design Principles

### 1. AI-Native, Not AI-Bolted-On

Every feature considers "how will an AI agent use this?" first. The API is a first-class interface: the board UI, the REST API and the MCP server call the same application code, so a task behaves the same way whichever one changes it.

### 2. Structured Context Over Free-Form

Technical context is stored as structured fields rather than one free-form description: `key_files` and `verification_steps` are lists of objects, and `testing_strategy` is a JSON object whose shape Stride validates. Tasks stay machine-readable and actionable. No guessing, no assumptions.

### 3. Conflict Prevention via Key Files

Tasks specify which files they'll modify. When an agent asks for the next task, Stride skips a Ready task that lists a file already listed by an in-progress task in Doing or Review, so two agents are not handed the same file. The check covers `GET /api/tasks/next` and a claim without an `identifier`; a claim that names a task does not run it.

### 4. Client-Side Hook Execution

Hooks execute on the agent's machine, not the server. Agents maintain full control over their execution environment.

### 5. Capability-Based Permissions

Each API token carries capabilities (`code_generation`, `testing`, etc.). When an agent asks for the next task or claims one, Stride offers only tasks whose `required_capabilities` the token has all of. A task with no required capabilities is offered to every token, and a token with no capabilities is offered every task. Listing and reading tasks are not filtered.

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

The onboarding endpoint serves these files to tools that have no Stride
plugin. The retired GitHub Copilot, Gemini and single-file `stride` skill
files are listed under
[Retired instruction files](docs/README.md#retired-instruction-files) in
the documentation index; use each tool's Stride plugin instead.

- [AGENTS.md instructions](docs/multi-agent-instructions/AGENTS.md) - For assistants that read an `AGENTS.md` file
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

- [Organizations and Workspaces](docs/organizations.md) - What Organizations and workspaces are, the Free and Organization plans, roles, invitations, moving a board into a workspace and account deletion
- [Single Sign-On](docs/single-sign-on.md) - Let an Organization's members sign in through your identity provider
- [SCIM Provisioning](docs/scim-provisioning.md) - Manage an Organization's members from your identity provider
- [Organization Security Policies](docs/organization-security-policies.md) - Require two-factor authentication and set how long audit events are kept
- [Workspace Export](docs/workspace-export.md) - Download an Organization workspace as a zip archive, and import one into a self-hosted instance

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
- [GET /api/tasks/:id/after_goal_status](docs/api/get_tasks_id_after_goal_status.md) - Check whether completing a task armed its goal's `after_goal` hook
- [PATCH /api/tasks/:id](docs/api/patch_tasks_id.md) - Update a task
- [PATCH /api/tasks/:id/complete](docs/api/patch_tasks_id_complete.md) - Complete tasks
- [PATCH /api/tasks/:id/mark_done](docs/api/patch_tasks_id_mark_done.md) - Move a task from Review straight to Done
- [PATCH /api/tasks/:id/mark_reviewed](docs/api/patch_tasks_id_mark_reviewed.md) - Record the outcome of a human review
- [PATCH /api/tasks/:id/after_goal](docs/api/patch_tasks_id_after_goal.md) - Report the result of a goal's `after_goal` hook
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

- **Atomic Task Claiming** - A claim succeeds for one agent only and expires after 60 minutes
- **Client-Side Hooks** - Full control over execution environment (tests, builds, PRs)
- **Rich Task Metadata** - 20+ fields of structured context for effective implementation
- **Capability Matching** - Agents are offered only the tasks their token's capabilities cover
- **Continuous Work Loop** - Agents work continuously until hitting review
- **File Conflict Prevention** - The next-task query skips a task whose `key_files` overlap a task already in progress
- **Dependency-Aware** - Tasks know what blocks them and what they block

## Contributing

Stride welcomes contributions! Whether you're human or AI, if you're improving the codebase, you're contributing.

See [AGENTS.md](AGENTS.md) for development guidelines.

## License

Stride is released under the MIT License. See [LICENSE](LICENSE).

---

**Built with Phoenix. Designed for AI. Made for humans.**
