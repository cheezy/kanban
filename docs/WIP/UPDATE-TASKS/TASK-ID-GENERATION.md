# Task Identifier Generation System

**Date:** 2025-12-20
**Status:** Documented (Implementation needed for Goal IDs)
**Related:** Task 01, Task 02, goal-ai-optimized-task-system.md

## Overview

The Kanban application generates human-readable, prefixed identifiers for all task types to make them easy to reference in conversation, documentation, and code reviews. Each entity type has a unique prefix letter followed by a sequential number.

**Important:** The system uses two types of tasks: **Work** (new functionality) and **Defect** (bug fixes). Goals are large initiatives that contain multiple tasks.

## ID Prefixes by Entity Type

| Entity Type | Prefix | Example | Description |
|-------------|--------|---------|-------------|
| **Goal** | G | G1, G2, G3 | Large initiatives (25+ hours, multiple tasks) |
| **Work** | W | W1, W2, W3 | Individual work items (1-3 hours) |
| **Defect** | D | D1, D2, D3 | Bug fixes and defect corrections |

## Current Implementation Status

### ✅ Implemented (Tasks and Defects)

**Location:** [lib/kanban/tasks.ex:615-637](lib/kanban/tasks.ex#L615-L637)

**How it works:**
1. Task type is determined (`:work` or `:defect`)
2. Prefix is selected based on type: `W` for work, `D` for defect
3. System finds maximum existing identifier number for that type
4. New identifier is generated: `prefix + (max_number + 1)`

**Example:**
- Existing tasks: W1, W2, W3
- Next task identifier: W4
- Existing defects: D1, D2
- Next defect identifier: D3

**Database Schema:**
```elixir
# tasks table
field :identifier, :string  # e.g., "W42" or "D7"
field :type, Ecto.Enum, values: [:work, :defect], default: :work

# Unique constraint ensures no duplicates
create unique_index(:tasks, [:identifier])
```

**Implementation Code:**
```elixir
defp generate_task_identifier(task_type) do
  # Normalize task type
  task_type =
    case task_type do
      "work" -> :work
      "defect" -> :defect
      atom when is_atom(atom) -> atom
    end

  # Get the prefix for this task type
  prefix = if task_type == :work, do: "W", else: "D"

  # Find the maximum identifier number for this type across ALL tasks
  # Since identifier has a global unique constraint, we need global uniqueness
  max_number =
    Task
    |> where([t], t.type == ^task_type)
    |> select([t], t.identifier)
    |> Repo.all()
    |> Enum.map(fn identifier ->
      # Extract numeric part (e.g., "W11" -> 11)
      identifier
      |> String.replace(prefix, "")
      |> String.to_integer()
    end)
    |> case do
      [] -> 0
      numbers -> Enum.max(numbers)
    end

  # Generate identifier: W1, W2, D1, D2, etc.
  "#{prefix}#{max_number + 1}"
end
```

**Migration (Historical):**

Migration file: [priv/repo/migrations/20251111234119_add_identifier_to_tasks.exs](priv/repo/migrations/20251111234119_add_identifier_to_tasks.exs)

```elixir
def up do
  alter table(:tasks) do
    add :identifier, :string
  end

  # Populate identifiers for existing tasks
  flush()
  populate_identifiers()

  create unique_index(:tasks, [:identifier])
end

defp populate_identifiers do
  # Get all boards
  boards =
    from(b in "boards", select: %{id: b.id})
    |> repo().all()

  # For each board, populate identifiers for tasks by type
  Enum.each(boards, fn board ->
    populate_board_identifiers(board.id)
  end)
end

defp populate_board_identifiers(board_id) do
  # Get all tasks for this board, ordered by creation date
  tasks =
    from(t in "tasks",
      join: c in "columns",
      on: t.column_id == c.id,
      where: c.board_id == ^board_id,
      select: %{id: t.id, type: t.type, inserted_at: t.inserted_at},
      order_by: [asc: t.inserted_at]
    )
    |> repo().all()

  # Group by type and assign sequential identifiers
  tasks
  |> Enum.group_by(& &1.type)
  |> Enum.each(fn {type, type_tasks} ->
    prefix = if type == "work", do: "W", else: "D"

    type_tasks
    |> Enum.with_index(1)
    |> Enum.each(fn {task, index} ->
      identifier = "#{prefix}#{index}"

      from(t in "tasks", where: t.id == ^task.id)
      |> repo().update_all(set: [identifier: identifier])
    end)
  end)
end
```

### ⏳ Pending Implementation (Goals)

**Requirement:** Extend the same identifier generation pattern to support Goal (G prefix) task type.

**Changes Needed:**

1. **Update Task Schema** ([lib/kanban/tasks/task.ex](lib/kanban/tasks/task.ex))

Add task_type field to distinguish goals from tasks:
```elixir
field :task_type, :string  # "goal", "work", "defect"
```

2. **Update ID Generation Logic** ([lib/kanban/tasks.ex](lib/kanban/tasks.ex))

Extend prefix selection to include goal type:
```elixir
defp generate_task_identifier(task_type) do
  # Get the prefix for this task type
  prefix =
    case task_type do
      "goal" -> "G"
      :work -> "W"
      :defect -> "D"
      _ -> "W"
    end

  # Find the maximum identifier number for this type across ALL tasks
  max_number =
    Task
    |> where([t], t.task_type == ^to_string(task_type))
    |> select([t], t.identifier)
    |> Repo.all()
    |> Enum.map(fn identifier ->
      # Extract numeric part (e.g., "G1" -> 1, "W5" -> 5)
      identifier
      |> String.replace(prefix, "")
      |> String.to_integer()
    end)
    |> case do
      [] -> 0
      numbers -> Enum.max(numbers)
    end

  # Generate identifier: G1, W1, D1, etc.
  "#{prefix}#{max_number + 1}"
end
```

3. **Create Migration**

```elixir
defmodule Kanban.Repo.Migrations.AddTaskTypeField do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :task_type, :string  # "goal", "work", "defect"
    end

    create index(:tasks, [:task_type])
  end
end
```

## Hierarchical Structure

Goals and Tasks form a two-level hierarchy using the `parent_id` field:

```
Goal (G1)
├── Work Task (W1)
├── Work Task (W2)
├── Defect (D1)
└── Defect (D2)

Standalone Tasks (no parent):
├── Task (W7)
└── Defect (D1)
```

**Database Schema for Hierarchy:**
```elixir
# tasks table
field :parent_id, :integer  # References another task (epic or feature)
field :task_type, :string   # "epic", "feature", "task" (NOT same as :type field)

# Self-referential foreign key
add :parent_id, references(:tasks, on_delete: :delete_all)
create index(:tasks, [:parent_id])
```

**Note:** There are two type-related fields:
- `type` (Ecto.Enum): `:epic`, `:feature`, `:work`, `:defect` - determines ID prefix
- `task_type` (string): `"epic"`, `"feature"`, `"task"` - determines hierarchy level

These may be consolidated in the future, but currently serve different purposes in the codebase.

## Usage Examples

### Creating Tasks with Auto-Generated IDs

**Epic:**
```elixir
{:ok, epic} = Tasks.create_task(%{
  title: "Implement AI-Optimized Task System",
  type: :epic,
  task_type: "epic",
  status: "open"
})

epic.identifier  # => "E1"
```

**Feature:**
```elixir
{:ok, feature} = Tasks.create_task(%{
  title: "Database Schema Foundation",
  type: :feature,
  task_type: "feature",
  parent_id: epic.id,
  status: "open"
})

feature.identifier  # => "F1"
```

**Work Task:**
```elixir
{:ok, task} = Tasks.create_task(%{
  title: "Extend task schema",
  type: :work,
  task_type: "task",
  parent_id: feature.id,
  status: "open",
  complexity: "large"
})

task.identifier  # => "W1"
```

**Defect:**
```elixir
{:ok, defect} = Tasks.create_task(%{
  title: "Fix task claiming race condition",
  type: :defect,
  task_type: "task",
  status: "open",
  complexity: "medium"
})

defect.identifier  # => "D1"
```

### Querying by Identifier

```elixir
# Get task by identifier
task = Repo.get_by(Task, identifier: "W42")

# Get all tasks of a specific type
epics = from(t in Task, where: t.type == :epic) |> Repo.all()
features = from(t in Task, where: t.type == :feature) |> Repo.all()
work_items = from(t in Task, where: t.type == :work) |> Repo.all()
defects = from(t in Task, where: t.type == :defect) |> Repo.all()

# Search for tasks by identifier pattern
tasks_starting_with_w =
  from(t in Task, where: like(t.identifier, "W%"))
  |> Repo.all()
```

### API Usage

**GET /api/tasks?type=epic**
```json
{
  "data": [
    {
      "id": 1,
      "identifier": "E1",
      "title": "Implement AI-Optimized Task System",
      "type": "epic",
      "task_type": "epic",
      "status": "open"
    }
  ]
}
```

**GET /api/tasks/E1/tree** (Hierarchical view)
```json
{
  "type": "epic",
  "task": {
    "id": 1,
    "identifier": "E1",
    "title": "Implement AI-Optimized Task System",
    "type": "epic"
  },
  "features": [
    {
      "type": "feature",
      "task": {
        "id": 2,
        "identifier": "F1",
        "title": "Database Schema Foundation",
        "type": "feature",
        "parent_id": 1
      },
      "tasks": [
        {
          "id": 3,
          "identifier": "W1",
          "title": "Extend task schema",
          "type": "work",
          "parent_id": 2
        },
        {
          "id": 4,
          "identifier": "W2",
          "title": "Add metadata fields",
          "type": "work",
          "parent_id": 2
        }
      ]
    }
  ],
  "statistics": {
    "total_tasks": 2,
    "completed_tasks": 0,
    "blocked_tasks": 0
  }
}
```

## Benefits of Prefixed IDs

### For Humans

1. **Easy Reference**: "Check out E1" is clearer than "Check out task ID 1287"
2. **Type Recognition**: Instantly know what kind of entity you're looking at
3. **Conversation**: Natural to discuss in meetings ("Let's focus on F2 tasks this sprint")
4. **Code Reviews**: Easy to reference in commit messages and PR descriptions

### For AI Agents

1. **Semantic Clarity**: Prefix indicates entity type without additional queries
2. **Dependency References**: Can reference "W42 depends on F3" in natural language
3. **Documentation**: Clear references in documentation and comments
4. **Logging**: Easy to grep logs for specific task types

### For System

1. **Uniqueness**: Global unique constraint prevents duplicates
2. **Sequential**: Predictable numbering helps identify creation order
3. **Compact**: Short identifiers save space in UI and databases
4. **Human-Readable**: No need for UUID complexity where not needed

## Implementation Checklist

- [x] Implement W prefix for work tasks
- [x] Implement D prefix for defects
- [x] Add unique constraint on identifier field
- [x] Create migration to backfill existing tasks
- [x] Add identifier generation to task creation
- [ ] **Implement E prefix for epics** (pending)
- [ ] **Implement F prefix for features** (pending)
- [ ] Update task schema to support epic and feature types
- [ ] Update ID generation logic to handle all four prefixes
- [ ] Add tests for epic and feature identifier generation
- [ ] Update API documentation with all four prefixes
- [ ] Update UI to display identifiers for all types

## Testing Strategy

### Unit Tests

```elixir
defmodule Kanban.TasksTest do
  use Kanban.DataCase

  describe "generate_task_identifier/1" do
    test "generates E1 for first epic" do
      assert Tasks.generate_task_identifier(:epic) == "E1"
    end

    test "generates F1 for first feature" do
      assert Tasks.generate_task_identifier(:feature) == "F1"
    end

    test "generates W1 for first work task" do
      assert Tasks.generate_task_identifier(:work) == "W1"
    end

    test "generates D1 for first defect" do
      assert Tasks.generate_task_identifier(:defect) == "D1"
    end

    test "increments epic identifiers sequentially" do
      create_task(%{type: :epic})  # E1
      create_task(%{type: :epic})  # E2
      assert Tasks.generate_task_identifier(:epic) == "E3"
    end

    test "identifiers are independent across types" do
      create_task(%{type: :epic})     # E1
      create_task(%{type: :feature})  # F1
      create_task(%{type: :work})     # W1
      create_task(%{type: :defect})   # D1

      assert Tasks.generate_task_identifier(:epic) == "E2"
      assert Tasks.generate_task_identifier(:feature) == "F2"
      assert Tasks.generate_task_identifier(:work) == "W2"
      assert Tasks.generate_task_identifier(:defect) == "D2"
    end
  end
end
```

### Integration Tests

```elixir
test "creates epic with E prefix identifier" do
  {:ok, epic} = Tasks.create_task(%{
    title: "Test Epic",
    type: :epic,
    task_type: "epic"
  })

  assert epic.identifier =~ ~r/^E\d+$/
end

test "creates feature with F prefix identifier" do
  {:ok, feature} = Tasks.create_task(%{
    title: "Test Feature",
    type: :feature,
    task_type: "feature"
  })

  assert feature.identifier =~ ~r/^F\d+$/
end

test "identifiers are globally unique" do
  {:ok, task1} = Tasks.create_task(%{title: "Task 1", type: :work})
  {:ok, task2} = Tasks.create_task(%{title: "Task 2", type: :work})

  refute task1.identifier == task2.identifier
end

test "epic-feature-task hierarchy has correct identifiers" do
  {:ok, epic} = Tasks.create_task(%{
    title: "Epic",
    type: :epic,
    task_type: "epic"
  })

  {:ok, feature} = Tasks.create_task(%{
    title: "Feature",
    type: :feature,
    task_type: "feature",
    parent_id: epic.id
  })

  {:ok, task} = Tasks.create_task(%{
    title: "Task",
    type: :work,
    task_type: "task",
    parent_id: feature.id
  })

  assert epic.identifier =~ ~r/^E\d+$/
  assert feature.identifier =~ ~r/^F\d+$/
  assert task.identifier =~ ~r/^W\d+$/
end
```

## Future Enhancements (Out of Scope)

1. **Custom Prefixes**: Allow board owners to customize prefixes (e.g., "BUG" instead of "D")
2. **Per-Board Sequences**: Separate ID sequences per board instead of global
3. **Vanity IDs**: Allow manual override of auto-generated IDs
4. **ID Format Validation**: Enforce prefix format in changesets
5. **ID History**: Track if IDs are reused after deletion
6. **Bulk ID Generation**: Pre-generate ID ranges for batch operations
7. **ID Reservation**: Reserve ID ranges for import operations

## References

- **Implementation:** [lib/kanban/tasks.ex:615-637](lib/kanban/tasks.ex#L615-L637)
- **Schema:** [lib/kanban/tasks/task.ex](lib/kanban/tasks/task.ex)
- **Migration:** [priv/repo/migrations/20251111234119_add_identifier_to_tasks.exs](priv/repo/migrations/20251111234119_add_identifier_to_tasks.exs)
- **Epic Structure:** [docs/WIP/UPDATE-TASKS/EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
- **Hierarchical Tree:** [docs/WIP/UPDATE-TASKS/12-add-hierarchical-task-tree-endpoint.md](12-add-hierarchical-task-tree-endpoint.md)
- **Task Breakdown:** [docs/WIP/TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md)

## Summary

The prefixed ID system provides human-readable, type-aware identifiers for all task types:

- **E** for Epics (large initiatives)
- **F** for Features (feature sets)
- **W** for Work tasks (individual items)
- **D** for Defects (bug fixes)

The system currently supports W and D prefixes. Implementation of E and F prefixes requires updating the task type enum, extending the ID generation logic, and creating appropriate migrations. This simple prefix system makes tasks easier to reference in conversation, documentation, and code while maintaining global uniqueness through database constraints.
