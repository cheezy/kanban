# Add GET /api/tasks/:id/tree Endpoint for Hierarchical Task Data

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** AI agents need to see the complete structure of work - which tasks belong to which goal. This provides context for planning and understanding dependencies across the entire project.

**WHAT:** Create GET /api/tasks/:id/tree endpoint that returns a nested JSON structure showing the complete hierarchy. If ID is a goal, return all its children. If ID is a task, return just that task. Include metadata about parent/child relationships and goal progress.

**WHERE:** API controller, Tasks context

**CURRENT STATUS:** ✅ **IMPLEMENTED** - Endpoint exists and returns hierarchical data. This document now serves as reference documentation.

## Acceptance Criteria

- [x] GET /api/tasks/:id/tree returns hierarchical JSON structure
- [x] For goal: Returns goal → children tasks (2 levels)
- [x] For task: Returns task only (1 level)
- [x] Each item includes all rich fields (complexity, dependencies, etc.)
- [x] Response includes counts (total children, completed)
- [x] Respects tasks:read scope
- [x] Returns 401 if no/invalid token
- [x] Returns 404 if task ID not found
- [x] Filters by type (goal, work, defect) automatically

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add get_task_tree/1 function
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add tree action
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Check parent_id and task_type fields
- [docs/WIP/TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md) - Goal/Task structure
- [docs/WIP/UPDATE-TASKS/TASK-ID-GENERATION.md](TASK-ID-GENERATION.md) - Prefixed ID system (G, W, D)

## Technical Notes

**Implementation Details:**
- Endpoint: `GET /api/tasks/:id/tree` in `KanbanWeb.API.TaskController`
- Context function: `Kanban.Tasks.get_task_tree/1`
- JSON view: `KanbanWeb.API.TaskJSON.tree/1`
- Returns different structure based on task type (`:goal` vs `:work`/`:defect`)

**Patterns Followed:**
- Uses single query to fetch children for goals (not recursive - only 2 levels)
- Preloads all associations via `Repo.preload`
- Includes parent_id and type in response
- Calculates statistics using `calculate_goal_progress/1` helper
- Orders children by position ascending
- For goals: Returns goal data + array of children + counts
- For tasks: Returns just the task data (no children)

**Database/Schema:**
- Tables: tasks (with parent_id self-reference)
- Fields: `parent_id` (integer, nullable), `type` (enum: :work, :defect, :goal)
- Migrations needed: ✅ Already exist
- Query logic:
  - Start with root task (by ID)
  - If type = `:goal`, find all children with `parent_id = goal.id`
  - If type = `:work` or `:defect`, return just that task

**UI Behavior (Board View):**
- **Goal Cards:**
  - Compact yellow cards with progress bars
  - Show completion percentage and count (e.g., "6/11")
  - **Non-draggable** - no drag handle shown
  - **Automatic movement** triggered when child tasks move:
    - When ALL children are in same column, goal moves to that column
    - Goal positions BEFORE first child in target column
    - "Done" column: Goal goes to end when all children complete
    - Movement handled by `update_parent_goal_position/3` in Tasks context
- **Task Cards:**
  - Regular cards with drag handles
  - Can be assigned to goals via `parent_id` selector
  - Moving a task triggers parent goal repositioning check

**Integration Points:**
- [ ] PubSub broadcasts: None (read-only)
- [ ] Phoenix Channels: None
- [ ] External APIs: None

## Verification

**Commands to Run:**

```bash
# Run tests
mix test test/kanban_web/controllers/api/task_controller_test.exs
mix test test/kanban/tasks_test.exs

# Test in console
iex -S mix
alias Kanban.{Repo, Tasks}

# Create goal → task structure
{:ok, goal} = Tasks.create_task(%{
  title: "Implement AI-Optimized Task System",
  task_type: "goal",
  status: "open"
})

{:ok, task1} = Tasks.create_task(%{
  title: "Extend task schema",
  type: :work,
  parent_id: goal.id,
  status: "open",
  complexity: :large
})

{:ok, task2} = Tasks.create_task(%{
  title: "Add metadata fields",
  type: :work,
  parent_id: goal.id,
  status: "completed",
  complexity: :medium
})

{:ok, task3} = Tasks.create_task(%{
  title: "Fix validation bug",
  type: :defect,
  parent_id: goal.id,
  status: "open",
  complexity: :small
})

# Get tree starting from goal
tree = Tasks.get_task_tree(goal.id)
IO.inspect(tree, limit: :infinity)

# Test API
export TOKEN="kan_dev_your_token_here"

# Get goal tree (includes all tasks)
curl http://localhost:4000/api/tasks/1/tree \
  -H "Authorization: Bearer $TOKEN"

# Get single task
curl http://localhost:4000/api/tasks/2/tree \
  -H "Authorization: Bearer $TOKEN"

# Run all checks
mix precommit
```

