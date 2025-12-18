# Add GET /api/tasks/next and POST /api/tasks/claim Endpoints

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** AI agents need to discover and atomically claim the next task to work on. Multiple agents may be working concurrently, so claiming must prevent race conditions where two agents grab the same task.

**WHAT:** Create two endpoints: GET /api/tasks/next (peek at next available task) and POST /api/tasks/claim (atomically claim the next task). The claim endpoint ensures only one agent can claim a task even if multiple agents request simultaneously.

**WHERE:** API controller, Tasks context

## Acceptance Criteria

- [ ] GET /api/tasks/next returns single task (not array)
- [ ] Only returns tasks in "Ready" column
- [ ] Only returns tasks with status "open" (not claimed)
- [ ] Excludes tasks with incomplete dependencies
- [ ] Ordered by priority (0 = highest) then created_at (oldest first)
- [ ] Returns 404 if no tasks available
- [ ] POST /api/tasks/claim atomically claims next available task
- [ ] Claim endpoint updates status to "in_progress" in single query
- [ ] Claim returns 409 Conflict if all tasks already claimed
- [ ] Both endpoints include all task fields and associations
- [ ] Respects tasks:read and tasks:write scopes
- [ ] Returns 401 if no/invalid token
- [ ] Response includes column information

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add get_next_task/0 and claim_next_task/0 functions
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add next and claim actions
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Check dependencies, status, and column_id
- [lib/kanban/columns.ex](lib/kanban/columns.ex) - Query for "Ready" column
- [README.md](../../../README.md) - AI Workflow section (lines 23-36)

## Technical Notes

**Patterns to Follow:**
- Use Ecto query with join to Column table
- Filter by column name = "Ready"
- Subquery to check if all dependency tasks are completed
- Return single task (use `Repo.one()`, not `Repo.all()`)
- Order by priority (0 = highest), then created_at (oldest first)
- For claim endpoint, use `Repo.update_all()` with WHERE status = 'open' for atomicity
- Preload all associations
- Return 404 if no task available
- Return 409 Conflict if claim fails (task already claimed)

**Database/Schema:**
- Tables: tasks, columns
- Migrations needed: No
- Query logic for GET /api/tasks/next:
  - JOIN columns ON task.column_id = column.id
  - WHERE column.name = 'Ready'
  - AND task.status = 'open'
  - AND (dependencies = [] OR all dependencies.status = 'completed')
  - ORDER BY COALESCE(priority, 999) ASC, inserted_at ASC
  - LIMIT 1
- Query logic for POST /api/tasks/claim (atomic):
  - Same filters as above
  - UPDATE tasks SET status = 'in_progress', updated_at = NOW()
  - WHERE id IN (subquery above) AND status = 'open'
  - RETURNING *

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
alias Kanban.{Repo, Tasks, Columns, Schemas.Task}

# Get or create "Ready" column
ready_column = Columns.get_column_by_name("Ready")

# Create tasks in Ready column with different priorities
{:ok, task1} = Tasks.create_task(%{
  title: "Low priority task",
  status: "open",
  priority: 3,
  column_id: ready_column.id
})

{:ok, task2} = Tasks.create_task(%{
  title: "High priority task",
  status: "open",
  priority: 0,
  column_id: ready_column.id
})

{:ok, task3} = Tasks.create_task(%{
  title: "Blocked task",
  status: "open",
  priority: 0,
  dependencies: [task1.id],
  column_id: ready_column.id
})

# Get next task (should return task2 - highest priority, unblocked)
next = Tasks.get_next_task()
IO.inspect(next.title, label: "Next task")
# Expected: "High priority task"

# Claim task2
Tasks.update_task(task2, %{status: "in_progress"})

# Get next task again (should return task1 - task2 is claimed)
next = Tasks.get_next_task()
IO.inspect(next.title, label: "Next task after claim")
# Expected: "Low priority task"

# Test API
export TOKEN="kan_dev_your_token_here"

# Option 1: Peek at next task (doesn't claim it)
curl http://localhost:4000/api/tasks/next \
  -H "Authorization: Bearer $TOKEN"

# Option 2: Atomically claim next task (recommended)
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer $TOKEN"

# Try to claim again (should get different task or 409 if none left)
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer $TOKEN"

# Try to get next task when none available (should 404)
curl http://localhost:4000/api/tasks/next \
  -H "Authorization: Bearer $TOKEN"

