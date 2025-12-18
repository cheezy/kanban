# Add GET /api/tasks/next and POST /api/tasks/claim Endpoints

**Complexity:** Medium | **Est. Files:** 4-5

## Description

**WHY:** AI agents need to discover and atomically claim the next task to work on. Multiple agents may be working concurrently, so claiming must prevent race conditions where two agents grab the same task. Tasks must auto-release after 60 minutes of inactivity to prevent abandoned work from blocking other agents. Tasks should only be offered to agents with the required capabilities to complete them. Agents must be able to release tasks they can't complete immediately.

**WHAT:** Create four endpoints: GET /api/tasks/next (peek at next available task), POST /api/tasks/claim (atomically claim the next task), POST /api/tasks/:id/unclaim (release a claimed task back to "open"), and GET /api/tasks/:id/validate (validate task readiness before claiming). The claim endpoint ensures only one agent can claim a task even if multiple agents request simultaneously. The unclaim endpoint allows agents to release tasks they realize they can't complete. The validate endpoint checks authentication, scopes, capabilities, and dependencies without side effects. Add automatic task release after 60 minutes of inactivity (no updates to the task). All endpoints filter tasks by agent capabilities - only return tasks where the agent has ALL required capabilities.

**WHERE:** API controller, Tasks context

## Acceptance Criteria

- [ ] GET /api/tasks/next returns single task (not array)
- [ ] Only returns tasks in "Ready" column
- [ ] Only returns tasks with status "open" (not claimed)
- [ ] Excludes tasks with incomplete dependencies
- [ ] Filters by agent capabilities - only returns tasks where agent has ALL required capabilities
- [ ] Tasks with empty required_capabilities are available to all agents
- [ ] Ordered by priority (0 = highest) then created_at (oldest first)
- [ ] Returns 404 if no tasks available
- [ ] POST /api/tasks/claim atomically claims next available task
- [ ] Claim endpoint updates status to "in_progress" and sets claimed_at timestamp
- [ ] Claim endpoint sets claim_expires_at to 60 minutes from now
- [ ] Claim returns 409 Conflict if all tasks already claimed
- [ ] POST /api/tasks/:id/unclaim releases claimed task back to "open"
- [ ] Unclaim endpoint validates agent can only unclaim tasks they claimed
- [ ] Unclaim endpoint accepts optional reason parameter for analytics
- [ ] Unclaim endpoint clears claimed_at and claim_expires_at timestamps
- [ ] Unclaim endpoint broadcasts task change via PubSub
- [ ] GET /api/tasks/:id/validate validates task readiness without claiming
- [ ] Validate endpoint checks authentication and scopes
- [ ] Validate endpoint checks if agent has required capabilities
- [ ] Validate endpoint checks if all dependencies are completed
- [ ] Validate endpoint returns readiness status and reason if not ready
- [ ] Tasks with expired claims (claim_expires_at < now) are treated as "open"
- [ ] Auto-release job runs every 5 minutes to reset expired claims
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
- Filter out tasks with expired claims (claim_expires_at IS NULL OR claim_expires_at > NOW())
- Filter by agent capabilities: task.required_capabilities is subset of agent.capabilities
- Subquery to check if all dependency tasks are completed
- Return single task (use `Repo.one()`, not `Repo.all()`)
- Order by priority (0 = highest), then created_at (oldest first)
- For claim endpoint, use `Repo.update_all()` with WHERE status = 'open' for atomicity
- Set claimed_at = NOW() and claim_expires_at = NOW() + 60 minutes
- Background job (Oban) runs every 5 minutes to release expired claims
- Preload all associations
- Return 404 if no task available
- Return 409 Conflict if claim fails (task already claimed)

**Database/Schema:**
- Tables: tasks, columns, api_tokens
- Migrations needed: Yes - add claimed_at, claim_expires_at, and required_capabilities to tasks table
- Query logic for GET /api/tasks/next:
  - JOIN columns ON task.column_id = column.id
  - WHERE column.name = 'Ready'
  - AND (task.status = 'open' OR (task.status = 'in_progress' AND task.claim_expires_at < NOW()))
  - AND (dependencies = [] OR all dependencies.status = 'completed')
  - AND (task.required_capabilities = [] OR task.required_capabilities <@ agent.capabilities)  # PostgreSQL array subset operator
  - ORDER BY COALESCE(priority, 999) ASC, inserted_at ASC
  - LIMIT 1
