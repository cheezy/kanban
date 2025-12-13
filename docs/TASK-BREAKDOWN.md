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