# Run all checks
mix precommit
```

**Manual Testing:**

1. Create board with "Ready" column
2. Create 3 tasks in Ready column: A (priority 0), B (priority 1), C (priority 0, depends on B)
3. Call GET /api/tasks/next
4. Verify returns A (priority 0, oldest if tied)
5. Call POST /api/tasks/claim
6. Verify returns A and status changes to "in_progress"
7. Call GET /api/tasks/next again
8. Verify returns B (next highest priority, unblocked - A is no longer "open")
9. Simulate race condition: Have two agents call POST /api/tasks/claim simultaneously
10. Verify only one succeeds (returns task), other gets 409 Conflict
11. Complete task B via API
12. Call POST /api/tasks/claim
13. Verify returns C (now unblocked)
14. Test with invalid token (should 401)
15. Test when no tasks in Ready column (should 404 or 409)

**Success Looks Like:**

- Endpoint returns single task object (not array)
- Only tasks in "Ready" column are considered
- Priority 0 tasks returned before priority 1, 2, 3
- Blocked tasks not returned
- Claimed tasks (status != "open") not returned
- Returns 404 when no tasks available
- All associations preloaded
- JSON response follows API format
- Scopes enforced

## Data Examples

**Tasks Context Function:**

```elixir
defmodule Kanban.Tasks do
  import Ecto.Query
  alias Kanban.Repo
  alias Kanban.Schemas.{Task, Column}

  @doc """
  Gets the next task for an AI agent to work on.

  Returns the highest priority task from the "Ready" column that:
  - Has status "open" (not claimed)
  - Has all dependencies completed

  Orders by priority (0 = highest) then inserted_at (oldest first).
  Returns nil if no task available.
  """
  def get_next_task do
    # Subquery to find completed task IDs
    completed_task_ids =
      from t in Task,
      where: t.status == "completed",
      select: t.id

    # Main query for next task
    from t in Task,
    join: c in Column, on: t.column_id == c.id,
    where: c.name == "Ready",
    where: t.status == "open",
    where: fragment(
      "CASE
        WHEN cardinality(?) = 0 THEN true
        ELSE NOT EXISTS (
          SELECT 1
          FROM unnest(?) AS dep_id
          WHERE dep_id NOT IN (?)
        )
      END",
      t.dependencies,
      t.dependencies,
      subquery(completed_task_ids)
    ),
    order_by: [
      asc: coalesce(t.priority, 999),  # NULL priorities go last
      asc: t.inserted_at
    ],
    limit: 1,
    preload: [:column]
    |> Repo.one()
  end

  @doc """
  Atomically claims the next available task.

  Updates status to "in_progress" in a single query to prevent race conditions.
  Returns {:ok, task} if successful, {:error, :no_tasks_available} if none available.
  """
  def claim_next_task do
    # Subquery to find completed task IDs
    completed_task_ids =
      from t in Task,
      where: t.status == "completed",
      select: t.id

    # Subquery to find the next task ID
    next_task_id =
      from t in Task,
      join: c in Column, on: t.column_id == c.id,
      where: c.name == "Ready",
      where: t.status == "open",
      where: fragment(
        "CASE
          WHEN cardinality(?) = 0 THEN true
          ELSE NOT EXISTS (
            SELECT 1
            FROM unnest(?) AS dep_id
            WHERE dep_id NOT IN (?)
          )
        END",
        t.dependencies,
        t.dependencies,
        subquery(completed_task_ids)
      ),
      order_by: [
        asc: coalesce(t.priority, 999),
        asc: t.inserted_at
      ],
      limit: 1,
      select: t.id

    # Atomically update the task to in_progress
    # WHERE status = 'open' ensures only one agent can claim it
    case Repo.update_all(
      from(t in Task,
        where: t.id in subquery(next_task_id),
        where: t.status == "open"
      ),
      set: [status: "in_progress", updated_at: DateTime.utc_now()]
    ) do
      {1, _} ->
        # Successfully claimed - fetch the task with associations
        task_id = Repo.one(next_task_id)
        task = Repo.get!(Task, task_id) |> Repo.preload([:column])
        {:ok, task}

      {0, _} ->
        # No task available or it was just claimed by another agent
        {:error, :no_tasks_available}
    end
  end