- Query logic for POST /api/tasks/claim (atomic):
  - Same filters as above
  - UPDATE tasks SET
      status = 'in_progress',
      claimed_at = NOW(),
      claim_expires_at = NOW() + INTERVAL '60 minutes',
      updated_at = NOW()
  - WHERE id IN (subquery above) AND (status = 'open' OR claim_expires_at < NOW())
  - RETURNING *
- Background job (every 5 minutes):
  - UPDATE tasks SET status = 'open', claimed_at = NULL, claim_expires_at = NULL
  - WHERE status = 'in_progress' AND claim_expires_at < NOW()

**Integration Points:**

- [ ] PubSub broadcasts: Broadcast when claim expires and task auto-released
- [ ] Phoenix Channels: None
- [ ] External APIs: None
- [ ] Oban: Background job to release expired claims every 5 minutes

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
{:ok, claimed_task} = Tasks.claim_next_task()
IO.inspect(claimed_task.claimed_at, label: "Claimed at")
IO.inspect(claimed_task.claim_expires_at, label: "Expires at")

# Get next task again (should return task1 - task2 is claimed)
next = Tasks.get_next_task()
IO.inspect(next.title, label: "Next task after claim")
# Expected: "Low priority task"

# Test expired claim release
# Manually set claim to expired
past_time = DateTime.add(DateTime.utc_now(), -61, :minute)
Repo.update_all(
  from(t in Task, where: t.id == ^claimed_task.id),
  set: [claim_expires_at: past_time]
)

# Release expired claims
{:ok, count} = Tasks.release_expired_claims()
IO.inspect(count, label: "Released count")
# Expected: 1

# Verify task is now available again
next = Tasks.get_next_task()
IO.inspect(next.title, label: "Next task after expiry")
# Expected: "High priority task" (task2 is available again)

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
14. Test claim expiry: Claim a task, manually set claim_expires_at to past, call release_expired_claims()
15. Verify expired task returns to "open" status and becomes available
16. Test with invalid token (should 401)
17. Test when no tasks in Ready column (should 404 or 409)
18. Wait 60 minutes (or manually trigger Oban job) and verify claimed task auto-releases

**Success Looks Like:**

- Endpoint returns single task object (not array)
- Only tasks in "Ready" column are considered
- Priority 0 tasks returned before priority 1, 2, 3
- Blocked tasks not returned
- Claimed tasks (status != "open") not returned unless claim expired
- Tasks auto-release after 60 minutes of inactivity
- Background job runs every 5 minutes to clean up expired claims
- Returns 404 when no tasks available
- All associations preloaded
- JSON response follows API format
- Scopes enforced
- Telemetry events fired for claim expiration

## Data Examples

**Migration:**

```elixir
defmodule Kanban.Repo.Migrations.AddClaimTimestampsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :claimed_at, :utc_datetime
      add :claim_expires_at, :utc_datetime
    end

    create index(:tasks, [:claim_expires_at])
    create index(:tasks, [:status, :claim_expires_at])
  end
end
```

**Tasks Context Function:**

