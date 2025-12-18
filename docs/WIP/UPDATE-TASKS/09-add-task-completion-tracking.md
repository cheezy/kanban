# Add Task Completion Tracking with Summary

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** When AI agents or users complete tasks, we need to capture detailed completion information: what files changed, what tests passed, any deviations from plan, and follow-up tasks identified. This creates an audit trail and helps improve future task planning.

**WHAT:** Implement complete_task function that updates task status, stores completion summary (JSONB), sets completed_at timestamp, and broadcasts completion event.

**WHERE:** Tasks context, API controller

## Acceptance Criteria

- [ ] Tasks.complete_task/2 function created
- [ ] PATCH /api/tasks/:id/complete endpoint added
- [ ] Completion summary stored as JSONB
- [ ] completed_at timestamp set automatically
- [ ] completed_by field populated
- [ ] Status updated to "completed"
- [ ] Estimation feedback fields populated (actual_complexity, actual_files_changed, time_spent_minutes)
- [ ] PubSub broadcasts completion event
- [ ] Validation ensures required completion fields present
- [ ] Dependent tasks unblocked automatically
- [ ] Tests cover happy path and validation

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add complete_task/2 function
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Check completion_summary field
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add complete action
- [docs/WIP/TASKS.md](docs/WIP/TASKS.md) - Completion summary format (lines 323-385)
- [docs/WIP/AI-WORKFLOW.md](docs/WIP/AI-WORKFLOW.md) - Completion data structure (lines 73-103)

## Technical Notes

**Patterns to Follow:**
- Use Ecto.Changeset for validation
- Store completion_summary as JSONB (complex nested structure)
- Set completed_at using DateTime.utc_now()
- Broadcast via Phoenix.PubSub
- Return updated task with all associations

**Database/Schema:**
- Tables: tasks (use existing completion fields from task 02)
- Migrations needed: No (fields added in task 02)
- Fields used:
  - completed_at (utc_datetime)
  - completed_by (string)
  - completion_summary (jsonb)
  - status (string) - updated to "completed"
  - actual_complexity (string) - actual complexity experienced (small, medium, large)
  - actual_files_changed (integer) - actual number of files modified
  - time_spent_minutes (integer) - actual time spent in minutes

**Completion Summary Structure:**
```elixir
%{
  files_changed: [%{path: string, changes: string}],
  tests_added: [string],
  verification_results: %{
    commands_run: [string],
    status: "passed" | "failed",
    output: string
  },
  implementation_notes: %{
    deviations: [string],
    discoveries: [string],
    edge_cases: [string]
  },
  estimation_feedback: %{
    estimated_complexity: string,      # What was estimated
    actual_complexity: string,         # What it actually was (stored in actual_complexity field)
    estimated_files: string,           # e.g., "2-3"
    actual_files_changed: integer,     # Count of files (stored in actual_files_changed field)
    time_spent_minutes: integer        # Actual time (stored in time_spent_minutes field)
  },
  telemetry_added: [string],
  follow_up_tasks: [string],
  known_limitations: [string]
}
```

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast task completion to board channel
- [ ] Phoenix Channels: Notify all board subscribers
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban/tasks_test.exs
mix test test/kanban_web/controllers/api/task_controller_test.exs

# Test in console
iex -S mix
alias Kanban.{Repo, Tasks, Schemas.Task}

# Create a task
{:ok, task} = Tasks.create_task(%{
  title: "Test task",
  status: "in_progress",
  created_by: "user:1"
})

# Complete the task
completion_data = %{
  completed_by: "ai_agent:claude-sonnet-4.5",
  actual_complexity: "medium",
  actual_files_changed: 3,
  time_spent_minutes: 25,
  completion_summary: %{
    files_changed: [
      %{path: "lib/kanban/tasks.ex", changes: "Added complete_task/2 function"}
    ],
    verification_results: %{
      commands_run: ["mix test"],
      status: "passed",
      output: "All tests passed"
    },
    estimation_feedback: %{
      estimated_complexity: "small",
      actual_complexity: "medium",
      estimated_files: "1-2",
      actual_files_changed: 3,
      time_spent_minutes: 25
    }
  }
}

{:ok, completed_task} = Tasks.complete_task(task, completion_data)
IO.inspect(completed_task.status, label: "Status")
IO.inspect(completed_task.completed_at, label: "Completed at")
IO.inspect(completed_task.actual_complexity, label: "Actual complexity")
IO.inspect(completed_task.time_spent_minutes, label: "Time spent")

