# Add AI Agent Metadata Tracking

**Complexity:** Small | **Est. Files:** 2-3

## Description

**WHY:** Need to distinguish between tasks created by humans vs AI agents, track which AI model created/completed tasks, and potentially adjust UI/behavior based on creator type.

**WHAT:** Enhance created_by and completed_by fields to store AI agent information, add UI indicators showing AI-created tasks, and track AI agent metadata (model name, version, capabilities).

**WHERE:** Tasks context, API endpoints, UI components

## Acceptance Criteria

- [ ] created_by format supports "ai_agent:model_name"
- [ ] completed_by format supports "ai_agent:model_name"
- [ ] API accepts AI agent identifier in create/complete requests
- [ ] UI shows badge/icon for AI-created tasks
- [ ] UI shows AI agent name in task details
- [ ] Statistics endpoint shows human vs AI task counts
- [ ] Validation ensures created_by/completed_by format correct
- [ ] Tests cover AI agent tracking

## Key Files to Read First

- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - created_by, completed_by fields (from task 02)
- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Create/complete functions
- [lib/kanban_web/live/board_live.ex](lib/kanban_web/live/board_live.ex) - Add AI badges to task cards
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Extract AI agent from token
- [docs/WIP/AI-WORKFLOW.md](docs/WIP/AI-WORKFLOW.md) - AI agent metadata format

## Technical Notes

**Patterns to Follow:**
- Format: "ai_agent:claude-sonnet-4.5" or "user:123"
- Extract AI agent info from API token scopes or metadata
- Add validation for format
- Display AI badge in UI using creator type

**Database/Schema:**
- Tables: tasks (use existing created_by, completed_by from task 02)
- Migrations needed: No (fields already exist)
- Format validation:
  - Must match "user:\d+" or "ai_agent:[a-z0-9-.]+"

**Integration Points:**
- [ ] PubSub broadcasts: Include creator metadata in events
- [ ] Phoenix Channels: None
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban/tasks_test.exs
mix test test/kanban_web/controllers/api/task_controller_test.exs

# Test in console
iex -S mix
alias Kanban.Tasks

# Create task as AI agent
{:ok, ai_task} = Tasks.create_task(%{
  title: "AI-created task",
  created_by: "ai_agent:claude-sonnet-4.5",
  status: "open"
})

# Create task as user
{:ok, user_task} = Tasks.create_task(%{
  title: "User-created task",
  created_by: "user:42",
  status: "open"
})

# Get statistics
stats = Tasks.get_creation_statistics()
IO.inspect(stats, label: "Task statistics")

# Test API
export TOKEN="kan_dev_your_token_here"

# Create task via API (should auto-set created_by from token)
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Test task via API",
      "complexity": "small"
    }
  }'

# Run precommit
mix precommit
```

**Manual Testing:**
1. Create task via API with AI agent token
2. Verify created_by set to "ai_agent:model_name"
3. View task in UI - verify AI badge shows
4. Create task via UI as logged-in user
5. Verify created_by set to "user:id"
6. View task - verify user avatar/name shows
7. Complete task via API
8. Verify completed_by tracks AI agent
9. Check statistics endpoint
10. Verify counts for human vs AI tasks correct

**Success Looks Like:**
- AI-created tasks show badge in UI
- created_by format validated
- API auto-sets creator from token
- Statistics track human vs AI
- All tests pass

## Data Examples

**Schema Validation:**
```elixir
defmodule Kanban.Schemas.Task do
  # ... existing schema ...

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :created_by, :completed_by, ...])
    |> validate_required([:title])
    |> validate_creator_format(:created_by)
    |> validate_creator_format(:completed_by)
    # ... rest of validations ...
  end

  defp validate_creator_format(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        if valid_creator_format?(value) do
          changeset
        else
          add_error(
            changeset,
            field,
            "must be in format 'user:ID' or 'ai_agent:MODEL_NAME'"
          )
        end

      _ ->
        add_error(changeset, field, "must be a string")
    end
  end

  defp valid_creator_format?(value) do
    Regex.match?(~r/^(user:\d+|ai_agent:[a-z0-9\-\.]+)$/, value)
  end
end
```

**API Controller Enhancement:**
```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  def create(conn, %{"task" => task_params}) do
    if has_scope?(conn, "tasks:write") do
      # Auto-set created_by from API token
      task_params_with_creator =
        task_params
        |> Map.put("created_by", get_creator_identifier(conn))

      case Tasks.create_task(task_params_with_creator) do
        {:ok, task} ->
          :telemetry.execute(
            [:kanban, :api, :task_created],
            %{task_id: task.id},
            %{created_by: task.created_by}
          )

          # ... rest of create logic ...
      end
    end
  end

  def complete(conn, %{"id" => id, "completion" => completion_params}) do
    if has_scope?(conn, "tasks:write") do
      task = Tasks.get_task!(id)

      # Auto-set completed_by from API token
      completion_params_with_completer =
        completion_params
        |> Map.put("completed_by", get_creator_identifier(conn))

      case Tasks.complete_task(task, completion_params_with_completer) do
        # ... rest of completion logic ...
      end
    end
  end

  defp get_creator_identifier(conn) do
    api_token = conn.assigns[:api_token]

    # Check if token has AI agent metadata
    case api_token.metadata do
      %{"ai_agent" => model_name} ->
        "ai_agent:#{model_name}"

      _ ->
        # Human user
        user = conn.assigns[:current_user]
        "user:#{user.id}"
    end
  end

  # New endpoint for statistics
  def statistics(conn, _params) do
    if has_scope?(conn, "tasks:read") do
      stats = Tasks.get_creation_statistics()
      json(conn, %{data: stats})
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end
end
```

**Context Function for Statistics:**
```elixir
defmodule Kanban.Tasks do
  import Ecto.Query

  def get_creation_statistics do
    tasks = Repo.all(Task)

    %{
      total: length(tasks),
      created_by_humans: Enum.count(tasks, &String.starts_with?(&1.created_by || "", "user:")),
      created_by_ai: Enum.count(tasks, &String.starts_with?(&1.created_by || "", "ai_agent:")),
      completed_by_humans: Enum.count(tasks, &String.starts_with?(&1.completed_by || "", "user:")),
      completed_by_ai: Enum.count(tasks, &String.starts_with?(&1.completed_by || "", "ai_agent:")),
      ai_models_used: get_ai_models_used(tasks)
    }
  end

  defp get_ai_models_used(tasks) do
    tasks
    |> Enum.flat_map(fn task ->
      [task.created_by, task.completed_by]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&String.starts_with?(&1, "ai_agent:"))
      |> Enum.map(&String.replace_prefix(&1, "ai_agent:", ""))
    end)
    |> Enum.frequencies()
  end