```elixir
defmodule Kanban.Tasks do
  import Ecto.Query
  alias Kanban.Repo
  alias Kanban.Schemas.{Task, Column}

  @doc """
  Gets the next task for an AI agent to work on.

  Returns the highest priority task from the "Ready" column that:
  - Has status "open" (not claimed) OR has expired claim
  - Has all dependencies completed
  - Agent has all required capabilities (or task has no capability requirements)

  Orders by priority (0 = highest) then inserted_at (oldest first).
  Returns nil if no task available.
  """
  def get_next_task(agent_capabilities \\ []) do
    # Subquery to find completed task IDs
    completed_task_ids =
      from t in Task,
      where: t.status == "completed",
      select: t.id

    # Main query for next task
    now = DateTime.utc_now()

    from t in Task,
    join: c in Column, on: t.column_id == c.id,
    where: c.name == "Ready",
    where: t.status == "open" or (t.status == "in_progress" and t.claim_expires_at < ^now),
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
    where: fragment(
      "cardinality(?) = 0 OR ? <@ ?",
      t.required_capabilities,
      t.required_capabilities,
      ^agent_capabilities
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

  Updates status to "in_progress" and sets claim timestamps in a single query to prevent race conditions.
  Sets claim_expires_at to 60 minutes from now for automatic release.
  Only returns tasks where agent has all required capabilities.
  Returns {:ok, task} if successful, {:error, :no_tasks_available} if none available.
  """
  def claim_next_task(agent_capabilities \\ []) do
    # Subquery to find completed task IDs
    completed_task_ids =
      from t in Task,
      where: t.status == "completed",
      select: t.id

    # Subquery to find the next task ID
    now = DateTime.utc_now()

    next_task_id =
      from t in Task,
      join: c in Column, on: t.column_id == c.id,
      where: c.name == "Ready",
      where: t.status == "open" or (t.status == "in_progress" and t.claim_expires_at < ^now),
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
      where: fragment(
        "cardinality(?) = 0 OR ? <@ ?",
        t.required_capabilities,
        t.required_capabilities,
        ^agent_capabilities
      ),
      order_by: [
        asc: coalesce(t.priority, 999),
        asc: t.inserted_at
      ],
      limit: 1,
      select: t.id

    # Atomically update the task to in_progress with claim timestamps
    # WHERE clause ensures only one agent can claim it (checks status and expiry)
    claim_expires_at = DateTime.add(now, 60, :minute)

    case Repo.update_all(
      from(t in Task,
        where: t.id in subquery(next_task_id),
        where: t.status == "open" or t.claim_expires_at < ^now
      ),
      set: [
        status: "in_progress",
        claimed_at: now,
        claim_expires_at: claim_expires_at,
        updated_at: now
      ]
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

  @doc """
  Releases tasks with expired claims back to "open" status.

  This function should be called by a background job (Oban) every 5 minutes.
  It finds all tasks that are in_progress but have an expired claim_expires_at,
  resets them to "open" status, and broadcasts the change.
  """
  def release_expired_claims do
    now = DateTime.utc_now()

    # Find and update expired tasks atomically
    {count, tasks} = Repo.update_all(
      from(t in Task,
        where: t.status == "in_progress",
        where: t.claim_expires_at < ^now,
        select: [:id, :title]
      ),
      set: [
        status: "open",
        claimed_at: nil,
        claim_expires_at: nil,
        updated_at: now
      ]
    )

    # Broadcast each released task
    Enum.each(tasks, fn task ->
      :telemetry.execute(
        [:kanban, :task, :claim_expired],
        %{task_id: task.id},
        %{released_at: now}
      )

      # Fetch full task and broadcast
      full_task = get_task!(task.id)
      broadcast_task_change(full_task, :task_claim_expired)
    end)

    {:ok, count}
  end

  @doc """
  Validates if a task is ready to be claimed by an agent.

  Checks:
  - Task exists and is in Ready column
  - Task is not already claimed (or claim has expired)
  - Agent has all required capabilities
  - All dependencies are completed
  - Task is not blocked

  Returns {:ok, %{ready: true}} if task is ready to claim.
  Returns {:ok, %{ready: false, reason: string}} if not ready with explanation.
  Returns {:error, :not_found} if task doesn't exist.
  """
  def validate_task_readiness(task_id, agent_capabilities \\ []) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        task = Repo.preload(task, [:column])
        now = DateTime.utc_now()

        # Check column
        cond do
          task.column.name != "Ready" ->
            {:ok, %{ready: false, reason: "Task is not in Ready column (currently in '#{task.column.name}')"}}

          # Check if already claimed (and not expired)
          task.status == "in_progress" and task.claim_expires_at > now ->
            expires_in = DateTime.diff(task.claim_expires_at, now, :minute)
            {:ok, %{ready: false, reason: "Task is already claimed by another agent (expires in #{expires_in} minutes)"}}

          # Check capabilities
          length(task.required_capabilities) > 0 and not all_capabilities_present?(task.required_capabilities, agent_capabilities) ->
            missing = task.required_capabilities -- agent_capabilities
            {:ok, %{ready: false, reason: "Agent missing required capabilities: #{Enum.join(missing, ", ")}"}}

          # Check dependencies
          not all_dependencies_completed?(task.dependencies) ->
            {:ok, %{ready: false, reason: "Task has incomplete dependencies"}}

          # Check blocked status
          task.status == "blocked" ->
            {:ok, %{ready: false, reason: "Task is marked as blocked"}}

          # All checks passed
          true ->
            {:ok, %{ready: true, task: task}}
        end
    end
  end

  defp all_capabilities_present?(required, agent_caps) do
    Enum.all?(required, fn cap -> cap in agent_caps end)
  end

  defp all_dependencies_completed?([]), do: true
  defp all_dependencies_completed?(dep_ids) do
    completed_count = Repo.one(
      from t in Task,
      where: t.id in ^dep_ids and t.status == "completed",
      select: count(t.id)
    )
    completed_count == length(dep_ids)
  end

  @doc """
  Unclaims a task, releasing it back to "open" status.

  Agents can unclaim tasks they realize they can't complete (missing context, blocked by external factor).
  Validates that the agent making the request is the one who claimed the task.
  Accepts optional reason parameter for analytics.

  Returns {:ok, task} if successful, {:error, reason} if validation fails.
  """
  def unclaim_task(task_id, api_token_id, reason \\ nil) do
    task = get_task!(task_id)

    # Validate task is claimed and in_progress
    cond do
      task.status != "in_progress" ->
        {:error, :not_claimed}

      is_nil(task.claimed_at) ->
        {:error, :not_claimed}

      # Note: We don't validate which agent claimed it since we don't store that info
      # In the future, we could add a claimed_by_api_token_id field to validate ownership
      true ->
        now = DateTime.utc_now()

        changeset =
          task
          |> Ecto.Changeset.change(%{
            status: "open",
            claimed_at: nil,
            claim_expires_at: nil,
            updated_at: now
          })

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            # Emit telemetry
            :telemetry.execute(
              [:kanban, :task, :unclaimed],
              %{task_id: task.id},
              %{
                api_token_id: api_token_id,
                reason: reason,
                unclaimed_at: now,
                was_claimed_for_minutes: DateTime.diff(now, task.claimed_at, :minute)
              }
            )

            # Broadcast change
            updated_task = Repo.preload(updated_task, [:column])
            broadcast_task_change(updated_task, :task_unclaimed)

            {:ok, updated_task}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end
end
```