# Test via API
export TOKEN="kan_dev_your_token_here"
curl -X PATCH http://localhost:4000/api/tasks/1/complete \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "completion": {
      "completed_by": "ai_agent:claude-sonnet-4.5",
      "actual_complexity": "medium",
      "actual_files_changed": 3,
      "time_spent_minutes": 25,
      "completion_summary": {
        "files_changed": [
          {"path": "lib/kanban/tasks.ex", "changes": "Added function"}
        ],
        "verification_results": {
          "status": "passed",
          "commands_run": ["mix test"]
        },
        "estimation_feedback": {
          "estimated_complexity": "small",
          "actual_complexity": "medium",
          "estimated_files": "1-2",
          "actual_files_changed": 3,
          "time_spent_minutes": 25
        }
      }
    }
  }'

# Run all checks
mix precommit
```

**Manual Testing:**
1. Create task via API
2. Update status to "in_progress"
3. Complete task via PATCH /complete with full summary
4. Verify status changed to "completed"
5. Verify completed_at timestamp set
6. Verify completion_summary stored correctly
7. Verify PubSub broadcast received
8. Create task B that depends on task A
9. Complete task A
10. Verify task B now appears in /ready endpoint

**Success Looks Like:**
- Task status updated to "completed"
- Completion timestamp set
- Summary stored in JSONB field
- Estimation feedback fields populated (actual_complexity, actual_files_changed, time_spent_minutes)
- PubSub broadcast sent
- Dependent tasks unblocked
- All tests pass
- API returns updated task with estimation data

## Data Examples

**Context Function:**
```elixir
defmodule Kanban.Tasks do
  alias Kanban.Repo
  alias Kanban.Schemas.Task
  import Ecto.Changeset

  def complete_task(%Task{} = task, attrs) do
    changeset =
      task
      |> cast(attrs, [:completed_by, :completion_summary, :actual_complexity, :actual_files_changed, :time_spent_minutes])
      |> put_change(:status, "completed")
      |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> validate_required([:completed_by, :completion_summary])
      |> validate_inclusion(:status, ["in_progress", "blocked"], message: "can only complete tasks that are in progress or blocked")
      |> validate_inclusion(:actual_complexity, ["small", "medium", "large"], allow_nil: true)
      |> validate_completion_summary()

    case Repo.update(changeset) do
      {:ok, completed_task} = result ->
        # Broadcast completion
        :telemetry.execute(
          [:kanban, :task, :completed],
          %{task_id: completed_task.id},
          %{completed_by: completed_task.completed_by}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{completed_task.column.board_id}",
          {:task_completed, completed_task}
        )

        result

      error ->
        error
    end
  end

  defp validate_completion_summary(changeset) do
    case get_change(changeset, :completion_summary) do
      nil ->
        changeset

      summary when is_map(summary) ->
        required_keys = ["files_changed", "verification_results"]

        missing_keys =
          required_keys
          |> Enum.reject(&Map.has_key?(summary, &1))

        if Enum.empty?(missing_keys) do
          changeset
        else
          add_error(
            changeset,
            :completion_summary,
            "missing required keys: #{Enum.join(missing_keys, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :completion_summary, "must be a map")
    end
  end
end
```

**API Controller Action:**
```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  def complete(conn, %{"id" => id, "completion" => completion_params}) do
    if has_scope?(conn, "tasks:write") do
      task = Tasks.get_task!(id)

      case Tasks.complete_task(task, completion_params) do
        {:ok, completed_task} ->
          render(conn, "show.json", task: completed_task)

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

**Router Update:**
```elixir
scope "/api", KanbanWeb.API do
  pipe_through :api

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
  get "/tasks/ready", TaskController, :ready
  patch "/tasks/:id/complete", TaskController, :complete
end
```

**Example Request:**
```json
{
  "completion": {
    "completed_by": "ai_agent:claude-sonnet-4.5",
    "completion_summary": {
      "files_changed": [
        {
          "path": "lib/kanban_web/live/board_live.ex",
          "changes": "Added priority filter dropdown to header"
        },
        {
          "path": "lib/kanban_web/live/board_live.html.heex",
          "changes": "Added filter UI component"
        }
      ],
      "tests_added": [
        "test/kanban_web/live/board_live_test.exs"
      ],
      "verification_results": {
        "commands_run": ["mix test", "mix precommit"],
        "status": "passed",
        "output": "All 512 tests passed, no warnings"
      },
      "implementation_notes": {
        "deviations": ["Added nil priority handling"],
        "discoveries": ["Existing filter pattern worked perfectly"],
        "edge_cases": ["Tasks with nil priority show in 'All' filter"]
      },
      "telemetry_added": ["[:kanban, :filter, :used]"],
      "follow_up_tasks": [],
      "known_limitations": ["Sorting by priority not implemented yet"]
    }
  }
}
```

## Observability

- [ ] Telemetry event: `[:kanban, :task, :completed]`
- [ ] Telemetry event: `[:kanban, :task, :completion_failed]`
- [ ] Metrics: Counter of completed tasks by creator type (human/AI)
- [ ] Metrics: Histogram of task completion time (completed_at - inserted_at)
- [ ] Logging: Log task completion at info level with task ID and completed_by

## Error Handling

- User sees: Validation error if completion_summary missing required fields
- On failure: Task status remains unchanged, completion not recorded
- Validation:
  - Can only complete tasks with status "in_progress" or "blocked"
  - completed_by required
  - completion_summary must have files_changed and verification_results

## Common Pitfalls

- [ ] Don't forget to validate task status before completing (can't complete "open" task)
- [ ] Remember to broadcast PubSub event after completion
- [ ] Avoid allowing re-completion of already completed tasks
- [ ] Don't forget to preload associations before returning
- [ ] Remember completion_summary validation (required keys)
- [ ] Avoid setting completed_at manually - use DateTime.utc_now()
- [ ] Don't forget to update dependent tasks (unblock them)

