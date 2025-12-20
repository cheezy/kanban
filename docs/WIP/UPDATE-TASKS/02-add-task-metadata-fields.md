# Add Task Metadata and Completion Tracking Fields

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** Need to track who created tasks (human vs AI), when they were completed, and store completion summaries as defined in TASKS.md format.

**WHAT:** Add metadata fields for task lifecycle: created_by_id (user FK), created_by_agent (AI model name), completed_at, completed_by_id, completed_by_agent, completion_summary (text), status, and dependencies.

**WHERE:** Task schema and migration

## Acceptance Criteria

- [ ] Migration adds metadata columns to tasks table
- [ ] Schema updated with new fields
- [ ] Dependencies stored as array of task IDs
- [ ] Completion summary stored as text field
- [ ] created_by_id references users table
- [ ] created_by_agent stores AI model name (if AI-created)
- [ ] Timestamps for completion
- [ ] Tests cover new fields

## Key Files to Read First

- `lib/kanban/schemas/task.ex` - Task schema
- `lib/kanban/tasks.ex` - Task context
- `priv/repo/migrations/XXXXXX_extend_tasks_schema.exs` - Previous migration
- `docs/WIP/TASKS.md` - Completion summary format (lines 323-385)
- `docs/WIP/AI-WORKFLOW.md` - Completion data structure (lines 73-103)
- [docs/WIP/UPDATE-TASKS/TASK-ID-GENERATION.md](TASK-ID-GENERATION.md) - Prefixed ID system (E, F, W, D)

## Technical Notes

**Patterns to Follow:**
- Use foreign key for created_by_id (references users.id)
- Store AI model name in created_by_agent (e.g., "claude-sonnet-4.5")
- Store completion summary as text field (JSON string or formatted text)
- Array of integers for dependencies (other task IDs)
- Use Ecto timestamps for completed_at

**Database/Schema:**
- Tables: tasks (keep flat structure)
- Migrations needed: Yes - add metadata columns
- Fields to add:
  - `created_by_id` (bigint, references users) - User who created task
  - `created_by_agent` (string) - AI model name if AI-created (e.g., "claude-sonnet-4.5")
  - `completed_at` (utc_datetime) - When task was completed
  - `completed_by_id` (bigint, references users) - User who completed task
  - `completed_by_agent` (string) - AI model name if AI-completed
  - `completion_summary` (text) - JSON string or formatted text with completion details
  - `dependencies` (array of bigint) - Other task IDs this task depends on
  - `status` (string) - "open", "in_progress", "completed", "blocked"
  - `claimed_at` (utc_datetime) - When task was claimed by an agent
  - `claim_expires_at` (utc_datetime) - When claim expires (60 minutes from claimed_at)
  - `required_capabilities` (array of string) - Agent capabilities required to work on this task (e.g., `["code_generation", "database_design"]`). Empty array means any agent can claim it.
  - `actual_complexity` (enum: small, medium, large) - Actual complexity experienced - reported by agent on completion
  - `actual_files_changed` (integer) - Actual number of files modified - reported by agent on completion
  - `time_spent_minutes` (integer) - Actual time spent in minutes - reported by agent on completion
  - `needs_review` (boolean, default: false) - Whether task requires human review before being marked as complete
  - `review_status` (string) - Review status (pending, approved, changes_requested, rejected) - set by human reviewer
  - `review_notes` (text) - Human feedback on the completed work
  - `reviewed_by_id` (bigint, references users) - User who reviewed the task
  - `reviewed_at` (utc_datetime) - When the task was reviewed

**Integration Points:**

- [ ] PubSub broadcasts: Required for all task lifecycle changes
- [ ] Phoenix Channels: LiveViews subscribe to `board:{board_id}` topic
- [ ] Broadcast events: `:task_created`, `:task_updated`, `:task_deleted`, `:task_status_changed`, `:task_claimed`, `:task_completed`, `:task_reviewed`
- [ ] External APIs: None

**PubSub Implementation Details:**

Follow the existing pattern in `lib/kanban/tasks.ex` which already broadcasts task moves:

```elixir
defp broadcast_task_change(%Task{} = task, event) do
  task_with_column = Repo.preload(task, :column)
  column = task_with_column.column

  if column do
    column_with_board = Repo.preload(column, :board)
    board_id = column_with_board.board.id

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, event, task}
    )
  end
end
```

**When to Broadcast:**

1. **Task Creation** - Broadcast `:task_created` after successful insert
2. **Status Change** - Broadcast `:task_status_changed` when status field changes (open → in_progress → completed → blocked)
3. **Task Claim** - Broadcast `:task_claimed` when claimed_at is set
4. **Task Completion** - Broadcast `:task_completed` when completed_at is set
5. **Review Status Change** - Broadcast `:task_reviewed` when review_status changes
6. **General Updates** - Broadcast `:task_updated` for other field changes (title, description, dependencies, etc.)
7. **Task Deletion** - Broadcast `:task_deleted` before deletion

**Enhanced Broadcast Function:**

Add to `lib/kanban/tasks.ex`:

```elixir
defp broadcast_task_change(%Task{} = task, event) do
  require Logger
  task_with_column = Repo.preload(task, [:column, :created_by, :completed_by, :reviewed_by])
  column = task_with_column.column

  if column do
    column_with_board = Repo.preload(column, :board)
    board_id = column_with_board.board.id

    Logger.info("Broadcasting #{event} for task #{task.id} to board:#{board_id}")

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, event, task}
    )

    # Telemetry event for monitoring
    :telemetry.execute(
      [:kanban, :pubsub, :broadcast],
      %{count: 1},
      %{event: event, task_id: task.id, board_id: board_id}
    )
  end
end

# Helper to broadcast with changeset comparison
defp broadcast_task_update(%Task{} = task, %Ecto.Changeset{} = changeset) do
  cond do
    Map.has_key?(changeset.changes, :status) ->
      broadcast_task_change(task, :task_status_changed)
    Map.has_key?(changeset.changes, :claimed_at) ->
      broadcast_task_change(task, :task_claimed)
    Map.has_key?(changeset.changes, :completed_at) ->
      broadcast_task_change(task, :task_completed)
    Map.has_key?(changeset.changes, :review_status) ->
      broadcast_task_change(task, :task_reviewed)
    true ->
      broadcast_task_change(task, :task_updated)
  end
end
```

**LiveView Subscription:**

Ensure LiveView subscribes to board topic in mount function (may already exist):

```elixir
# In lib/kanban_web/live/board_live/show.ex
@impl true
def mount(%{"id" => id}, _session, socket) do
  board = Boards.get_board!(id)

  # Subscribe to PubSub topic for real-time updates
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
  end

  {:ok, assign(socket, board: board, ...)}
end
```