**Manual Testing:**

1. Create goal with 3 tasks (2 work, 1 defect)
2. Call GET /api/tasks/:goal_id/tree
3. Verify returns goal → tasks structure
4. Verify includes all rich fields for each item
5. Verify statistics are accurate (3 total tasks, 1 completed, etc.)
8. Call GET /api/tasks/:task_id/tree
9. Verify returns just that task (no children)
10. Test with invalid ID (should 404)
11. Test with invalid token (should 401)

**Success Looks Like:**

- Returns complete nested structure
- All rich fields included for each item
- Statistics are accurate
- Performance is acceptable (< 500ms for 50+ tasks)
- JSON structure is intuitive and easy to parse
- AI agents can use this to understand full project structure

## Data Examples

**Tasks Context Function:**

```elixir
defmodule Kanban.Tasks do
  import Ecto.Query
  alias Kanban.Repo
  alias Kanban.Schemas.Task

  @doc """
  Gets the hierarchical tree starting from a task.

  Returns nested structure with all children recursively loaded.
  Includes statistics about task counts and status.
  """
  def get_task_tree(task_id) do
    root = Repo.get!(Task, task_id) |> Repo.preload([:column])

    case root.task_type do
      "goal" -> build_goal_tree(root)
      "work" -> build_task_node(root)
      "defect" -> build_task_node(root)
      _ -> build_task_node(root)
    end
  end

  defp build_goal_tree(goal) do
    tasks =
      from(t in Task,
        where: t.parent_id == ^goal.id,
        where: t.type in [:work, :defect],
        order_by: [asc: coalesce(t.position, t.inserted_at)]
      )
      |> Repo.all()
      |> Repo.preload([:column])
      |> Enum.map(&build_task_node/1)

    %{
      type: "goal",
      task: task_to_map(goal),
      tasks: tasks,
      statistics: calculate_goal_statistics(goal.id)
    }
  end

  defp build_task_node(task) do
    %{
      type: task.type,
      task: task_to_map(task),
      children: nil
    }
  end

  defp task_to_map(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      task_type: task.task_type,
      status: task.status,
      priority: task.priority,
      complexity: task.complexity,
      estimated_files: task.estimated_files,
      dependencies: task.dependencies,
      parent_id: task.parent_id,
      why: task.why,
      what: task.what,
      where_context: task.where_context,
      key_files: parse_key_files(task.key_files),
      verification_steps: parse_verification_steps(task.verification_steps),
      created_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp calculate_goal_statistics(goal_id) do
    # Get all tasks under this goal
    task_counts =
      from(t in Task,
        where: t.parent_id == ^goal_id,
        where: t.type in [:work, :defect],
        group_by: t.status,
        select: {t.status, count(t.id)}
      )
      |> Repo.all()
      |> Enum.into(%{})

    %{
      total_tasks: Enum.sum(Map.values(task_counts)),
      completed: Map.get(task_counts, "completed", 0),
      in_progress: Map.get(task_counts, "in_progress", 0),
      open: Map.get(task_counts, "open", 0),
      blocked: Map.get(task_counts, "blocked", 0)
    }
  end
end

  defp parse_key_files(nil), do: []
  defp parse_key_files(text), do: Kanban.Tasks.TextFieldParser.parse_key_files(text)

  defp parse_verification_steps(nil), do: []
  defp parse_verification_steps(text), do: Kanban.Tasks.TextFieldParser.parse_verification_steps(text)
end
```

**Controller Action:**

