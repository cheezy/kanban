# Task Breakdown

Should I be able to create subtasks automatically, or just flat tasks?

## Decision: 2-Level Hierarchy (Goal → Tasks)

### Current Structure

The system uses a **2-level hierarchy** with **two task types**:

**Levels:**
1. **Goal** (G prefix) - Large initiatives (25+ hours, multiple tasks)
   - Type field: `:goal` in database
   - Identifier: G1, G2, G3, etc.
   - Has `parent_id` of `nil` (top-level)
   - Can have child tasks via their `parent_id` field
2. **Task** - Individual work items (1-3 hours each)
   - Has `parent_id` pointing to a goal (or `nil` for standalone tasks)
   - Identifier: W1-W999 or D1-D999

**Task Types (for non-goal tasks):**
1. **Work** (W prefix, `:work` enum) - New functionality, enhancements
2. **Defect** (D prefix, `:defect` enum) - Bug fixes, corrections
3. **Goal** (G prefix, `:goal` type) - Container for related tasks

```json
{
  "title": "Implement AI-Optimized Task System",
  "task_type": "goal",
  "identifier": "G1",
  "tasks": [
    {"title": "Add API auth", "type": "work", "identifier": "W1", "blocks": []},
    {"title": "Create /ready endpoint", "type": "work", "identifier": "W2", "blocks": ["W1"]},
    {"title": "Fix race condition", "type": "defect", "identifier": "D1", "blocks": ["W2"]}
  ]
}
```

### Why This Structure

- **Simpler data model** - Only 2 levels instead of 3 (Epic/Feature/Task)
- **Dependencies handle ordering** - No need for complex nesting
- **Easier to visualize** - Clearer in Kanban board
- **Task types provide clarity** - Work vs Defect is more meaningful than Feature vs Task
- **Less maintenance** - Fewer levels = less overhead

### Flat Tasks with Dependencies (Default)

For most work, use flat tasks with dependencies:

```json
{
  "tasks": [
    {"id": 1, "title": "Add API auth", "type": "work", "blocks": []},
    {"id": 2, "title": "Create /ready endpoint", "type": "work", "blocks": [1]},
    {"id": 3, "title": "Fix validation bug", "type": "defect", "blocks": [1]}
  ]
}
```

## Why 2 Levels Work Better for AI

### 1. Natural Planning Structure

When breaking down work, think in terms of goals and tasks:

- Goal: "Implement AI-Optimized Task System"
  - Work Task: "Add API authentication"
  - Work Task: "Create task endpoints"
  - Defect: "Fix race condition in claiming"

### 2. Progress Tracking

- Goal shows "7/13 tasks complete"
- Clear visibility into what's done
- Task types visible (5 work, 2 defects)

### 3. Scope Management

- Easy to see what's part of a larger goal
- Tasks can be completed independently
- Can defer some tasks without losing context

### 4. Better for Resuming Work

If I get interrupted:

- Flat tasks: I have to remember which tasks belong together
- Goal hierarchy: The parent goal shows the full context and related tasks

## Implementation Approach

The schema supports the 2-level hierarchy:

```elixir
# Schema
field :parent_id, references(:tasks)  # null = top-level (goal), non-null = child task
field :task_type, :string  # "goal", "work", "defect"
field :type, Ecto.Enum, values: [:work, :defect]  # For tasks only
field :identifier, :string  # G1, W42, D7
```

```json
# API accepts goal with tasks
POST /api/tasks
{
  "title": "Implement user authentication",
  "task_type": "goal",
  "tasks": [
    {"title": "Add JWT library", "type": "work"},
    {"title": "Create auth controller", "type": "work"},
    {"title": "Fix password validation", "type": "defect"}
  ]
}

# OR attach to existing goal
POST /api/tasks
{
  "title": "Add auth",
  "type": "work",
  "parent_id": "G1"  # Attach to existing goal
}
```

### When to Use What

**Create a Goal** when:

- Planning large initiatives (25+ hours)
- Breaking down complex features into multiple work items
- Grouping related tasks for a release or milestone

**Create Flat Tasks** when:

- Quick fixes/bugs (use type: "defect")
- Independent features (use type: "work")
- Simple requests from user
- Tasks that don't belong to a larger initiative

## UI Considerations

### Kanban Board View

**Goal Cards:**
- **Compact height** - `min-h-[45px]` with `p-1.5` padding (vs regular tasks with `p-3`)
- **Reduced spacing** - `mt-1` between title and progress bar, `mt-1.5` between progress bar and badges
- **Yellow gradient background** - `from-yellow-50 to-yellow-100` with `border-yellow-300/60`
- **Three-line layout:**
  - Line 1: Title (text-sm, leading-snug)
  - Line 2: Progress bar with completion count (e.g., "6/11")
  - Line 3: Badge row (type badge, priority, identifier)
- **Non-draggable** - No drag handle displayed, moves automatically based on child tasks
- **Automatic movement:**
  - Moves to target column when ALL child tasks are in the same column
  - Positions itself BEFORE the first child task in the target column
  - Special handling for "Done" column - positions at end if all children complete
  - Updates triggered by `update_parent_goal_position/3` in Tasks context
- **Real-time progress updates** via PubSub broadcasts
- **Type badge** - Yellow "G" badge with gradient background
- **Visual identification** - Determined by `String.starts_with?(task.identifier, "G")`

**Task Cards:**
- Standard height with `p-3` padding and `min-h-[60px]` (before we reduced goals)
- Display task type icons (W for work, D for defect) with color-coded badges
- **Draggable** between columns with visible drag handle (hero-bars-3 icon)
- Color coding:
  - Work tasks (W): Blue gradient badges
  - Defect tasks (D): Red gradient badges
- Shows standard task metadata (description, assigned user, etc.)
- **Can be assigned to goals** via `parent_id` field
- Moving a task triggers parent goal repositioning if applicable

### List View

- Indent tasks under parent goals
- Filter options:
  - "Show only goals"
  - "Show only tasks"
  - "Show only defects"

## API Features for Goal/Task Hierarchy

The API provides:

1. **Auto-flattening API**: Send nested JSON, system creates the hierarchy
2. **Smart completion**: When all tasks done, mark goal complete
3. **Dependency inheritance**: If goal blocks X, all tasks implicitly block X
4. **Query flexibility**:
   - `GET /api/tasks/ready` - includes tasks whose parent goal is unblocked
   - `GET /api/tasks/ready?type=work` - only work tasks
   - `GET /api/tasks/ready?type=defect` - only defects
   - `GET /api/tasks/:id/tree` - hierarchical view (goal → tasks)

## Identifier System

All items have human-readable prefixed identifiers:

- **G1, G2, G3** - Goals
- **W1, W2, W3** - Work tasks
- **D1, D2, D3** - Defects

See [TASK-ID-GENERATION.md](UPDATE-TASKS/TASK-ID-GENERATION.md) for full details.

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
