# Implement Task CRUD API Endpoints

**Complexity:** Large | **Est. Files:** 6-8

## Description

**WHY:** AI agents need JSON API endpoints to create, read, update, and delete tasks programmatically. HTTP REST API is the standard way for external tools to interact with the application.

**WHAT:** Create JSON API endpoints for task CRUD operations, including creating tasks with nested associations (key_files, verification_steps, pitfalls), fetching tasks with all related data, and updating task fields.

**WHERE:** New API controller and JSON views

## Acceptance Criteria

- [ ] POST /api/tasks creates task with all fields
- [ ] GET /api/tasks lists tasks with pagination
- [ ] GET /api/tasks/:id returns single task with associations
- [ ] PATCH /api/tasks/:id updates task fields
- [ ] DELETE /api/tasks/:id soft-deletes or removes task
- [ ] Nested associations handled in create/update
- [ ] JSON responses follow consistent format
- [ ] Error responses include validation details
- [ ] Scopes enforced (tasks:read, tasks:write, tasks:delete)
- [ ] All endpoints return proper HTTP status codes

## Eating Our Own Dog Food

**Start Using This:** Once this task is complete, all remaining tasks (08-15) should be created and managed via the API instead of manually in the UI.

**How to use:**

1. Complete this task (07) using manual/UI methods
2. Create task 08 via POST /api/tasks endpoint
3. Update task status via PATCH /api/tasks/:id as you work
4. Use GET /api/tasks to view remaining work
5. For tasks 09-15, use the API exclusively for task creation and updates
6. When completing any task, create new tasks for follow-up work discovered

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Task context functions to use
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Schema with all fields
- [lib/kanban_web/router.ex](lib/kanban_web/router.ex) - Add /api routes
- [lib/kanban_web/controllers/page_controller.ex](lib/kanban_web/controllers/page_controller.ex) - Controller pattern example
- [docs/WIP/AI-WORKFLOW.md](docs/WIP/AI-WORKFLOW.md) - Expected JSON format (lines 73-171)

## Technical Notes

**Patterns to Follow:**
- Use Phoenix.Controller for API endpoints
- JSON responses via Phoenix.View or Jason.encode
- Leverage existing Tasks context functions
- Follow RESTful conventions
- Preload associations to avoid N+1 queries
- Use Ecto.Changeset for validation

**Database/Schema:**
- Tables: Uses existing tasks table and associations
- Migrations needed: No
- Context functions needed:
  - Tasks.list_tasks(filters, pagination)
  - Tasks.get_task!(id) with preloads
  - Tasks.create_task(attrs) with nested associations
  - Tasks.update_task(task, attrs)
  - Tasks.delete_task(task)

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast task created/updated/deleted to board channel
- [ ] Phoenix Channels: Notify all board subscribers of changes
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban_web/controllers/api/task_controller_test.exs
mix test test/kanban/tasks_test.exs

# Test API manually
export TOKEN="kan_dev_your_token_here"

# Create task
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Add user search",
      "complexity": "medium",
      "estimated_files": "2-3",
      "why": "Users need to find other users quickly",
      "what": "Add search bar to users index",
      "where_context": "Users list page header",
      "key_files": [
        {"file_path": "lib/kanban_web/live/user_live/index.ex", "note": "Main LiveView", "position": 1}
      ],
      "verification_steps": [
        {"step_type": "command", "step_text": "mix test test/kanban/accounts_test.exs", "position": 1}
      ]
    }
  }'

# List tasks
curl http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN"

# Get specific task
curl http://localhost:4000/api/tasks/1 \
  -H "Authorization: Bearer $TOKEN"

# Update task
curl -X PATCH http://localhost:4000/api/tasks/1 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"task": {"complexity": "large"}}'