**Background Job (Oban):**

```elixir
defmodule Kanban.Workers.ReleaseExpiredClaims do
  @moduledoc """
  Background job that releases tasks with expired claims.
  Runs every 5 minutes via Oban cron.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    case Kanban.Tasks.release_expired_claims() do
      {:ok, count} when count > 0 ->
        require Logger
        Logger.info("Released #{count} expired task claims")
        :ok

      {:ok, 0} ->
        :ok
    end
  end
end
```

**Oban Configuration (config/config.exs):**

```elixir
config :kanban, Oban,
  repo: Kanban.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Release expired claims every 5 minutes
       {"*/5 * * * *", Kanban.Workers.ReleaseExpiredClaims}
     ]}
  ],
  queues: [maintenance: 10]
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
  Filters tasks by agent capabilities.
  """
  def next(conn, _params) do
    if has_scope?(conn, "tasks:read") do
      agent_capabilities = conn.assigns.api_token.capabilities || []

      case Tasks.get_next_task(agent_capabilities) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No tasks available in Ready column matching your capabilities"})

        task ->
          :telemetry.execute(
            [:kanban, :api, :next_task_fetched],
            %{task_id: task.id},
            %{
              api_token_id: conn.assigns.api_token.id,
              priority: task.priority,
              required_capabilities: task.required_capabilities
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
  Filters tasks by agent capabilities.
  """
  def claim(conn, _params) do
    if has_scope?(conn, "tasks:write") do
      agent_capabilities = conn.assigns.api_token.capabilities || []

      case Tasks.claim_next_task(agent_capabilities) do
        {:ok, task} ->
          :telemetry.execute(
            [:kanban, :api, :task_claimed],
            %{task_id: task.id},
            %{
              api_token_id: conn.assigns.api_token.id,
              priority: task.priority,
              ai_agent: conn.assigns.api_token.metadata["ai_agent"],
              required_capabilities: task.required_capabilities,
              agent_capabilities: agent_capabilities
            }
          )

          render(conn, "show.json", task: task)

        {:error, :no_tasks_available} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "No tasks available to claim matching your capabilities. All tasks in Ready column are either blocked, already claimed, or require capabilities you don't have."})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions. Requires tasks:write scope"})
    end
  end

  @doc """
  GET /api/tasks/:id/validate
  Validates if a task is ready to be claimed by the agent.
  Performs all readiness checks without claiming the task.
  """
  def validate(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:read") do
      agent_capabilities = conn.assigns.api_token.capabilities || []

      case Tasks.validate_task_readiness(id, agent_capabilities) do
        {:ok, %{ready: true, task: task}} ->
          json(conn, %{
            valid: true,
            ready: true,
            task: %{
              id: task.id,
              title: task.title,
              status: task.status,
              required_capabilities: task.required_capabilities,
              dependencies: task.dependencies
            },
            checks: %{
              authentication: "valid",
              scopes: "valid",
              capabilities: "valid",
              dependencies: "valid",
              column: "valid"
            }
          })

        {:ok, %{ready: false, reason: reason}} ->
          json(conn, %{
            valid: true,
            ready: false,
            reason: reason,
            checks: categorize_failure_reason(reason)
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Task not found"})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions. Requires tasks:read scope"})
    end
  end

  defp categorize_failure_reason(reason) do
    cond do
      String.contains?(reason, "capabilities") ->
        %{authentication: "valid", scopes: "valid", capabilities: "missing", dependencies: "unknown", column: "unknown"}

      String.contains?(reason, "dependencies") ->
        %{authentication: "valid", scopes: "valid", capabilities: "valid", dependencies: "incomplete", column: "valid"}

      String.contains?(reason, "column") ->
        %{authentication: "valid", scopes: "valid", capabilities: "valid", dependencies: "valid", column: "wrong"}

      String.contains?(reason, "claimed") ->
        %{authentication: "valid", scopes: "valid", capabilities: "valid", dependencies: "valid", column: "valid", availability: "claimed"}

      true ->
        %{authentication: "valid", scopes: "valid", capabilities: "valid", dependencies: "valid", column: "valid", status: "blocked"}
    end
  end

  @doc """
  POST /api/tasks/:id/unclaim
  Releases a claimed task back to "open" status.
  Allows agents to unclaim tasks they realize they can't complete.
  """
  def unclaim(conn, %{"id" => id} = params) do
    if has_scope?(conn, "tasks:write") do
      reason = params["reason"]

      case Tasks.unclaim_task(id, conn.assigns.api_token.id, reason) do
        {:ok, task} ->
          :telemetry.execute(
            [:kanban, :api, :task_unclaimed],
            %{task_id: task.id},
            %{
              api_token_id: conn.assigns.api_token.id,
              reason: reason,
              ai_agent: conn.assigns.api_token.metadata["ai_agent"]
            }
          )

          render(conn, "show.json", task: task)

        {:error, :not_claimed} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Task is not currently claimed"})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Task not found"})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_changeset_errors(changeset)})
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
  get "/tasks/:id/validate", TaskController, :validate
  post "/tasks/:id/unclaim", TaskController, :unclaim

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

**Unclaim Workflow (When Agent Can't Complete):**

```bash
# Step 1: Claim task
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer kan_live_abc123..."