## Dependencies

**Requires:** 02-add-task-metadata-fields.md, 04-implement-task-crud-api.md
**Blocks:** None

## Follow-Up Task Creation Workflow

**Important:** When completing tasks, agents should create new tasks for any follow-up work discovered.

### Workflow Steps

1. **Complete Current Task:** Call PATCH /api/tasks/:id/complete with completion summary
2. **Document Follow-Ups:** Include follow-up tasks in `completion_summary.follow_up_tasks` array
3. **Create New Tasks:** Immediately create new tasks via POST /api/tasks for each follow-up item
4. **Link Dependencies:** Add current task ID to new task's dependencies if applicable

### Example: Creating Follow-Up Tasks After Completion

```bash
# Step 1: Complete current task (W42: Add user authentication)
curl -X PATCH http://localhost:4000/api/tasks/42/complete \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "completion": {
      "completed_by": "ai_agent:claude-sonnet-4.5",
      "actual_complexity": "large",
      "actual_files_changed": 8,
      "time_spent_minutes": 65,
      "completion_summary": {
        "files_changed": [...],
        "verification_results": {...},
        "follow_up_tasks": [
          "Add password reset flow",
          "Implement 2FA support",
          "Add session timeout configuration"
        ]
      }
    }
  }'

# Step 2: Create follow-up task #1
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Add password reset flow",
      "complexity": "medium",
      "estimated_files": "3-4",
      "why": "Follow-up from W42: Users need ability to reset forgotten passwords",
      "what": "Implement email-based password reset with token expiration",
      "where_context": "Authentication system",
      "dependencies": [42]
    }
  }'

# Step 3: Create follow-up task #2
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "task": {
      "title": "Implement 2FA support",
      "complexity": "large",
      "estimated_files": "5-6",
      "why": "Follow-up from W42: Enhanced security for sensitive accounts",
      "what": "Add TOTP-based two-factor authentication",
      "where_context": "Authentication system",
      "dependencies": [42]
    }
  }'

# Continue for remaining follow-up tasks...
```

### Benefits of Creating Follow-Up Tasks

- **Prevents Work From Being Forgotten:** Follow-ups become visible, trackable tasks
- **Enables Parallel Work:** Other agents can claim follow-up tasks
- **Maintains Dependency Chain:** Proper ordering ensures prerequisites are met
- **Provides Audit Trail:** Historical record of how work evolved
- **Improves Planning:** Follow-ups are estimated and tracked like any other work

## Out of Scope

- Don't implement automatic follow-up task creation (agents create manually via API)
- Don't add completion approval workflow
- Don't implement completion summary templates
- Don't add AI-powered completion validation
- Future enhancement: Auto-create follow-up tasks from completion_summary.follow_up_tasks array
