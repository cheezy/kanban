# Stride

> An AI-native workflow application built with Phoenix LiveView

---

## What is Stride?

At its core, Stride is a Kanban board application—but it's designed from the ground up to work seamlessly with AI agents. While it provides a beautiful visual interface for humans to manage tasks and projects, its real power lies in its API-first architecture that allows AI and team members to plan, create, and manage work programmatically in an AI driven workflow.

During development, we asked AI what would help them do their work more effectively. The roadmap for this application is based on the AI's suggestions.

## Vision: AI-First Workflow Management

Traditional project management tools treat AI integration as an afterthought. Stride flips this model:

- **AI agents can push planning results** directly into the app as structured tasks
- **Query for ready work** (like `GET /api/tasks/ready`) to find unblocked tasks
- **Track dependencies** automatically to prevent duplicate or blocked work
- **Rich technical context** embedded in tasks using structured JSON schemas
- **Seamless handoff** between AI and human work without friction

### The AI Workflow

```text
1. AI with the guidance of Product Owners or Technical Leads creates a structured plan with dependencies
2. AI POSTs the plan to Stride as a set of interconnected tasks in a Backlog column
3. Product Owners or Technical Leads reviews in the Kanban UI, refines as needed
4. Human moves the tasks or a feature into the Ready column
5. AI queries /api/tasks/next to find the next logical tasks
6. AI claims a task (PATCH status=in_progress) and moves it to the In Progress column
7. AI implements the task
8. AI marks it complete (PATCH status=completed) and moves it to the Review column for a Human to review
9. Human reviews the task and moves it to the Done column
10. Dependencies automatically unblock downstream work
```

## Key Features

### For Humans

- **Beautiful Kanban board UI** built with Phoenix LiveView
- **Real-time updates** across all connected clients
- **Task dependencies** with visual blocking indicators
- **Hierarchical tasks** (epics → features → tasks)
- **Priority management** (0-4 scale, 0 = highest)
- **Mobile responsive** with modern Tailwind CSS design

### For AI Agents

- **JSON API** for programmatic task management
- **Bearer token authentication** with scoped permissions
- **Structured technical context** (files to modify, patterns to follow, test scenarios)
- **Acceptance criteria** as machine-readable checkboxes
- **Dependency resolution** to find ready work
- **Rich metadata** for effective implementation

## Task Schema: AI-Optimized

Tasks in Stride aren't just titles and descriptions—they contain everything an AI needs to implement effectively:

### Core Fields

- `title` - Clear, actionable name
- `description` - The "what" and "why"
- `status` - open, in_progress, completed, blocked
- `priority` - 0-4 (0 = highest/critical)
- `task_type` - feature, bug, task, research, refactor

### AI-Specific Fields

- `acceptance_criteria` - Checkboxes defining "done"
- `technical_context` - Structured JSON including:
  - Files to modify/create/reference
  - Modules and dependencies
  - Database migrations needed
  - Patterns to follow/avoid
  - Testing strategy
  - Constraints and scope
  - UI/UX requirements
  - Performance considerations
  - Security concerns
- `scope` - Explicit in-scope and out-of-scope items
- `examples` - Input/output examples, test cases
- `dependencies` - Blocks/blocked-by relationships
- `created_by` - Tracks human vs AI origin (for analytics)

### Example Task JSON

```json
{
  "title": "Add priority filter to board view",
  "description": "Allow users to filter tasks by priority level",
  "type": "feature",
  "priority": 0,
  "status": "open",
  "acceptance_criteria": [
    "Filter by priority 0 shows only highest priority tasks",
    "Filter state persists in URL params",
    "Shows 'All' option to clear filter"
  ],
  "technical_context": {
    "files": {
      "to_modify": ["lib/kanban_web/live/board_live.ex"],
      "reference_files": ["lib/kanban_web/live/board_live/status_filter_component.ex"]
    },
    "patterns": {
      "to_follow": [
        {
          "pattern": "Use handle_event for filter changes",
          "location": "lib/kanban_web/live/board_live.ex:95"
        }
      ]
    },
    "testing": {
      "test_files": ["test/kanban_web/live/board_live_test.exs"],
      "key_scenarios": ["No tasks match filter", "All tasks same priority"]
    },
    "constraints": [
      {
        "type": "must_not",
        "constraint": "Don't modify task card layout"
      }
    ]
  }
}
```