# Response: {"data": {"id": 42, "title": "Implement OAuth2", "status": "in_progress", ...}}

# Step 2: Realize you can't complete it (missing OAuth2 libraries, blocked by external dependency)
curl -X POST http://localhost:4000/api/tasks/42/unclaim \
  -H "Authorization: Bearer kan_live_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "reason": "Missing OAuth2 library dependencies"
  }'

# Response: {"data": {"id": 42, "title": "Implement OAuth2", "status": "open", ...}}
# Task is now available for another agent to claim
```

**Validation Workflow (Check Before Claiming):**

```bash
# Step 1: Validate task readiness before claiming
curl http://localhost:4000/api/tasks/42/validate \
  -H "Authorization: Bearer kan_live_abc123..."

# Response (Ready to claim):
{
  "valid": true,
  "ready": true,
  "task": {
    "id": 42,
    "title": "Add user search",
    "status": "open",
    "required_capabilities": ["code_generation"],
    "dependencies": []
  },
  "checks": {
    "authentication": "valid",
    "scopes": "valid",
    "capabilities": "valid",
    "dependencies": "valid",
    "column": "valid"
  }
}

# Response (Not ready - missing capabilities):
{
  "valid": true,
  "ready": false,
  "reason": "Agent missing required capabilities: database_design, security_analysis",
  "checks": {
    "authentication": "valid",
    "scopes": "valid",
    "capabilities": "missing",
    "dependencies": "unknown",
    "column": "unknown"
  }
}

# Response (Not ready - dependencies incomplete):
{
  "valid": true,
  "ready": false,
  "reason": "Task has incomplete dependencies",
  "checks": {
    "authentication": "valid",
    "scopes": "valid",
    "capabilities": "valid",
    "dependencies": "incomplete",
    "column": "valid"
  }
}