end
```

**UI Component for AI Badge:**
```elixir
defmodule KanbanWeb.TaskCardComponent do
  use KanbanWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="task-card">
      <div class="flex items-center justify-between">
        <h3 class="font-semibold"><%= @task.title %></h3>
        <.ai_badge :if={ai_created?(@task)} model={extract_ai_model(@task.created_by)} />
      </div>
      <!-- Rest of task card -->
    </div>
    """
  end

  defp ai_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-purple-100 text-purple-800">
      <.icon name="hero-cpu-chip" class="w-3 h-3 mr-1" />
      AI: <%= @model %>
    </span>
    """
  end

  defp ai_created?(task) do
    task.created_by && String.starts_with?(task.created_by, "ai_agent:")
  end

  defp extract_ai_model(created_by) when is_binary(created_by) do
    created_by
    |> String.replace_prefix("ai_agent:", "")
    |> String.split("-")
    |> List.first()
    |> String.capitalize()
  end

  defp extract_ai_model(_), do: "AI"
end
```

**Router Update:**
```elixir
scope "/api", KanbanWeb.API do
  pipe_through :api

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
  get "/tasks/ready", TaskController, :ready
  patch "/tasks/:id/complete", TaskController, :complete
  get "/tasks/:id/dependencies", TaskController, :dependencies
  get "/tasks/:id/dependents", TaskController, :dependents
  get "/tasks/statistics", TaskController, :statistics
end
```

**API Token Metadata (in api_tokens table):**
```elixir
# When creating AI agent token, include metadata
{:ok, token, plain_token} = Accounts.create_api_token(user, %{
  name: "Claude Sonnet 4.5 Agent",
  scopes: ["tasks:read", "tasks:write"],
  metadata: %{
    ai_agent: "claude-sonnet-4.5",
    capabilities: ["task_creation", "task_completion", "code_generation"]
  }
})
```

## Observability

- [ ] Telemetry event: `[:kanban, :task, :created_by_ai]`
- [ ] Telemetry event: `[:kanban, :task, :completed_by_ai]`
- [ ] Metrics: Counter of AI-created tasks by model
- [ ] Metrics: Histogram of AI task completion time
- [ ] Logging: Log AI agent actions at info level

## Error Handling

- User sees: Validation error if created_by/completed_by format invalid
- On failure: Task creation/completion fails with clear error
- Validation: Format must be "user:ID" or "ai_agent:MODEL"

## Common Pitfalls

- [ ] Don't forget to validate created_by format in changeset
- [ ] Remember to auto-set created_by from API token (don't trust client input)
- [ ] Avoid exposing internal user IDs in public APIs
- [ ] Don't forget to handle nil created_by (legacy tasks)
- [ ] Remember to extract model name from "ai_agent:model" format for display
- [ ] Avoid hardcoding AI model names - extract from created_by
- [ ] Don't forget to update PubSub broadcasts to include creator metadata

## Dependencies

**Requires:** 07-implement-task-dependencies.md
**Blocks:** None (final task)

## Out of Scope

- Don't implement AI model capability matching
- Don't add AI agent performance analytics dashboard
- Don't implement AI agent rate limiting by model
- Don't add AI model version tracking
- Future enhancement: Track AI agent performance metrics (tasks completed, success rate)
- Future enhancement: Add AI model recommendations based on task complexity