**LiveView Handler:**

Update `lib/kanban_web/live/board_live/show.ex` to handle new events:

```elixir
@impl true
def handle_info({Kanban.Tasks, :task_created, _task}, socket) do
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_updated, _task}, socket) do
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_status_changed, task}, socket) do
  # Can add flash message for status changes if needed
  socket = put_flash(socket, :info, "Task '#{task.title}' status changed to #{task.status}")
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_claimed, task}, socket) do
  socket = put_flash(socket, :info, "Task '#{task.title}' was claimed")
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_completed, task}, socket) do
  socket = put_flash(socket, :success, "Task '#{task.title}' was completed!")
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_reviewed, task}, socket) do
  socket = put_flash(socket, :info, "Task '#{task.title}' review status: #{task.review_status}")
  {:noreply, reload_board_data(socket)}
end

@impl true
def handle_info({Kanban.Tasks, :task_deleted, _task}, socket) do
  {:noreply, reload_board_data(socket)}
end
```

**Context Function Updates:**

Ensure these functions call broadcast:

```elixir
# In lib/kanban/tasks.ex

def create_task(attrs \\ %{}) do
  %Task{}
  |> Task.changeset(attrs)
  |> Repo.insert()
  |> case do
    {:ok, task} ->
      task = Repo.preload(task, [:column, :created_by])
      broadcast_task_change(task, :task_created)

      # Emit telemetry event
      :telemetry.execute(
        [:kanban, :task, :created],
        %{count: 1},
        %{
          task_id: task.id,
          created_by_id: task.created_by_id,
          created_by_agent: task.created_by_agent,
          board_id: get_board_id(task)
        }
      )

      {:ok, task}
    error -> error
  end
end

def update_task(%Task{} = task, attrs) do
  changeset = Task.changeset(task, attrs)

  changeset
  |> Repo.update()
  |> case do
    {:ok, updated_task} ->
      updated_task = Repo.preload(updated_task, [:column, :created_by, :completed_by, :reviewed_by])

      # Emit specific telemetry based on what changed
      cond do
        Map.has_key?(changeset.changes, :status) ->
          :telemetry.execute(
            [:kanban, :task, :status_changed],
            %{count: 1},
            %{
              task_id: updated_task.id,
              old_status: task.status,
              new_status: updated_task.status,
              board_id: get_board_id(updated_task)
            }
          )

        true ->
          :telemetry.execute(
            [:kanban, :task, :updated],
            %{count: 1},
            %{task_id: updated_task.id, board_id: get_board_id(updated_task)}
          )
      end

      broadcast_task_update(updated_task, changeset)
      {:ok, updated_task}
    error -> error
  end
end

def claim_task(%Task{} = task, user_id, agent_name \\ nil) do
  claim_attrs = %{
    claimed_at: DateTime.utc_now(),
    claim_expires_at: DateTime.utc_now() |> DateTime.add(60, :minute),
    status: "in_progress"
  }

  case update_task(task, claim_attrs) do
    {:ok, claimed_task} ->
      # Emit telemetry event for claim
      :telemetry.execute(
        [:kanban, :task, :claimed],
        %{count: 1},
        %{
          task_id: claimed_task.id,
          user_id: user_id,
          agent_name: agent_name,
          board_id: get_board_id(claimed_task)
        }
      )

      {:ok, claimed_task}
    error -> error
  end
end

def complete_task(%Task{} = task, attrs) do
  completion_attrs = Map.merge(attrs, %{
    completed_at: DateTime.utc_now(),
    status: "completed"
  })

  case update_task(task, completion_attrs) do
    {:ok, completed_task} ->
      # Emit telemetry event for completion
      :telemetry.execute(
        [:kanban, :task, :completed],
        %{count: 1, time_spent_minutes: completed_task.time_spent_minutes || 0},
        %{
          task_id: completed_task.id,
          completed_by_id: completed_task.completed_by_id,
          completed_by_agent: completed_task.completed_by_agent,
          complexity: completed_task.actual_complexity,
          files_changed: completed_task.actual_files_changed,
          board_id: get_board_id(completed_task)
        }
      )

      {:ok, completed_task}
    error -> error
  end
end

def review_task(%Task{} = task, review_attrs) do
  review_data = Map.merge(review_attrs, %{
    reviewed_at: DateTime.utc_now()
  })

  case update_task(task, review_data) do
    {:ok, reviewed_task} ->
      # Emit telemetry event for review
      :telemetry.execute(
        [:kanban, :task, :reviewed],
        %{count: 1},
        %{
          task_id: reviewed_task.id,
          reviewed_by_id: reviewed_task.reviewed_by_id,
          review_status: reviewed_task.review_status,
          board_id: get_board_id(reviewed_task)
        }
      )

      {:ok, reviewed_task}
    error -> error
  end
end

def delete_task(%Task{} = task) do
  task = Repo.preload(task, [:column])
  broadcast_task_change(task, :task_deleted)

  :telemetry.execute(
    [:kanban, :task, :deleted],
    %{count: 1},
    %{task_id: task.id, board_id: get_board_id(task)}
  )

  Repo.delete(task)
end

# Helper function to get board_id from task
defp get_board_id(%Task{column: %{board_id: board_id}}), do: board_id
defp get_board_id(_), do: nil
```

## Verification

**Commands to Run:**
```bash
# Create and run migration
mix ecto.gen.migration add_task_metadata
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.{Repo, Schemas.Task, Tasks}

# Create task with metadata (by human user)
{:ok, task} = Tasks.create_task(%{
  title: "Test task",
  created_by_id: 1,  # User ID
  created_by_agent: nil,  # Not AI-created
  status: "in_progress",
  dependencies: []
})

# Create task by AI agent
{:ok, ai_task} = Tasks.create_task(%{
  title: "AI-created task",
  created_by_id: 1,  # User who authorized the AI
  created_by_agent: "claude-sonnet-4.5",
  status: "open"
})

# Complete task (by AI agent)
{:ok, completed} = Tasks.complete_task(task, %{
  completed_by_id: 1,
  completed_by_agent: "claude-sonnet-4.5",
  completion_summary: """
  Files Changed:
  - lib/kanban_web/live/board_live.ex: Added priority filter dropdown
  - lib/kanban_web/live/board_live.html.heex: Added filter UI

  Tests Added:
  - test/kanban_web/live/board_live_test.exs

  Verification Results:
  - Commands: mix test, mix precommit
  - Status: passed
  - Output: All tests passed

  Implementation Notes:
  - Deviations: Added nil handling
  - Discoveries: Existing pattern worked well
  - Edge Cases: Tasks without priority show in All filter

  Telemetry Added: [:kanban, :filter, :used]
  Known Limitations: Sorting not implemented
  """
})

# Run tests
mix test test/kanban/tasks_test.exs
mix precommit
```