# Run all checks
mix precommit
```

**Manual Testing:**
1. Create API token via UI
2. Test POST /api/tasks with valid data
3. Test POST with invalid data (verify error messages)
4. Test GET /api/tasks (verify pagination)
5. Test GET /api/tasks/:id (verify associations loaded)
6. Test PATCH /api/tasks/:id
7. Test DELETE /api/tasks/:id
8. Verify PubSub broadcasts to board channel
9. Check LiveView updates in real-time
10. Test without token (should 401)
11. Test with revoked token (should 401)

**Success Looks Like:**
- Can create tasks via API with all fields
- Nested associations created correctly
- API returns proper JSON structure
- Validation errors returned clearly
- PubSub broadcasts work
- LiveView updates without refresh
- All CRUD operations functional
- Scopes enforced correctly

## Data Examples

**API Controller:**
```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks
  alias Kanban.Schemas.Task

  action_fallback KanbanWeb.FallbackController

  def index(conn, params) do
    # Enforce scope
    if has_scope?(conn, "tasks:read") do
      tasks = Tasks.list_tasks(params)
      render(conn, "index.json", tasks: tasks)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  def show(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:read") do
      task = Tasks.get_task!(id)
      render(conn, "show.json", task: task)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  def create(conn, %{"task" => task_params}) do
    if has_scope?(conn, "tasks:write") do
      case Tasks.create_task(task_params) do
        {:ok, task} ->
          # Broadcast to PubSub
          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{task.column.board_id}",
            {:task_created, task}
          )

          conn
          |> put_status(:created)
          |> render("show.json", task: task)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render("error.json", changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  def update(conn, %{"id" => id, "task" => task_params}) do
    if has_scope?(conn, "tasks:write") do
      task = Tasks.get_task!(id)

      case Tasks.update_task(task, task_params) do
        {:ok, task} ->
          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{task.column.board_id}",
            {:task_updated, task}
          )

          render(conn, "show.json", task: task)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render("error.json", changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  defp has_scope?(conn, required_scope) do
    api_token = conn.assigns[:api_token]
    required_scope in api_token.scopes
  end
end
```

**JSON View:**
```elixir
defmodule KanbanWeb.API.TaskView do
  use KanbanWeb, :view

  def render("index.json", %{tasks: tasks}) do
    %{
      data: render_many(tasks, __MODULE__, "task.json"),
      meta: %{count: length(tasks)}
    }
  end

  def render("show.json", %{task: task}) do
    %{data: render_one(task, __MODULE__, "task.json")}
  end

  def render("task.json", %{task: task}) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      complexity: task.complexity,
      estimated_files: task.estimated_files,
      why: task.why,
      what: task.what,
      where_context: task.where_context,
      patterns_to_follow: task.patterns_to_follow,
      database_changes: task.database_changes,
      pubsub_required: task.pubsub_required,
      channels_required: task.channels_required,
      telemetry_event: task.telemetry_event,
      metrics_to_track: task.metrics_to_track,
      logging_requirements: task.logging_requirements,
      error_user_message: task.error_user_message,
      error_on_failure: task.error_on_failure,
      validation_rules: task.validation_rules,
      migration_needed: task.migration_needed,
      breaking_change: task.breaking_change,
      key_files: render_many(task.key_files, __MODULE__, "key_file.json", as: :key_file),
      verification_steps: render_many(task.verification_steps, __MODULE__, "verification_step.json", as: :step),
      pitfalls: render_many(task.pitfalls, __MODULE__, "pitfall.json", as: :pitfall),
      out_of_scope: render_many(task.out_of_scope, __MODULE__, "out_of_scope.json", as: :item),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  def render("key_file.json", %{key_file: kf}) do
    %{
      id: kf.id,
      file_path: kf.file_path,
      note: kf.note,
      position: kf.position
    }
  end

  def render("verification_step.json", %{step: step}) do
    %{
      id: step.id,
      step_type: step.step_type,
      step_text: step.step_text,
      expected_result: step.expected_result,
      position: step.position
    }
  end

  def render("pitfall.json", %{pitfall: pitfall}) do
    %{
      id: pitfall.id,
      pitfall_text: pitfall.pitfall_text,
      position: pitfall.position
    }
  end

  def render("out_of_scope.json", %{item: item}) do
    %{
      id: item.id,
      item_text: item.item_text,
      position: item.position
    }
  end

  def render("error.json", %{changeset: changeset}) do
    %{
      errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
    }
  end
end
```

**Context Functions:**

**IMPORTANT:** Always use the `Tasks` context functions (`Tasks.create_task/2`, `Tasks.update_task/2`, `Tasks.delete_task/1`) instead of calling `Repo` directly. These context functions include critical broadcasting logic via Phoenix PubSub that ensures all connected LiveView clients receive real-time updates.

```elixir
defmodule Kanban.Tasks do
  alias Kanban.Repo
  alias Kanban.Schemas.Task

  # Use existing context functions - they handle PubSub broadcasting automatically
  # Located in lib/kanban/tasks.ex

  # Key functions for API:
  # - Tasks.create_task(column, attrs) - Creates task and broadcasts :task_created
  # - Tasks.update_task(task, attrs) - Updates task and broadcasts appropriate event
  # - Tasks.delete_task(task) - Deletes task and broadcasts :task_deleted
  # - Tasks.get_task!(id) - Gets task with preloaded associations
  # - Tasks.move_task(task, column, position) - Moves task and broadcasts :task_moved

  # Broadcasting is handled automatically:
  # - create_task/2 broadcasts {Kanban.Tasks, :task_created, task}
  # - update_task/2 broadcasts based on what changed:
  #   - :task_status_changed when status changes
  #   - :task_claimed when claimed_at changes
  #   - :task_completed when completed_at changes
  #   - :task_reviewed when review_status changes
  #   - :task_updated for other updates
  # - delete_task/1 broadcasts {Kanban.Tasks, :task_deleted, task}
  # - move_task/3 broadcasts {Kanban.Tasks, :task_moved, task}

  # All broadcasts go to "board:#{board_id}" topic
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :task_created]`
- [ ] Telemetry event: `[:kanban, :api, :task_updated]`
- [ ] Telemetry event: `[:kanban, :api, :task_deleted]`
- [ ] Telemetry event: `[:kanban, :api, :task_listed]`
- [ ] Metrics: Counter of API requests by endpoint
- [ ] Metrics: Counter of API errors by type
- [ ] Logging: Log API requests at debug level with token ID

## Error Handling

- User sees: JSON error response with validation details
- On failure: Task not created/updated, transaction rolled back
- Validation: Changeset validates all fields, nested associations validated

## Common Pitfalls

- [ ] Don't forget to preload associations (avoid N+1 queries)
- [ ] Remember to broadcast PubSub events after mutations
- [ ] Avoid returning sensitive data in JSON (like token hashes)
- [ ] Don't forget to check scopes before each action
- [ ] Remember to handle nested association params in changeset
- [ ] Avoid circular dependencies in JSON rendering
- [ ] Don't forget proper HTTP status codes (201 for create, 204 for delete, etc.)
- [ ] Remember to validate position fields in nested associations

## Dependencies

**Requires:** 01A-extend-task-schema-scalar-fields.md, 01B-extend-task-schema-jsonb-collections.md, 02-add-task-metadata-fields.md, 06-create-api-authentication.md
**Blocks:** 08-add-task-ready-endpoint.md, 09-add-task-completion-tracking.md

## Out of Scope

- Don't implement GraphQL API (REST only for now)
- Don't add bulk operations (batch create/update)
- Don't implement task search/filtering (beyond basic status/complexity)
- Don't add webhook notifications
- Don't implement API versioning yet
