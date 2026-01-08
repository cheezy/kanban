# Stride

> An AI-native workflow application built with Phoenix LiveView

---

## 🚀 Quick Start

**New to Stride?** → **[Get Started with AI Agents](docs/GETTING-STARTED-WITH-AI.md)**

This comprehensive guide walks you through:

- Creating your first AI-optimized board
- Setting up API access for AI agents
- Configuring workflow hooks
- Understanding the human-AI collaboration workflow

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
- `parent_id` - Parent goal (for hierarchical tasks)
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
- `GET /api/tasks/next` - Get next available task ready to work
- `GET /api/tasks` - List all tasks (optionally filtered by column)
- `GET /api/tasks/:id` - Get task details (supports identifiers like "W14")
- `GET /api/tasks/:id/tree` - Get task tree (goals with children)
- `GET /api/tasks/:id/dependencies` - Get full dependency tree
- `GET /api/tasks/:id/dependents` - Get tasks that depend on this task
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

### Getting Started

- **[Getting Started with AI Agents](docs/GETTING-STARTED-WITH-AI.md)** ⭐ Start here!
- [Task Writing Guide](docs/TASK-WRITING-GUIDE.md) - How to write effective tasks for AI

### Workflow & Integration

- [AI Workflow Guide](docs/AI-WORKFLOW.md) - Complete API workflow for agents
- [Agent Hook Execution Guide](docs/AGENT-HOOK-EXECUTION-GUIDE.md) - Deep dive into hooks
- [Review Workflow](docs/REVIEW-WORKFLOW.md) - Mastering the review process
- [Unclaim Tasks Guide](docs/UNCLAIM-TASKS.md) - When and how to unclaim tasks

### Configuration & Management

- [Authentication Guide](docs/AUTHENTICATION.md) - API token setup and management
- [Agent Capabilities](docs/AGENT-CAPABILITIES.md) - Understanding capabilities
- [Estimation & Feedback](docs/ESTIMATION-FEEDBACK.md) - Improving task estimates

### API Reference

- [API Documentation](docs/api/README.md) - Complete API reference
- [GET /api/tasks](docs/api/get_tasks.md) - List tasks
- [POST /api/tasks](docs/api/post_tasks.md) - Create tasks
- [POST /api/tasks/claim](docs/api/post_tasks_claim.md) - Claim tasks
- [PATCH /api/tasks/:id/complete](docs/api/patch_tasks_id_complete.md) - Complete tasks

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

[Add your license here]

---

**Built with Phoenix. Designed for AI. Made for humans.**