**Manual Testing:**

1. **Create task via iex** with created_by_id field
   ```elixir
   {:ok, task} = Tasks.create_task(%{
     title: "Test task",
     column_id: 1,
     created_by_id: 1
   })
   ```
   - Verify `:task_created` broadcast sent
   - Check telemetry event `[:kanban, :task, :created]` emitted

2. **Create AI-created task** with created_by_agent field
   ```elixir
   {:ok, ai_task} = Tasks.create_task(%{
     title: "AI-created task",
     column_id: 1,
     created_by_id: 1,
     created_by_agent: "claude-sonnet-4.5"
   })
   ```
   - Verify task created with agent name

3. **Update task status** to "in_progress"
   ```elixir
   {:ok, updated} = Tasks.update_task(task, %{status: "in_progress"})
   ```
   - Verify `:task_status_changed` broadcast sent
   - Verify telemetry event `[:kanban, :task, :status_changed]` emitted
   - Check logs for broadcast message

4. **Claim a task**
   ```elixir
   {:ok, claimed} = Tasks.claim_task(task, user_id: 1, agent_name: "claude-sonnet-4.5")
   ```
   - Verify `:task_claimed` broadcast sent
   - Verify claimed_at and claim_expires_at set correctly (60 minutes apart)
   - Verify status changed to "in_progress"

5. **Complete task** with completion_summary
   ```elixir
   {:ok, completed} = Tasks.complete_task(task, %{
     completed_by_id: 1,
     completed_by_agent: "claude-sonnet-4.5",
     actual_complexity: :medium,
     actual_files_changed: 3,
     time_spent_minutes: 45,
     completion_summary: "Files Changed:\n- lib/example.ex\n..."
   })
   ```
   - Verify `:task_completed` broadcast sent
   - Verify telemetry event `[:kanban, :task, :completed]` with time_spent measurement
   - Verify completed_at timestamp set
   - Verify status changed to "completed"

6. **Review a task**
   ```elixir
   {:ok, reviewed} = Tasks.review_task(task, %{
     reviewed_by_id: 1,
     review_status: "approved",
     review_notes: "Looks good!"
   })
   ```
   - Verify `:task_reviewed` broadcast sent
   - Verify reviewed_at timestamp set

7. **Test PubSub in LiveView** - Open board in two browser tabs
   - In tab 1: Subscribe to board topic and watch for broadcasts
   - In tab 2: Create/update/complete tasks
   - Verify tab 1 receives real-time updates without refresh
   - Verify flash messages appear for status changes

8. **Test dependencies**
   ```elixir
   {:ok, task_with_deps} = Tasks.create_task(%{
     title: "Dependent task",
     column_id: 1,
     dependencies: [task.id, ai_task.id]
   })
   ```
   - Verify dependencies stored as array

9. **Query tasks by creator type**
   ```elixir
   # Human-created tasks
   from(t in Task, where: is_nil(t.created_by_agent)) |> Repo.all()

   # AI-created tasks
   from(t in Task, where: not is_nil(t.created_by_agent)) |> Repo.all()
   ```

**Success Looks Like:**
- New metadata columns in database
- Can track task creator (user ID + optional AI model)
- Completion summary stored as text
- Dependencies work
- Status transitions tracked
- PubSub broadcasts working for all lifecycle events
- Telemetry events emitted correctly
- LiveView receives real-time updates across multiple tabs
- All tests pass

**PubSub Testing:**

Add tests to `test/kanban/tasks_test.exs` to verify broadcasts:

```elixir
defmodule Kanban.TasksTest do
  use Kanban.DataCase
  import Kanban.TasksFixtures
  alias Kanban.Tasks

  describe "PubSub broadcasts" do
    setup do
      board = board_fixture()
      column = column_fixture(%{board_id: board.id})
      user = user_fixture()

      # Subscribe to board topic
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      {:ok, board: board, column: column, user: user}
    end

    test "broadcasts :task_created on create", %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(%{
        title: "Test task",
        column_id: column.id,
        created_by_id: user.id
      })

      assert_received {Kanban.Tasks, :task_created, received_task}
      assert received_task.id == task.id
    end

    test "broadcasts :task_status_changed on status update", %{column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "open"})

      {:ok, _updated} = Tasks.update_task(task, %{status: "in_progress"})

      assert_received {Kanban.Tasks, :task_status_changed, received_task}
      assert received_task.status == "in_progress"
    end

    test "broadcasts :task_claimed on claim", %{column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "open"})

      {:ok, _claimed} = Tasks.claim_task(task, user.id, "claude-sonnet-4.5")

      assert_received {Kanban.Tasks, :task_claimed, received_task}
      assert received_task.claimed_at != nil
    end

    test "broadcasts :task_completed on complete", %{column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "in_progress"})

      {:ok, _completed} = Tasks.complete_task(task, %{
        completed_by_id: user.id,
        completion_summary: "Done!"
      })

      assert_received {Kanban.Tasks, :task_completed, received_task}
      assert received_task.completed_at != nil
    end

    test "broadcasts :task_reviewed on review", %{column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "completed"})

      {:ok, _reviewed} = Tasks.review_task(task, %{
        reviewed_by_id: user.id,
        review_status: "approved"
      })

      assert_received {Kanban.Tasks, :task_reviewed, received_task}
      assert received_task.review_status == "approved"
    end

    test "broadcasts :task_deleted on delete", %{column: column} do
      task = task_fixture(%{column_id: column.id})

      {:ok, _deleted} = Tasks.delete_task(task)

      assert_received {Kanban.Tasks, :task_deleted, received_task}
      assert received_task.id == task.id
    end

    test "does not broadcast on failed update", %{column: column} do
      task = task_fixture(%{column_id: column.id})

      {:error, _changeset} = Tasks.update_task(task, %{status: "invalid_status"})

      refute_received {Kanban.Tasks, _, _}
    end
  end
end
```

**API Integration Testing:**

Add comprehensive API integration tests to `test/kanban_web/controllers/api/task_controller_test.exs`:

```elixir
defmodule KanbanWeb.Api.TaskControllerTest do
  use KanbanWeb.ConnCase, async: true
  import Kanban.{TasksFixtures, AccountsFixtures, BoardsFixtures}

  alias Kanban.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    board = board_fixture()
    column = column_fixture(%{board_id: board.id})

    # Create API token for authentication
    {:ok, api_token, token} = Accounts.create_api_token(user, %{
      name: "Test Token",
      scopes: ["tasks:read", "tasks:write", "tasks:delete", "tasks:claim"],
      capabilities: ["code_generation", "testing", "documentation"]
    })

    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    conn = put_req_header(conn, "content-type", "application/json")

    {:ok, conn: conn, user: user, board: board, column: column, api_token: api_token}
  end

  describe "POST /api/tasks - create task" do
    test "creates task with human creator", %{conn: conn, column: column, user: user} do
      task_params = %{
        title: "New API task",
        description: "Created via API",
        column_id: column.id,
        created_by_id: user.id,
        status: "open",
        priority: "medium"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{
        "id" => id,
        "title" => "New API task",
        "description" => "Created via API",
        "status" => "open",
        "created_by_id" => created_by_id,
        "created_by_agent" => nil
      } = json_response(conn, 201)["task"]

      assert created_by_id == user.id
      assert is_integer(id)
    end

    test "creates task with AI agent creator", %{conn: conn, column: column, user: user} do
      task_params = %{
        title: "AI-generated task",
        description: "Created by AI agent",
        column_id: column.id,
        created_by_id: user.id,
        created_by_agent: "claude-sonnet-4.5",
        status: "open",
        required_capabilities: ["code_generation", "testing"]
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{
        "id" => _id,
        "title" => "AI-generated task",
        "created_by_agent" => "claude-sonnet-4.5",
        "required_capabilities" => ["code_generation", "testing"],
        "status" => "open"
      } = json_response(conn, 201)["task"]
    end

    test "returns error with invalid data", %{conn: conn} do
      task_params = %{description: "Missing required title field"}

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert %{"title" => ["can't be blank"]} = errors
    end

    test "returns 401 without valid API token", %{column: column, user: user} do
      conn = build_conn()
      |> put_req_header("content-type", "application/json")

      task_params = %{
        title: "Unauthorized task",
        column_id: column.id,
        created_by_id: user.id
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "emits telemetry event on creation", %{conn: conn, column: column, user: user} do
      # Attach telemetry handler
      :telemetry.attach(
        "test-task-created",
        [:kanban, :task, :created],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      task_params = %{
        title: "Telemetry test task",
        column_id: column.id,
        created_by_id: user.id
      }

      post(conn, ~p"/api/tasks", task: task_params)

      assert_received {:telemetry_event, [:kanban, :task, :created], %{count: 1}, metadata}
      assert metadata.task_id != nil
      assert metadata.created_by_id == user.id

      :telemetry.detach("test-task-created")
    end
  end

  describe "GET /api/tasks/:id - show task" do
    test "returns task details", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{
        column_id: column.id,
        created_by_id: user.id,
        status: "in_progress",
        dependencies: []
      })

      conn = get(conn, ~p"/api/tasks/#{task.id}")

      assert %{
        "id" => id,
        "title" => title,
        "status" => "in_progress",
        "created_by_id" => created_by_id
      } = json_response(conn, 200)["task"]

      assert id == task.id
      assert title == task.title
      assert created_by_id == user.id
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/999999")
      assert json_response(conn, 404)["error"] == "Not found"
    end

    test "requires tasks:read scope", %{user: user, column: column} do
      # Create token without tasks:read scope
      {:ok, _api_token, token} = Accounts.create_api_token(user, %{
        name: "Limited Token",
        scopes: ["tasks:write"],
        capabilities: []
      })

      conn = build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

      task = task_fixture(%{column_id: column.id})

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      assert json_response(conn, 403)["error"] == "Insufficient permissions"
    end
  end

  describe "PUT /api/tasks/:id/claim - claim task" do
    test "claims task successfully", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{
        column_id: column.id,
        status: "open",
        claimed_at: nil
      })

      conn = put(conn, ~p"/api/tasks/#{task.id}/claim", %{
        agent_name: "claude-sonnet-4.5"
      })

      assert %{
        "id" => id,
        "status" => "in_progress",
        "claimed_at" => claimed_at,
        "claim_expires_at" => claim_expires_at
      } = json_response(conn, 200)["task"]

      assert id == task.id
      assert claimed_at != nil
      assert claim_expires_at != nil

      # Verify claim expires in ~60 minutes
      claimed = DateTime.from_iso8601(claimed_at) |> elem(1)
      expires = DateTime.from_iso8601(claim_expires_at) |> elem(1)
      diff_minutes = DateTime.diff(expires, claimed, :minute)

      assert diff_minutes in 59..61
    end

    test "returns error if task already claimed", %{conn: conn, column: column} do
      task = task_fixture(%{
        column_id: column.id,
        status: "in_progress",
        claimed_at: DateTime.utc_now(),
        claim_expires_at: DateTime.utc_now() |> DateTime.add(60, :minute)
      })

      conn = put(conn, ~p"/api/tasks/#{task.id}/claim", %{
        agent_name: "claude-sonnet-4.5"
      })

      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "already claimed"
    end

    test "requires tasks:claim scope", %{user: user, column: column} do
      {:ok, _api_token, token} = Accounts.create_api_token(user, %{
        name: "No Claim Token",
        scopes: ["tasks:read", "tasks:write"],
        capabilities: []
      })

      conn = build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

      task = task_fixture(%{column_id: column.id, status: "open"})

      conn = put(conn, ~p"/api/tasks/#{task.id}/claim")
      assert json_response(conn, 403)["error"] == "Insufficient permissions"
    end

    test "emits telemetry event on claim", %{conn: conn, column: column} do
      :telemetry.attach(
        "test-task-claimed",
        [:kanban, :task, :claimed],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      task = task_fixture(%{column_id: column.id, status: "open"})

      put(conn, ~p"/api/tasks/#{task.id}/claim", %{agent_name: "claude-sonnet-4.5"})

      assert_received {:telemetry_event, [:kanban, :task, :claimed], %{count: 1}, metadata}
      assert metadata.task_id == task.id
      assert metadata.agent_name == "claude-sonnet-4.5"

      :telemetry.detach("test-task-claimed")
    end
  end

  describe "PUT /api/tasks/:id/complete - complete task" do
    test "completes task with all metadata", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{
        column_id: column.id,
        status: "in_progress",
        claimed_at: DateTime.utc_now()
      })

      completion_data = %{
        completed_by_id: user.id,
        completed_by_agent: "claude-sonnet-4.5",
        actual_complexity: :medium,
        actual_files_changed: 5,
        time_spent_minutes: 45,
        completion_summary: """
        Files Changed:
        - lib/example.ex: Added new feature
        - test/example_test.exs: Added tests

        Verification: All tests passed
        """
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/complete", completion_data)

      assert %{
        "id" => id,
        "status" => "completed",
        "completed_at" => completed_at,
        "completed_by_agent" => "claude-sonnet-4.5",
        "actual_complexity" => "medium",
        "actual_files_changed" => 5,
        "time_spent_minutes" => 45,
        "completion_summary" => completion_summary
      } = json_response(conn, 200)["task"]

      assert id == task.id
      assert completed_at != nil
      assert completion_summary =~ "Files Changed"
    end

    test "requires task to be in progress", %{conn: conn, column: column} do
      task = task_fixture(%{column_id: column.id, status: "open"})

      conn = put(conn, ~p"/api/tasks/#{task.id}/complete", %{
        completion_summary: "Done"
      })

      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "must be in progress"
    end

    test "emits telemetry with time_spent measurement", %{conn: conn, column: column, user: user} do
      :telemetry.attach(
        "test-task-completed",
        [:kanban, :task, :completed],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      task = task_fixture(%{
        column_id: column.id,
        status: "in_progress"
      })

      put(conn, ~p"/api/tasks/#{task.id}/complete", %{
        completed_by_id: user.id,
        time_spent_minutes: 30,
        completion_summary: "Done"
      })

      assert_received {:telemetry_event, [:kanban, :task, :completed], measurements, metadata}
      assert measurements.count == 1
      assert measurements.time_spent_minutes == 30
      assert metadata.complexity != nil

      :telemetry.detach("test-task-completed")
    end
  end

  describe "PUT /api/tasks/:id/review - review task" do
    test "approves completed task", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{
        column_id: column.id,
        status: "completed",
        completed_at: DateTime.utc_now(),
        needs_review: true
      })

      review_data = %{
        reviewed_by_id: user.id,
        review_status: "approved",
        review_notes: "Great work! All tests pass."
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/review", review_data)

      assert %{
        "id" => id,
        "review_status" => "approved",
        "review_notes" => "Great work! All tests pass.",
        "reviewed_at" => reviewed_at
      } = json_response(conn, 200)["task"]

      assert id == task.id
      assert reviewed_at != nil
    end

    test "requests changes on task", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{
        column_id: column.id,
        status: "completed",
        completed_at: DateTime.utc_now()
      })

      review_data = %{
        reviewed_by_id: user.id,
        review_status: "changes_requested",
        review_notes: "Please add more test coverage"
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/review", review_data)

      assert %{
        "review_status" => "changes_requested",
        "review_notes" => "Please add more test coverage"
      } = json_response(conn, 200)["task"]
    end

    test "validates review_status enum", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "completed"})

      conn = put(conn, ~p"/api/tasks/#{task.id}/review", %{
        reviewed_by_id: user.id,
        review_status: "invalid_status"
      })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["review_status"] != nil
    end
  end

  describe "GET /api/tasks - list tasks with filters" do
    test "filters tasks by status", %{conn: conn, column: column} do
      _open_task = task_fixture(%{column_id: column.id, status: "open"})
      _in_progress = task_fixture(%{column_id: column.id, status: "in_progress"})
      _completed = task_fixture(%{column_id: column.id, status: "completed"})

      conn = get(conn, ~p"/api/tasks?status=in_progress")

      tasks = json_response(conn, 200)["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["status"] == "in_progress"
    end

    test "filters tasks by creator type (human)", %{conn: conn, column: column, user: user} do
      _human_task = task_fixture(%{
        column_id: column.id,
        created_by_id: user.id,
        created_by_agent: nil
      })

      _ai_task = task_fixture(%{
        column_id: column.id,
        created_by_id: user.id,
        created_by_agent: "claude-sonnet-4.5"
      })

      conn = get(conn, ~p"/api/tasks?creator_type=human")

      tasks = json_response(conn, 200)["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["created_by_agent"] == nil
    end

    test "filters tasks by creator type (ai)", %{conn: conn, column: column, user: user} do
      _human_task = task_fixture(%{
        column_id: column.id,
        created_by_id: user.id,
        created_by_agent: nil
      })

      _ai_task = task_fixture(%{
        column_id: column.id,
        created_by_id: user.id,
        created_by_agent: "claude-sonnet-4.5"
      })

      conn = get(conn, ~p"/api/tasks?creator_type=ai")

      tasks = json_response(conn, 200)["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["created_by_agent"] == "claude-sonnet-4.5"
    end

    test "filters tasks by review status", %{conn: conn, column: column} do
      _pending_review = task_fixture(%{
        column_id: column.id,
        needs_review: true,
        review_status: "pending"
      })

      _approved = task_fixture(%{
        column_id: column.id,
        review_status: "approved"
      })

      conn = get(conn, ~p"/api/tasks?review_status=pending")

      tasks = json_response(conn, 200)["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["review_status"] == "pending"
    end

    test "paginates results", %{conn: conn, column: column} do
      # Create 15 tasks
      for i <- 1..15 do
        task_fixture(%{column_id: column.id, title: "Task #{i}"})
      end

      # Get first page (default 10 per page)
      conn = get(conn, ~p"/api/tasks?page=1&per_page=10")
      response = json_response(conn, 200)

      assert length(response["tasks"]) == 10
      assert response["pagination"]["total"] == 15
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["per_page"] == 10
      assert response["pagination"]["total_pages"] == 2

      # Get second page
      conn = get(conn, ~p"/api/tasks?page=2&per_page=10")
      response = json_response(conn, 200)

      assert length(response["tasks"]) == 5
    end
  end

  describe "GET /api/tasks/next_available - get next claimable task" do
    test "returns task matching agent capabilities", %{conn: conn, column: column} do
      _no_requirements = task_fixture(%{
        column_id: column.id,
        status: "open",
        required_capabilities: []
      })

      matching_task = task_fixture(%{
        column_id: column.id,
        status: "open",
        title: "Matching task",
        required_capabilities: ["code_generation"]
      })

      _unmatched = task_fixture(%{
        column_id: column.id,
        status: "open",
        required_capabilities: ["database_design", "deployment"]
      })

      conn = get(conn, ~p"/api/tasks/next_available?capabilities[]=code_generation&capabilities[]=testing")

      assert %{
        "id" => id,
        "title" => "Matching task"
      } = json_response(conn, 200)["task"]

      assert id == matching_task.id
    end

    test "returns 404 when no tasks available", %{conn: conn, column: column} do
      _all_claimed = task_fixture(%{
        column_id: column.id,
        status: "in_progress",
        claimed_at: DateTime.utc_now()
      })

      conn = get(conn, ~p"/api/tasks/next_available?capabilities[]=code_generation")

      assert json_response(conn, 404)["error"] == "No tasks available"
    end
  end

  describe "DELETE /api/tasks/:id - delete task" do
    test "deletes task successfully", %{conn: conn, column: column} do
      task = task_fixture(%{column_id: column.id})

      conn = delete(conn, ~p"/api/tasks/#{task.id}")

      assert response(conn, 204) == ""
    end

    test "requires tasks:delete scope", %{user: user, column: column} do
      {:ok, _api_token, token} = Accounts.create_api_token(user, %{
        name: "Read-only Token",
        scopes: ["tasks:read"],
        capabilities: []
      })

      conn = build_conn()
      |> put_req_header("authorization", "Bearer #{token}")

      task = task_fixture(%{column_id: column.id})

      conn = delete(conn, ~p"/api/tasks/#{task.id}")
      assert json_response(conn, 403)["error"] == "Insufficient permissions"
    end

    test "emits telemetry event on delete", %{conn: conn, column: column} do
      :telemetry.attach(
        "test-task-deleted",
        [:kanban, :task, :deleted],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      task = task_fixture(%{column_id: column.id})

      delete(conn, ~p"/api/tasks/#{task.id}")

      assert_received {:telemetry_event, [:kanban, :task, :deleted], %{count: 1}, metadata}
      assert metadata.task_id == task.id

      :telemetry.detach("test-task-deleted")
    end
  end

  describe "PubSub integration with API" do
    setup %{column: column} do
      board = Repo.preload(column, :board).board
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      {:ok, board: board}
    end

    test "broadcasts on API task creation", %{conn: conn, column: column, user: user} do
      task_params = %{
        title: "Broadcast test",
        column_id: column.id,
        created_by_id: user.id
      }

      post(conn, ~p"/api/tasks", task: task_params)

      assert_received {Kanban.Tasks, :task_created, task}
      assert task.title == "Broadcast test"
    end

    test "broadcasts on API task completion", %{conn: conn, column: column, user: user} do
      task = task_fixture(%{column_id: column.id, status: "in_progress"})

      put(conn, ~p"/api/tasks/#{task.id}/complete", %{
        completed_by_id: user.id,
        completion_summary: "Done via API"
      })

      assert_received {Kanban.Tasks, :task_completed, completed_task}
      assert completed_task.id == task.id
    end
  end
end
```