```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  @doc """
  GET /api/tasks/:id/tree
  Returns hierarchical structure of tasks.
  """
  def tree(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:read") do
      case Tasks.get_task_tree(id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Task not found"})

        tree ->
          :telemetry.execute(
            [:kanban, :api, :task_tree_fetched],
            %{task_id: id},
            %{api_token_id: conn.assigns.api_token.id}
          )

          json(conn, %{data: tree})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions. Requires tasks:read scope"})
    end
  end

  defp has_scope?(conn, required_scope) do
    api_token = conn.assigns[:api_token]
    required_scope in api_token.scopes
  end
end
```

**Router Update:**

```elixir
scope "/api", KanbanWeb.API do
  pipe_through :api

  # Special endpoints MUST come before resources
  get "/tasks/next", TaskController, :next
  post "/tasks/claim", TaskController, :claim
  get "/tasks/:id/tree", TaskController, :tree

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
end
```

**Example Response (Goal):**

```json
{
  "data": {
    "type": "goal",
    "task": {
      "id": 1,
      "title": "Implement AI-Optimized Task System",
      "description": "Enable Kanban to store rich task metadata",
      "task_type": "goal",
      "status": "open",
      "priority": 0,
      "created_at": "2025-01-15T10:00:00Z"
    },
    "tasks": [
      {
        "type": "work",
        "task": {
          "id": 2,
          "title": "Extend task schema",
          "type": "work",
          "status": "completed",
          "complexity": "large",
          "estimated_files": "5-7",
          "parent_id": 1,
          "dependencies": [],
          "key_files": [
            {
              "file_path": "lib/kanban/schemas/task.ex",
              "note": "Task schema",
              "position": 1
            }
          ]
        },
        "children": null
      },
      {
        "type": "work",
        "task": {
          "id": 3,
          "title": "Add metadata fields",
          "type": "work",
          "status": "in_progress",
          "complexity": "medium",
          "parent_id": 1,
          "dependencies": [2]
        },
        "children": null
      },
      {
        "type": "defect",
        "task": {
          "id": 4,
          "title": "Fix validation bug",
          "type": "defect",
          "status": "open",
          "complexity": "small",
          "parent_id": 1,
          "dependencies": []
        },
        "children": null
      }
    ],
    "statistics": {
      "total_tasks": 3,
      "completed": 1,
      "in_progress": 1,
      "open": 1,
      "blocked": 0
    }
  }
}
```

**Example Response (Single Task):**

```json
{
  "data": {
    "type": "task",
    "task": {
      "id": 3,
      "title": "Extend task schema",
      "task_type": "task",
      "status": "completed",
      "complexity": "large",
      "estimated_files": "5-7",
      "parent_id": 2,
      "dependencies": []
    },
    "children": null
  }
}
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :task_tree_fetched]`
- [ ] Metrics: Counter of /tree endpoint calls
- [ ] Metrics: Histogram of tree depth (goal vs task)
- [ ] Metrics: Histogram of tree size (number of children)
- [ ] Logging: Log tree fetches at debug level (task ID, type, depth)

## Error Handling

- User sees: 401 if unauthorized, 403 if missing scope, 404 if task not found
- On failure: Clear error message if task ID invalid
- Validation: None (read-only endpoint)

## Common Pitfalls

- [ ] Don't forget to preload all associations for each task in tree
- [ ] Remember to order children by position or created_at
- [ ] Avoid N+1 queries - fetch all children in one query per level
- [ ] Don't forget to include statistics at each level
- [ ] Remember to handle tasks with no parent_id (root tasks)
- [ ] Avoid infinite loops if circular parent relationships exist
- [ ] Don't forget to parse text fields (key_files, verification_steps) to structured format
- [ ] Remember task_type field might be null for old tasks

## Dependencies

**Requires:** 02-add-task-metadata-fields.md, 06-create-api-authentication.md, 07-implement-task-crud-api.md
**Blocks:** None

## Out of Scope

- Don't implement depth limit (return full tree always)
- Don't add filtering by status in tree (return all children)
- Don't implement tree mutations (create/move tasks in hierarchy)
- Don't add sibling relationships (only parent/child)
- Future enhancement: Add ?depth=2 parameter to limit tree depth
- Future enhancement: Add ?include_completed=false to filter out completed tasks
- Future enhancement: Add breadcrumb path from root to current task
- Future enhancement: Cache tree structure for performance