# Step 2: If ready, claim the task
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer kan_live_abc123..."
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :next_task_fetched]`
- [ ] Telemetry event: `[:kanban, :api, :task_claimed]` with ai_agent metadata
- [ ] Telemetry event: `[:kanban, :api, :task_unclaimed]` with reason and duration
- [ ] Telemetry event: `[:kanban, :task, :claim_expired]` when task auto-released
- [ ] Telemetry event: `[:kanban, :task, :unclaimed]` when agent unclaims task
- [ ] Metrics: Counter of /next endpoint calls
- [ ] Metrics: Counter of /claim endpoint calls (successful and failed)
- [ ] Metrics: Counter of /unclaim endpoint calls with reason tags
- [ ] Metrics: Counter of expired claims released per job run
- [ ] Metrics: Histogram of task claim duration (claimed_at to completion, expiry, or unclaim)
- [ ] Metrics: Histogram of task priority distribution
- [ ] Metrics: Gauge of tasks in Ready column over time
- [ ] Metrics: Gauge of claimed tasks nearing expiry (< 10 minutes remaining)
- [ ] Metrics: Counter of 409 Conflict responses (contention indicator)
- [ ] Logging: Log task claims at info level (task ID, priority, ai_agent, expires_at)
- [ ] Logging: Log claim conflicts at debug level
- [ ] Logging: Log expired claim releases at info level (task ID, agent, claim duration)
- [ ] Logging: Log manual unclaims at info level (task ID, agent, reason, claim duration)
- [ ] Dashboard: Show tasks claimed vs completed vs expired vs unclaimed over time
- [ ] Dashboard: Show top unclaim reasons for identifying systemic issues

## Error Handling

- User sees: 401 if unauthorized, 403 if missing scope
- GET /next: Returns 404 if no tasks available
- POST /claim: Returns 409 Conflict if no tasks available to claim
- POST /unclaim: Returns 422 if task is not currently claimed
- POST /unclaim: Returns 404 if task not found
- On failure: Clear error messages explain why claim/unclaim failed
- Validation: None for GET, atomic update for POST /claim, status check for POST /unclaim

## Common Pitfalls

- [ ] Don't forget to check ALL dependencies are completed (not just some)
- [ ] Remember route order matters - put /tasks/next and /tasks/claim BEFORE /tasks/:id
- [ ] Don't forget to filter by column name = "Ready"
- [ ] Don't forget to filter out tasks with status != "open" unless claim expired
- [ ] Remember to handle empty dependencies array vs nil
- [ ] Avoid returning tasks that block themselves (circular deps)
- [ ] Don't forget COALESCE for null priorities (they should go last)
- [ ] Remember to return 404 for GET, 409 for POST when no tasks available
- [ ] Don't return an array - return single task object
- [ ] Don't forget WHERE clause to check both status = 'open' AND claim_expires_at for atomicity
- [ ] Remember claim endpoint requires tasks:write scope (not just tasks:read)
- [ ] Don't use Repo.get() then Repo.update() - use update_all for atomicity
- [ ] Don't forget to set claimed_at and claim_expires_at when claiming
- [ ] Remember to add indexes on claim_expires_at for background job performance
- [ ] Don't forget to configure Oban cron job for releasing expired claims
- [ ] Remember to clear claimed_at and claim_expires_at when releasing expired tasks

## Dependencies

**Requires:** 02-add-task-metadata-fields.md, 06-create-api-authentication.md, 07-implement-task-crud-api.md
**Blocks:** None (can be developed in parallel with 09-10)

## Out of Scope

- Don't implement priority scoring algorithm beyond simple 0-4 scale
- Don't add machine learning for task recommendations
- Don't track detailed claim history (which agent attempted to claim when)
- Don't implement partial capability matches (agent must have ALL required capabilities)
- Don't validate which agent claimed a task when unclaiming (no claimed_by_api_token_id field yet)
- Future enhancement: Add claimed_by_api_token_id field to validate unclaim ownership
- Future enhancement: Add agent heartbeat to extend claim expiry (keep-alive mechanism)
- Future enhancement: Track claim attempts and failures for analytics
- Future enhancement: Add queue system for agents waiting for tasks
- Future enhancement: Configurable claim timeout per task or per agent
- Future enhancement: Alert when tasks expire repeatedly (indicates problem)
- Future enhancement: Manual claim extension via API
- Future enhancement: Capability negotiation (suggest alternative agents for tasks)
- Future enhancement: Unclaim history tracking (how many times was this task unclaimed and why)