## Data Examples

**Schema Migration:**
```elixir
defmodule Kanban.Repo.Migrations.AddTaskMetadata do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Creator tracking
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :created_by_agent, :string  # AI model name if AI-created

      # Completion tracking
      add :completed_at, :utc_datetime
      add :completed_by_id, references(:users, on_delete: :nilify_all)
      add :completed_by_agent, :string  # AI model name if AI-completed
      add :completion_summary, :text  # Formatted text or JSON string

      # Task relationships and status
      add :dependencies, {:array, :bigint}, default: []
      add :status, :string, default: "open"

      # Claim tracking (for task 08 - auto-release after 60 minutes)
      add :claimed_at, :utc_datetime
      add :claim_expires_at, :utc_datetime

      # Agent capability matching (for task 08 - filter by agent capabilities)
      add :required_capabilities, {:array, :string}, default: []

      # Estimation feedback loop (for task 09 - track actual vs estimated)
      add :actual_complexity, :string  # Enum: small, medium, large
      add :actual_files_changed, :integer
      add :time_spent_minutes, :integer

      # Human review queue (for human feedback on completed work)
      add :needs_review, :boolean, default: false  # Whether task requires human review
      add :review_status, :string  # pending, approved, changes_requested, rejected
      add :review_notes, :text
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
    end

    create index(:tasks, [:created_by_id])
    create index(:tasks, [:completed_by_id])
    create index(:tasks, [:status])
    create index(:tasks, [:created_by_agent])
    create index(:tasks, [:claim_expires_at])
    create index(:tasks, [:status, :claim_expires_at])
    create index(:tasks, [:actual_complexity])
    create index(:tasks, [:needs_review])
    create index(:tasks, [:review_status])
    create index(:tasks, [:reviewed_by_id])
  end
end
```

