# Task Breakdown

 Should I be able to create subtasks automatically, or just flat tasks?

## Both - But Start Simple

### Start: Flat Tasks (MVP)

```json
Just let me create independent tasks with dependencies:
{
  "tasks": [
    {"id": 1, "title": "Add API auth", "blocks": []},
    {"id": 2, "title": "Create /ready endpoint", "blocks": [1]},
    {"id": 3, "title": "Add task creation endpoint", "blocks": [1]}
  ]
}
```

### Why start here

- Simpler data model
- Dependencies handle ordering
- Easier to visualize in Kanban

### Later: Hierarchical Subtasks (Better UX)

But eventually hierarchical is more powerful because:

```json
{
  "title": "Add AI workflow API",
  "type": "epic",
  "subtasks": [
    {
      "title": "Add API authentication",
      "subtasks": [
        {"title": "Create API token schema"},
        {"title": "Add token validation plug"},
        {"title": "Add UI for token generation"}
      ]
    },
    {
      "title": "Create task endpoints",
      "blocks": ["Add API authentication"],
      "subtasks": [
        {"title": "GET /api/tasks/ready"},
        {"title": "POST /api/tasks"},
        {"title": "PATCH /api/tasks/:id"}
      ]
    }
  ]
}
```

## Why Subtasks Are Better for AI Planning

### 1. Natural Planning Structure

When I break down work, I think hierarchically:

- Epic: "Add AI workflow API"
  - Feature: "Authentication"
    - Task: "Token schema"
    - Task: "Validation plug"

### 2. Progress Tracking

- Parent shows "2/5 subtasks complete"
- Clear visibility into what's done

### 3. Scope Management

- Easy to see what's part of a larger effort
- Can complete subtasks independently
- Can defer some subtasks without losing context

### 4. Better for Resuming Work

If I get interrupted:

- Flat tasks: I have to remember which tasks belong together
- Subtasks: The parent task shows the full context

## Hybrid Approach (My Recommendation)

Allow both patterns:

```elixir
# Schema supports both
field :parent_id, references(:tasks)  # null = top-level task
field :task_type, :string  # epic, feature, task, bug
```

```json
# API accepts both
POST /api/tasks
{
  "title": "Add auth",
  "subtasks": [...]  # Creates children automatically
}

# OR
POST /api/tasks
{
  "title": "Add auth",
  "parent_id": "kanban-5"  # Attach to existing parent
}
```

### What I'd Use When

Flat tasks when:

- Quick fixes/bugs
- Independent features
- Simple requests from user

Subtasks when:

- Planning mode (breaking down complex work)
- Epics with multiple parts
- Related work that shares context

## UI Considerations

### Kanban Board View

- Show parent tasks as cards
- Badge showing "3/5" subtasks complete
- Click to expand/collapse subtasks

### List View

- Indent subtasks under parents
- Or filter: "Show only top-level tasks"

## What Would Help Me Most

If you implement subtasks, give me:

1. Auto-flattening API: I can send nested JSON, you create the hierarchy
2. Smart completion: When all subtasks done, mark parent done
3. Dependency inheritance: If parent blocks X, all subtasks implicitly block X
4. Query flexibility:
    `GET /api/tasks/ready` includes subtasks whose parent is complete
    `GET /api/tasks/ready?top_level=true` only shows parent tasks

*My vote: Start with flat + dependencies, add subtasks in v2* when you see how planning actually works in practice. What's your intuition - do you think you'd want to see the hierarchy in the UI?

## Task Format and Structure

For the detailed task structure that AI can both create and execute efficiently, see **TASKS.md**. That document defines:

- **18 categories** of essential information for task implementation
- **Copy-paste template** for creating new tasks
- **Completion summary format** - how AI updates tasks after finishing work
- **Full lifecycle** from task creation → execution → completion

### How Task Breakdown Fits with TASKS.md

When creating tasks via API (flat or hierarchical), use the TASKS.md template structure:

```json
{
  "title": "Add priority filter to board list view",
  "complexity": "medium",
  "estimated_files": "2-3",
  "description": {
    "why": "Users need to focus on high-priority tasks without manually scanning",
    "what": "Add a dropdown filter for task priority (0-4) in board header",
    "where": "Board list view header, next to existing status filter"
  },
  "acceptance_criteria": [
    "Dropdown shows priorities 0-4 with labels (Critical, High, Medium, Low, None)",
    "Filtering updates task list in real-time via LiveView",
    "Filter state persists in URL params (?priority=3)"
  ],
  "key_files": [
    {"path": "lib/kanban_web/live/board_live.ex", "note": "Main LiveView handling board display"},
    {"path": "lib/kanban/boards.ex", "note": "Context with get_tasks/2 function to update"}
  ],
  "verification": {
    "commands": ["mix test test/kanban/boards_test.exs", "mix precommit"],
    "manual_steps": [
      "Navigate to /boards",
      "Click priority filter dropdown",
      "Select 'High (3)' priority"
    ]
  },
  "observability": {
    "telemetry_events": ["[:kanban, :filter, :used]"],
    "metrics": ["counter of filter usage"]
  }
}
```

This rich task structure enables AI to:
1. **Execute without exploration** - key files are listed upfront
2. **Verify correctly** - exact commands and manual steps provided
3. **Complete properly** - knows what telemetry/metrics to add
4. **Update post-completion** - structured format for completion summary

See **TASKS.md** for the full template and examples.