## API Endpoints (Planned)

### Authentication

- `POST /settings/api-tokens` - Generate API token with scopes

### Task Management

- `GET /api/tasks/ready` - Tasks ready to work (unblocked, status=open)
- `GET /api/tasks/:id` - Full task details with context
- `POST /api/tasks` - Create task(s) with dependencies
- `PATCH /api/tasks/:id` - Update status/progress
- `POST /api/tasks/:id/subtasks` - Break down into smaller tasks
- `GET /api/tasks/:id/context` - Related tasks/dependencies

### Authentication Model

Bearer token with scoped permissions:

```text
Authorization: Bearer kan_live_abc123def456...

Scopes:
- tasks:read      # Read tasks
- tasks:write     # Create/update tasks
- tasks:delete    # Delete tasks
- boards:read     # Read board structure
```

## Technology Stack

- **Phoenix Framework** - Robust Elixir web framework
- **Phoenix LiveView** - Real-time server-rendered UI
- **PostgreSQL** - Relational database with JSONB support
- **Tailwind CSS v4** - Modern utility-first styling
- **Ecto** - Database wrapper and query generator

## Design Principles

### 1. AI-Native, Not AI-Bolted-On

Every feature considers "how will an AI agent use this?" first.

### 2. Structured Context Over Free-Form

JSON schemas for technical context make tasks machine-readable and actionable.

### 3. Visual Equality

AI-created and human-created tasks look identical—because they are equal in value.

### 4. Dependency-Aware

Tasks know what blocks them and what they block. This enables intelligent work querying.

### 5. Progressive Enhancement

Start simple (flat tasks with dependencies), evolve to complex (hierarchical epics with rich context).

## Getting Started

### Prerequisites

- Elixir 1.19+
- PostgreSQL
- Node.js (for asset compilation)

### Setup

```bash
# Install dependencies
mix deps.get
npm install --prefix assets

# Setup database
mix ecto.create
mix ecto.migrate

# Start the server
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000)

### Development Workflow

```bash
# Run tests
mix test

# Run precommit checks (tests, credo, sobelow, coverage)
mix precommit

# Format code
mix format
```

## Documentation

- [AI Workflow Guide](docs/AI-WORKFLOW.md) - How AI agents integrate with Stride
- [API Format](docs/API-FORMAT.md) - JSON API design decisions
- [AI Authentication](docs/AI-AUTHENTICATION.md) - Bearer token approach
- [Task Breakdown](docs/TASK-BREAKDOWN.md) - Flat vs hierarchical tasks
- [Rich Content Schema](docs/RICH-CONTENT.md) - Technical context JSON schema
- [UI Integration](docs/UI-INTEGRATION.md) - Displaying AI vs human tasks
- [Task Requirements](docs/TASKS.md) - What makes a good task for AI implementation

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

## What's Next?

Stride is evolving from a Kanban board into a full AI workflow platform. Planned features:

- API token generation and management UI
- RESTful API for task CRUD operations
- Dependency visualization and resolution
- Advanced filtering (by assignee, creator type, technical context)
- Task templates for common patterns
- Webhook integration for CI/CD workflows
- Real-time collaboration features
- Analytics dashboard (AI vs human task completion, velocity, bottlenecks)

## Contributing

Stride welcomes contributions! Whether you're human or AI, if you're improving the codebase, you're contributing.

## License

[Add your license here]

---

**Built with Phoenix. Designed for AI. Made for humans.**