**Data Migration for Existing Tasks:**

Create a separate data migration to backfill existing tasks with sensible defaults:

```elixir
defmodule Kanban.Repo.Migrations.BackfillTaskMetadata do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Get the first admin user or first user as fallback for system-created tasks
    system_user_id = get_system_user_id()

    # Update all existing tasks with default metadata
    execute """
    UPDATE tasks
    SET
      status = CASE
        WHEN position IS NOT NULL THEN 'open'
        ELSE 'open'
      END,
      created_by_id = #{system_user_id},
      dependencies = '{}',
      required_capabilities = '{}',
      needs_review = false
    WHERE status IS NULL
    """

    # Mark tasks in specific columns as "in_progress" or "completed" based on column name
    # This assumes you have a convention where column names indicate status
    # Adjust the logic based on your actual column naming
    execute """
    UPDATE tasks t
    SET status = 'completed'
    FROM columns c
    WHERE t.column_id = c.id
      AND c.name ILIKE '%done%'
      AND t.status = 'open'
    """

    execute """
    UPDATE tasks t
    SET status = 'in_progress'
    FROM columns c
    WHERE t.column_id = c.id
      AND (c.name ILIKE '%progress%' OR c.name ILIKE '%doing%')
      AND t.status = 'open'
    """

    # Log the migration results
    task_count = repo().one(from t in "tasks", select: count(t.id))
    IO.puts("✓ Backfilled metadata for #{task_count} existing tasks")
  end

  def down do
    # This is a data migration - we don't reverse it
    # The schema migration handles adding/removing columns
    :ok
  end

  defp get_system_user_id do
    # Try to get first admin user, fallback to first user
    repo().one(
      from u in "users",
      where: u.type == "admin",
      order_by: [asc: u.id],
      limit: 1,
      select: u.id
    ) ||
    repo().one(
      from u in "users",
      order_by: [asc: u.id],
      limit: 1,
      select: u.id
    ) ||
    raise "No users found in database - please create a user first"
  end
end
```

**Alternative: Inline Data Migration**

If you prefer to combine schema and data migration in one file:

```elixir
defmodule Kanban.Repo.Migrations.AddTaskMetadata do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Add new columns
    alter table(:tasks) do
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :created_by_agent, :string
      add :completed_at, :utc_datetime
      add :completed_by_id, references(:users, on_delete: :nilify_all)
      add :completed_by_agent, :string
      add :completion_summary, :text
      add :dependencies, {:array, :bigint}, default: []
      add :status, :string, default: "open"
      add :claimed_at, :utc_datetime
      add :claim_expires_at, :utc_datetime
      add :required_capabilities, {:array, :string}, default: []
      add :actual_complexity, :string
      add :actual_files_changed, :integer
      add :time_spent_minutes, :integer
      add :needs_review, :boolean, default: false
      add :review_status, :string
      add :review_notes, :text
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
    end

    # Add indexes
    create index(:tasks, [:created_by_id])
    create index(:tasks, [:completed_by_id])
    create index(:tasks, [:status])
    create index(:tasks, [:created_by_agent])
    create index(:tasks, [:claim_expires_at])
    create index(:tasks, [:status, :claim_expires_at])
    create index(:tasks, [:actual_complexity])
    create index(:tasks, [:needs_review])
    create index(:tasks, [:review_status])
    create index(:tasks, [:reviewed_by_id])

    # Backfill existing tasks
    flush()  # Ensure schema changes are applied before data migration

    system_user_id = get_system_user_id()

    execute """
    UPDATE tasks
    SET
      status = 'open',
      created_by_id = #{system_user_id},
      dependencies = '{}',
      required_capabilities = '{}',
      needs_review = false
    WHERE status IS NULL
    """

    # Infer status from column names
    execute """
    UPDATE tasks t
    SET status = 'completed'
    FROM columns c
    WHERE t.column_id = c.id
      AND (c.name ILIKE '%done%' OR c.name ILIKE '%complete%')
      AND t.status = 'open'
    """

    execute """
    UPDATE tasks t
    SET status = 'in_progress'
    FROM columns c
    WHERE t.column_id = c.id
      AND (c.name ILIKE '%progress%' OR c.name ILIKE '%doing%' OR c.name ILIKE '%wip%')
      AND t.status = 'open'
    """
  end

  def down do
    drop index(:tasks, [:reviewed_by_id])
    drop index(:tasks, [:review_status])
    drop index(:tasks, [:needs_review])
    drop index(:tasks, [:actual_complexity])
    drop index(:tasks, [:status, :claim_expires_at])
    drop index(:tasks, [:claim_expires_at])
    drop index(:tasks, [:created_by_agent])
    drop index(:tasks, [:status])
    drop index(:tasks, [:completed_by_id])
    drop index(:tasks, [:created_by_id])

    alter table(:tasks) do
      remove :reviewed_at
      remove :reviewed_by_id
      remove :review_notes
      remove :review_status
      remove :needs_review
      remove :time_spent_minutes
      remove :actual_files_changed
      remove :actual_complexity
      remove :required_capabilities
      remove :claim_expires_at
      remove :claimed_at
      remove :status
      remove :dependencies
      remove :completion_summary
      remove :completed_by_agent
      remove :completed_by_id
      remove :completed_at
      remove :created_by_agent
      remove :created_by_id
    end
  end

  defp get_system_user_id do
    repo().one(
      from u in "users",
      where: u.type == ^:admin,
      order_by: [asc: u.id],
      limit: 1,
      select: u.id
    ) ||
    repo().one(
      from u in "users",
      order_by: [asc: u.id],
      limit: 1,
      select: u.id
    ) ||
    raise "No users found - create a user before running this migration"
  end
end
```

**Migration Verification Commands:**

```bash
# Before running migration - check existing tasks
psql -d kanban_dev -c "SELECT COUNT(*) FROM tasks;"
psql -d kanban_dev -c "SELECT id, title, position FROM tasks LIMIT 5;"

# Run migration
mix ecto.migrate

# After migration - verify backfill
psql -d kanban_dev -c "SELECT COUNT(*) FROM tasks WHERE status IS NOT NULL;"
psql -d kanban_dev -c "SELECT COUNT(*) FROM tasks WHERE created_by_id IS NOT NULL;"
psql -d kanban_dev -c "SELECT status, COUNT(*) FROM tasks GROUP BY status;"

# Check specific tasks
psql -d kanban_dev -c "
  SELECT
    t.id,
    t.title,
    t.status,
    t.created_by_id,
    u.email as created_by_email,
    c.name as column_name
  FROM tasks t
  LEFT JOIN users u ON t.created_by_id = u.id
  LEFT JOIN columns c ON t.column_id = c.id
  LIMIT 10;
"
```

**Testing the Migration:**

```elixir
# In test/kanban/migrations/backfill_task_metadata_test.exs
defmodule Kanban.Migrations.BackfillTaskMetadataTest do
  use Kanban.DataCase
  import Ecto.Query

  describe "backfill task metadata migration" do
    test "sets default status for existing tasks" do
      # Create test data before migration
      user = user_fixture()
      board = board_fixture()
      column = column_fixture(%{board_id: board.id, name: "To Do"})

      # Insert task directly to bypass new validations
      {:ok, _task} = Repo.insert(%Task{
        title: "Old task",
        column_id: column.id,
        position: 0
      }, skip_validation: true)

      # Run backfill logic
      # (You would call the actual migration function here)

      # Verify results
      task = Repo.one!(from t in Task, where: t.title == "Old task")

      assert task.status == "open"
      assert task.created_by_id != nil
      assert task.dependencies == []
      assert task.required_capabilities == []
      assert task.needs_review == false
    end

    test "infers status from column name" do
      user = user_fixture()
      board = board_fixture()
      done_column = column_fixture(%{board_id: board.id, name: "Done"})

      {:ok, _task} = Repo.insert(%Task{
        title: "Completed task",
        column_id: done_column.id,
        position: 0
      }, skip_validation: true)

      # Run backfill logic

      task = Repo.one!(from t in Task, where: t.title == "Completed task")
      assert task.status == "completed"
    end
  end
end
```

**Schema Update:**
```elixir
defmodule Kanban.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    # ... existing fields ...

    # Creator tracking
    belongs_to :created_by, Kanban.Schemas.User
    field :created_by_agent, :string

    # Completion tracking
    field :completed_at, :utc_datetime
    belongs_to :completed_by, Kanban.Schemas.User
    field :completed_by_agent, :string
    field :completion_summary, :string

    # Task relationships and status
    field :dependencies, {:array, :integer}, default: []
    field :status, :string, default: "open"

    # Claim tracking
    field :claimed_at, :utc_datetime
    field :claim_expires_at, :utc_datetime

    # Agent capability matching
    field :required_capabilities, {:array, :string}, default: []

    # Estimation feedback loop
    field :actual_complexity, Ecto.Enum, values: [:small, :medium, :large]
    field :actual_files_changed, :integer
    field :time_spent_minutes, :integer

    # Human review queue
    field :needs_review, :boolean, default: false
    field :review_status, :string
    field :review_notes, :string
    belongs_to :reviewed_by, Kanban.Schemas.User
    field :reviewed_at, :utc_datetime

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title, :description, :created_by_id, :created_by_agent,
      :completed_at, :completed_by_id, :completed_by_agent,
      :completion_summary, :dependencies, :status,
      :claimed_at, :claim_expires_at, :required_capabilities,
      :actual_complexity, :actual_files_changed, :time_spent_minutes,
      :needs_review, :review_status, :review_notes, :reviewed_by_id, :reviewed_at
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, [:open, :in_progress, :completed, :blocked])
    |> validate_inclusion(:actual_complexity, [:small, :medium, :large])
    |> validate_inclusion(:review_status, [:pending, :approved, :changes_requested, :rejected])
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:completed_by_id)
    |> foreign_key_constraint(:reviewed_by_id)
  end
end
```