end
```

**Controller Actions:**

```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  @doc """
  GET /api/tasks/next
  Returns the next available task without claiming it.
  Useful for peeking at what's available.
  """
  def next(conn, _params) do
    if has_scope?(conn, "tasks:read") do
      case Tasks.get_next_task() do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No tasks available in Ready column"})

        task ->
          :telemetry.execute(
            [:kanban, :api, :next_task_fetched],
            %{task_id: task.id},
            %{
              api_token_id: conn.assigns.api_token.id,
              priority: task.priority
            }
          )

          render(conn, "show.json", task: task)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions. Requires tasks:read scope"})
    end
  end

  @doc """
  POST /api/tasks/claim
  Atomically claims the next available task.
  This is the recommended endpoint for AI agents to prevent race conditions.
  """
  def claim(conn, _params) do
    if has_scope?(conn, "tasks:write") do
      case Tasks.claim_next_task() do
        {:ok, task} ->
          :telemetry.execute(
            [:kanban, :api, :task_claimed],
            %{task_id: task.id},
            %{
              api_token_id: conn.assigns.api_token.id,
              priority: task.priority,
              ai_agent: conn.assigns.api_token.metadata["ai_agent"]
            }
          )

          render(conn, "show.json", task: task)

        {:error, :no_tasks_available} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "No tasks available to claim. All tasks in Ready column are either blocked or already claimed."})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions. Requires tasks:write scope"})
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

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
end
```

**Example Response (Success):**

```json
{
  "data": {
    "id": 42,
    "title": "Add user search functionality",
    "description": "Implement search bar in user list",
    "complexity": "medium",
    "estimated_files": "2-3",
    "status": "open",
    "priority": 0,
    "dependencies": [],
    "column": {
      "id": 5,
      "name": "Ready",
      "position": 1
    },
    "key_files": [
      {
        "file_path": "lib/kanban_web/live/user_live/index.ex",
        "note": "Main LiveView component",
        "position": 1
      }
    ],
    "verification_steps": [
      {
        "step_type": "command",
        "step_text": "mix test test/kanban/accounts_test.exs",
        "expected_result": "All tests pass",
        "position": 1
      }
    ],
    "created_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T10:30:00Z"
  }
}
```

**Example Response (No Tasks Available):**

```json
{
  "error": "No tasks available in Ready column"
}
```

**AI Agent Workflow (Recommended):**

```bash
# Step 1: Atomically claim next task
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer kan_live_abc123..."

# Response: {"data": {"id": 42, "title": "Add user search", "status": "in_progress", ...}}

# Step 2: Implement the task...

# Step 3: Complete the task
curl -X PATCH http://localhost:4000/api/tasks/42 \
  -H "Authorization: Bearer kan_live_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "status": "completed",
    "completion_summary": "Files Changed:\n- lib/kanban_web/live/user_live/index.ex\n\nTests: All passed"
  }'
```

**Alternative Workflow (Peek First):**

```bash
# Step 1: Peek at next task (optional - doesn't claim it)
curl http://localhost:4000/api/tasks/next \
  -H "Authorization: Bearer kan_live_abc123..."

# Response: {"data": {"id": 42, "title": "Add user search", "status": "open", ...}}

# Step 2: Decide to claim it
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer kan_live_abc123..."

# If another agent claimed it between step 1 and 2:
# Response: 409 Conflict - {"error": "No tasks available to claim..."}

# Step 3: Implement and complete...
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :next_task_fetched]`
- [ ] Telemetry event: `[:kanban, :api, :task_claimed]` with ai_agent metadata
- [ ] Metrics: Counter of /next endpoint calls
- [ ] Metrics: Counter of /claim endpoint calls (successful and failed)
- [ ] Metrics: Histogram of task priority distribution
- [ ] Metrics: Gauge of tasks in Ready column over time
- [ ] Metrics: Counter of 409 Conflict responses (contention indicator)
- [ ] Logging: Log task claims at info level (task ID, priority, ai_agent)
- [ ] Logging: Log claim conflicts at debug level

## Error Handling

- User sees: 401 if unauthorized, 403 if missing scope
- GET /next: Returns 404 if no tasks available
- POST /claim: Returns 409 Conflict if no tasks available to claim
- On failure: Clear error messages explain why claim failed
- Validation: None (read-only for GET, atomic update for POST)

## Common Pitfalls

- [ ] Don't forget to check ALL dependencies are completed (not just some)
- [ ] Remember route order matters - put /tasks/next and /tasks/claim BEFORE /tasks/:id
- [ ] Don't forget to filter by column name = "Ready"
- [ ] Don't forget to filter out tasks with status != "open" in WHERE clause
- [ ] Remember to handle empty dependencies array vs nil
- [ ] Avoid returning tasks that block themselves (circular deps)
- [ ] Don't forget COALESCE for null priorities (they should go last)
- [ ] Remember to return 404 for GET, 409 for POST when no tasks available
- [ ] Don't return an array - return single task object
- [ ] Don't forget WHERE status = 'open' in the update_all query (prevents double-claim)
- [ ] Remember claim endpoint requires tasks:write scope (not just tasks:read)
- [ ] Don't use Repo.get() then Repo.update() - use update_all for atomicity

## Dependencies

**Requires:** 02-add-task-metadata-fields.md, 06-create-api-authentication.md, 07-implement-task-crud-api.md
**Blocks:** None (can be developed in parallel with 09-10)

## Out of Scope

- Don't implement timeout/auto-release of claimed tasks (future enhancement)
- Don't add complexity matching (return tasks matching agent capabilities)
- Don't implement priority scoring algorithm beyond simple 0-4 scale
- Don't add machine learning for task recommendations
- Don't track claim history (which agent attempted to claim when)
- Future enhancement: Add claim_expires_at for automatic release after 30 minutes
- Future enhancement: Add agent heartbeat to keep claim alive
- Future enhancement: Track claim attempts and failures for analytics
- Future enhancement: Add queue system for agents waiting for tasks
