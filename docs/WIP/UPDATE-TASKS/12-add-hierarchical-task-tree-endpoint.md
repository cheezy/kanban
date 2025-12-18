# Add GET /api/tasks/:id/tree Endpoint for Hierarchical Task Data

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** AI agents need to see the complete structure of work - which tasks belong to which features, which features belong to which epics. This provides context for planning and understanding dependencies across the entire project.

**WHAT:** Create GET /api/tasks/:id/tree endpoint that returns a nested JSON structure showing the complete hierarchy. If ID is an epic, return all features and their tasks. If ID is a feature, return all tasks. If ID is a task, return just that task. Include metadata about parent/child relationships.

**WHERE:** API controller, Tasks context

## Acceptance Criteria

- [ ] GET /api/tasks/:id/tree returns hierarchical JSON structure
- [ ] For epic: Returns epic → features → tasks (3 levels)
- [ ] For feature: Returns feature → tasks (2 levels)
- [ ] For task: Returns task only (1 level)
- [ ] Each item includes all rich fields (complexity, dependencies, etc.)
- [ ] Response includes counts (total tasks, completed, blocked)
- [ ] Respects tasks:read scope
- [ ] Returns 401 if no/invalid token
- [ ] Returns 404 if task ID not found
- [ ] Filters by task_type (epic, feature, task) automatically

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add get_task_tree/1 function
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add tree action
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Check parent_id and task_type fields
- [docs/WIP/TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md) - Epic/Feature/Task structure

## Technical Notes

**Patterns to Follow:**
- Use recursive query or multiple queries to build tree
- Preload all associations (key_files, verification_steps, etc.)
- Include parent_id and task_type in response
- Calculate statistics (total count, completed count, blocked count)
- Return depth indicator (epic=0, feature=1, task=2)
- Order children by position or created_at

**Database/Schema:**
- Tables: tasks (with parent_id self-reference)
- Migrations needed: No (assuming parent_id and task_type already exist)
- Query logic:
  - Start with root task (by ID)
  - If task_type = "epic", find all children with parent_id = epic.id and task_type = "feature"
  - For each feature, find all children with parent_id = feature.id and task_type = "task"
  - If task_type = "feature", find all children with task_type = "task"
  - If task_type = "task", return just that task

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

# Create epic → feature → task structure
{:ok, epic} = Tasks.create_task(%{
  title: "Implement AI-Optimized Task System",
  task_type: "epic",
  status: "open"
})

{:ok, feature1} = Tasks.create_task(%{
  title: "Database Schema Foundation",
  task_type: "feature",
  parent_id: epic.id,
  status: "open"
})

{:ok, task1} = Tasks.create_task(%{
  title: "Extend task schema",
  task_type: "task",
  parent_id: feature1.id,
  status: "open",
  complexity: "large"
})

{:ok, task2} = Tasks.create_task(%{
  title: "Add metadata fields",
  task_type: "task",
  parent_id: feature1.id,
  status: "completed",
  complexity: "medium"
})

# Get tree starting from epic
tree = Tasks.get_task_tree(epic.id)
IO.inspect(tree, limit: :infinity)

# Test API
export TOKEN="kan_dev_your_token_here"

# Get epic tree (includes all features and tasks)
curl http://localhost:4000/api/tasks/1/tree \
  -H "Authorization: Bearer $TOKEN"

# Get feature tree (includes all tasks)
curl http://localhost:4000/api/tasks/2/tree \
  -H "Authorization: Bearer $TOKEN"

# Get single task
curl http://localhost:4000/api/tasks/3/tree \
  -H "Authorization: Bearer $TOKEN"