**Completion Summary Text Format:**
```
Files Changed:
- lib/kanban_web/live/board_live.ex: Added priority filter dropdown
- lib/kanban_web/live/board_live.html.heex: Added filter UI

Tests Added:
- test/kanban_web/live/board_live_test.exs

Verification Results:
- Commands: mix test, mix precommit
- Status: passed
- Output: All 512 tests passed

Implementation Notes:
- Deviations: Added nil handling for tasks without priority
- Discoveries: Existing filter pattern worked perfectly
- Edge Cases: Tasks with nil priority show in 'All' filter

Telemetry Added: [:kanban, :filter, :used]
Follow-up Tasks: None
Known Limitations: Sorting by priority not implemented yet
```

**Helper Functions:**
```elixir
defmodule Kanban.Tasks do
  # Check if task was created by AI
  def ai_created?(%Task{created_by_agent: agent}) when is_binary(agent), do: true
  def ai_created?(_), do: false

  # Get creator display name
  def creator_name(%Task{created_by_agent: agent, created_by: user}) when is_binary(agent) do
    "AI: #{agent} (authorized by #{user.email})"
  end
  def creator_name(%Task{created_by: user}) do
    user.email
  end

  # Parse completion summary for API
  def parse_completion_summary(nil), do: nil
  def parse_completion_summary(text) when is_binary(text) do
    # Can parse structured text or decode JSON string
    # For now, return as-is for display
    text
  end
end
```

## Observability

**Telemetry Events:**

- [ ] `[:kanban, :task, :created]` - Emitted when task is created
  - Measurements: `%{count: 1}`
  - Metadata: `%{task_id: id, created_by_id: user_id, created_by_agent: agent_name, board_id: board_id}`

- [ ] `[:kanban, :task, :status_changed]` - Emitted when task status changes
  - Measurements: `%{count: 1}`
  - Metadata: `%{task_id: id, old_status: old, new_status: new, board_id: board_id}`

- [ ] `[:kanban, :task, :claimed]` - Emitted when task is claimed
  - Measurements: `%{count: 1}`
  - Metadata: `%{task_id: id, user_id: user_id, agent_name: agent, board_id: board_id}`

- [ ] `[:kanban, :task, :completed]` - Emitted when task is completed
  - Measurements: `%{count: 1, time_spent_minutes: minutes}`
  - Metadata: `%{task_id: id, completed_by_id: user_id, completed_by_agent: agent, complexity: actual_complexity, files_changed: actual_files_changed, board_id: board_id}`

- [ ] `[:kanban, :task, :reviewed]` - Emitted when task is reviewed
  - Measurements: `%{count: 1}`
  - Metadata: `%{task_id: id, reviewed_by_id: user_id, review_status: status, board_id: board_id}`

- [ ] `[:kanban, :pubsub, :broadcast]` - Emitted when PubSub broadcast occurs
  - Measurements: `%{count: 1}`
  - Metadata: `%{event: event_atom, task_id: id, board_id: board_id}`

**Metrics to Track:**

- Counter: Tasks created (segmented by human vs AI creator)
- Counter: Tasks completed (segmented by human vs AI completer)
- Summary: Time spent on tasks (actual_time_spent_minutes)
- Counter: Tasks by status (open, in_progress, completed, blocked)
- Counter: Tasks by review status (pending, approved, changes_requested, rejected)
- Counter: PubSub broadcasts by event type

**Logging:**

- **Info level**: Task lifecycle events (created, claimed, completed, reviewed)
  - Format: `"Task #{task.id} '#{task.title}' completed by #{completer_name} in #{time_spent} minutes"`
- **Info level**: PubSub broadcasts (already in broadcast_task_change)
  - Format: `"Broadcasting #{event} for task #{task.id} to board:#{board_id}"`
- **Warn level**: Expired claims not released
  - Format: `"Task #{task.id} claim expired but not released (claimed_at: #{claimed_at})"`
- **Error level**: Validation failures, constraint violations

## Error Handling

- User sees: Validation errors if completion_summary malformed
- On failure: Task status remains unchanged
- Validation: Validate status transitions (can't go from completed to open)

## Common Pitfalls

**Database & Validation:**
- [ ] Don't forget to validate status transitions (can't go from completed back to open)
- [ ] Don't forget created_by_id must reference existing user
- [ ] Remember dependencies must reference valid task IDs
- [ ] Avoid circular dependencies in task relationships
- [ ] Remember completed_at should be set automatically on completion
- [ ] Remember to handle nil completion_summary gracefully

**PubSub Broadcasts:**
- [ ] **CRITICAL**: Always broadcast AFTER successful database update, not before
- [ ] Remember to preload associations (column, board) before broadcasting
- [ ] Don't forget to broadcast on ALL lifecycle events (create, update, delete, status change, claim, complete, review)
- [ ] Remember broadcast_task_change already handles nil column gracefully
- [ ] Don't broadcast on failed updates - wrap in case statement
- [ ] Remember to emit telemetry events alongside broadcasts for observability

**AI-Specific Fields:**
- [ ] Don't forget to set created_by_agent for AI-created tasks
- [ ] Remember actual_complexity, actual_files_changed, time_spent_minutes should only be set on completion
- [ ] Don't forget claim_expires_at is 60 minutes after claimed_at
- [ ] Remember to validate required_capabilities is array of strings

**LiveView Integration:**
- [ ] Don't forget to add handle_info for ALL broadcast events in show.ex
- [ ] Remember LiveView must subscribe to board topic in mount/3
- [ ] Don't forget to reload board data after receiving broadcasts
- [ ] Remember flash messages are optional but improve UX for status changes

## Dependencies

**Requires:** 01A-extend-task-schema-scalar-fields.md, 01B-extend-task-schema-jsonb-collections.md
**Blocks:** 04-implement-task-crud-api.md, 06-add-task-completion-tracking.md

## Out of Scope

- Don't implement dependency resolution logic yet
- Don't add UI for dependencies
- Don't implement automatic task unblocking
- Don't add API endpoints yet