# Run all checks
mix precommit
```

**Manual Testing:**

1. Create epic with 2 features, each with 3 tasks
2. Call GET /api/tasks/:epic_id/tree
3. Verify returns epic → features → tasks structure
4. Verify includes all rich fields for each item
5. Verify statistics are accurate (6 total tasks, etc.)
6. Call GET /api/tasks/:feature_id/tree
7. Verify returns feature → tasks (no epic)
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
      "epic" -> build_epic_tree(root)
      "feature" -> build_feature_tree(root)
      "task" -> build_task_node(root)
      _ -> build_task_node(root)
    end
  end

  defp build_epic_tree(epic) do
    features =
      from(t in Task,
        where: t.parent_id == ^epic.id,
        where: t.task_type == "feature",
        order_by: [asc: coalesce(t.position, t.inserted_at)]
      )
      |> Repo.all()
      |> Enum.map(&build_feature_tree/1)

    %{
      type: "epic",
      task: task_to_map(epic),
      features: features,
      statistics: calculate_epic_statistics(epic.id)
    }
  end

  defp build_feature_tree(feature) do
    tasks =
      from(t in Task,
        where: t.parent_id == ^feature.id,
        where: t.task_type == "task",
        order_by: [asc: coalesce(t.position, t.inserted_at)]
      )
      |> Repo.all()
      |> Repo.preload([:column])
      |> Enum.map(&build_task_node/1)

    %{
      type: "feature",
      task: task_to_map(feature),
      tasks: tasks,
      statistics: calculate_feature_statistics(feature.id)
    }
  end

  defp build_task_node(task) do
    %{
      type: "task",
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

  defp calculate_epic_statistics(epic_id) do
    # Get all tasks in all features under this epic
    task_counts =
      from(f in Task,
        join: t in Task, on: t.parent_id == f.id,
        where: f.parent_id == ^epic_id and f.task_type == "feature",
        where: t.task_type == "task",
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

  defp calculate_feature_statistics(feature_id) do
    task_counts =
      from(t in Task,
        where: t.parent_id == ^feature_id,
        where: t.task_type == "task",
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

**Example Response (Epic):**

```json
{
  "data": {
    "type": "epic",
    "task": {
      "id": 1,
      "title": "Implement AI-Optimized Task System",
      "description": "Enable Kanban to store rich task metadata",
      "task_type": "epic",
      "status": "open",
      "priority": 0,
      "created_at": "2025-01-15T10:00:00Z"
    },
    "features": [
      {
        "type": "feature",
        "task": {
          "id": 2,
          "title": "Database Schema Foundation",
          "task_type": "feature",
          "status": "in_progress",
          "parent_id": 1
        },
        "tasks": [
          {
            "type": "task",
            "task": {
              "id": 3,
              "title": "Extend task schema",
              "task_type": "task",
              "status": "completed",
              "complexity": "large",
              "estimated_files": "5-7",
              "parent_id": 2,
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
            "type": "task",
            "task": {
              "id": 4,
              "title": "Add metadata fields",
              "task_type": "task",
              "status": "in_progress",
              "complexity": "medium",
              "parent_id": 2,
              "dependencies": [3]
            },
            "children": null
          }
        ],
        "statistics": {
          "total_tasks": 2,
          "completed": 1,
          "in_progress": 1,
          "open": 0,
          "blocked": 0
        }
      }
    ],
    "statistics": {
      "total_tasks": 11,
      "completed": 3,
      "in_progress": 2,
      "open": 5,
      "blocked": 1
    }
  }
}
```

**Example Response (Feature):**

```json
{
  "data": {
    "type": "feature",
    "task": {
      "id": 2,
      "title": "Database Schema Foundation",
      "task_type": "feature",
      "status": "in_progress",
      "parent_id": 1
    },
    "tasks": [
      {
        "type": "task",
        "task": {
          "id": 3,
          "title": "Extend task schema",
          "task_type": "task",
          "status": "completed",
          "complexity": "large"
        },
        "children": null
      },
      {
        "type": "task",
        "task": {
          "id": 4,
          "title": "Add metadata fields",
          "task_type": "task",
          "status": "in_progress",
          "complexity": "medium",
          "dependencies": [3]
        },
        "children": null
      }
    ],
    "statistics": {
      "total_tasks": 2,
      "completed": 1,
      "in_progress": 1,
      "open": 0,
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
- [ ] Metrics: Histogram of tree depth (epic vs feature vs task)
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
