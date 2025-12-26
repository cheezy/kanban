# Add Mark Done API Endpoint

**Complexity:** Small | **Est. Files:** 2-3

## Description

**WHY:** After tasks are reviewed in the Review column, they need to be marked as officially completed and moved to the Done column. This final step sets completed_at timestamp, changes status to "completed", and unblocks dependent tasks.

**WHAT:** Implement mark_done function and PATCH /api/tasks/:id/mark_done endpoint that moves task from Review to Done column, sets status to "completed", sets completed_at timestamp, and broadcasts completion event.

**WHERE:** Tasks context, API controller

## Acceptance Criteria

- [ ] Tasks.mark_done/2 function created
- [ ] PATCH /api/tasks/:id/mark_done endpoint added
- [ ] Task moved from Review to Done column
- [ ] Status updated to "completed"
- [ ] completed_at timestamp set automatically
- [ ] completer_name field populated from user
- [ ] PubSub broadcasts task_completed event
- [ ] Dependent tasks unblocked automatically
- [ ] Tests cover happy path and validation
- [ ] Only tasks in Review column can be marked done
- [ ] Position calculated correctly in Done column

## Key Files to Read First

- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add mark_done/2 function
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add mark_done action
- [docs/WIP/UPDATE-TASKS/09-add-task-completion-tracking.md](docs/WIP/UPDATE-TASKS/09-add-task-completion-tracking.md) - Related completion tracking

## Technical Notes

**Patterns to Follow:**
- Use Ecto.Changeset for validation
- Set completed_at using DateTime.utc_now()
- Broadcast via Phoenix.PubSub
- Return updated task with all associations
- Similar pattern to claim_next_task (column movement + field updates)

**Database/Schema:**
- Tables: tasks, columns (to get Done column)
- Migrations needed: No (fields already exist)
- Fields used:
  - column_id (integer) - updated to Done column ID
  - status (string) - updated to "completed"
  - completed_at (utc_datetime) - set to current timestamp
  - completed_by_id (integer) - set to current user ID
  - completer_name (string) - set to current user name
  - position (integer) - updated for Done column

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast task completion to board channel
- [ ] Phoenix Channels: Notify all board subscribers
- [ ] Dependency unlocking: Check all tasks with this task in dependencies array
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban/tasks_test.exs
mix test test/kanban_web/controllers/api/task_controller_test.exs

# Test in console
iex -S mix
alias Kanban.{Repo, Tasks, Columns}

# Get a task in Review column
review_column = Columns.get_column_by_name(14, "Review")
task = Tasks.list_tasks(review_column) |> List.first()

# Mark it as done
user = Kanban.Accounts.get_user!(1)
{:ok, done_task} = Tasks.mark_done(task, user)
IO.inspect(done_task.status, label: "Status")
IO.inspect(done_task.column.name, label: "Column")
IO.inspect(done_task.completed_at, label: "Completed at")

# Test via API
export TOKEN="stride_dev_your_token_here"
curl -X PATCH http://localhost:4000/api/tasks/W16/mark_done \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# Run all checks
mix precommit
```

**Manual Testing:**
1. Create task via API
2. Claim task (moves to Doing)
3. Complete task (moves to Review via /complete endpoint)
4. Mark done via PATCH /mark_done
5. Verify task moved from Review to Done column
6. Verify status changed to "completed"
7. Verify completed_at timestamp set
8. Verify completer_name populated
9. Verify PubSub broadcast received
10. Create task B that depends on task A
11. Mark task A as done
12. Verify task B now appears in /next endpoint

**Success Looks Like:**
- Task moved from Review column to Done column
- Status changed from "in_progress" to "completed"
- completed_at timestamp set to current time
- completed_by_id and completer_name populated
- PubSub broadcast sent
- Dependent tasks unblocked
- Position calculated correctly in Done column
- All tests pass
- API returns updated task with new column_id and status

## Data Examples

**Context Function:**
```elixir
defmodule Kanban.Tasks do
  alias Kanban.{Repo, Columns}
  alias Kanban.Schemas.Task
  alias Kanban.Accounts.User
  import Ecto.Changeset

  def mark_done(%Task{} = task, %User{} = user) do
    board_id = task.column.board_id

    # Get Done column for the board
    done_column = Columns.get_column_by_name(board_id, "Done")
    next_position = get_next_position(done_column)

    changeset =
      task
      |> cast(%{}, [])
      |> put_change(:column_id, done_column.id)
      |> put_change(:position, next_position)
      |> put_change(:status, :completed)
      |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> put_change(:completed_by_id, user.id)
      |> put_change(:completer_name, user.email)
      |> validate_required([:column_id, :status, :completed_at])

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        task = Repo.preload(updated_task, [:column, :goal, :assigned_to])

        # Broadcast completion
        :telemetry.execute(
          [:kanban, :task, :completed],
          %{task_id: task.id},
          %{completed_by_id: user.id}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{board_id}",
          {:task_completed, task}
        )

        {:ok, task}

      error ->
        error
    end
  end
end
```

**API Controller Action:**
```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  def mark_done(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.mark_done(task, user) do
        {:ok, done_task} ->
          emit_telemetry(conn, :task_marked_done, %{task_id: done_task.id})
          render(conn, :show, task: done_task)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end
end
```

**Router Update:**
```elixir
scope "/api", KanbanWeb.API do
  pipe_through [:api, :require_api_auth]

  resources "/tasks", TaskController, only: [:index, :show, :create, :update]
  get "/tasks/next", TaskController, :next
  post "/tasks/claim", TaskController, :claim
  post "/tasks/:id/unclaim", TaskController, :unclaim
  patch "/tasks/:id/complete", TaskController, :complete
  patch "/tasks/:id/mark_done", TaskController, :mark_done  # NEW
end
```

**Example Request:**
```bash
curl -X PATCH http://localhost:4000/api/tasks/W16/mark_done \
  -H "Authorization: Bearer stride_dev_xyz..." \
  -H "Content-Type: application/json"
```

**Example Response:**
```json
{
  "data": {
    "id": 16,
    "identifier": "W16",
    "title": "Add task completion tracking",
    "status": "completed",
    "column_id": 5,
    "position": 1,
    "completed_at": "2025-12-26T10:30:00Z",
    "completed_by_id": 1,
    "completer_name": "user@example.com",
    "completion_summary": { ... },
    "actual_complexity": "medium",
    "actual_files_changed": 3,
    "time_spent_minutes": 25
  }
}
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :task_marked_done]`
- [ ] Telemetry event: `[:kanban, :task, :completed]`
- [ ] Metrics: Counter of completed tasks by user
- [ ] Metrics: Histogram of task completion time (completed_at - inserted_at)
- [ ] Logging: Log task completion at info level with task ID and user

## Error Handling

- User sees: "Task does not belong to this board" if wrong board
- User sees: "Task must be in Review column to mark as done" if not in Review
- On failure: Task status and column remain unchanged
- Validation:
  - Task must be in Review column
  - completed_at, status, column_id required

## Common Pitfalls

- [ ] Don't allow marking done tasks that aren't in Review column
- [ ] Remember to broadcast PubSub event after completion
- [ ] Don't forget to preload associations before returning
- [ ] Remember to set both completed_by_id and completer_name
- [ ] Avoid setting completed_at manually - use DateTime.utc_now()
- [ ] Don't forget to calculate position in Done column
- [ ] Remember to unblock dependent tasks (handled by dependency checking logic)

## Dependencies

**Requires:** 09-add-task-completion-tracking.md (sets up completion_summary)
**Blocks:** None

## Out of Scope

- Don't add approval/rejection workflow
- Don't allow re-marking already completed tasks
- Don't add completion review comments (use existing comment system)
- Don't automatically archive old completed tasks
- Future enhancement: Add "reject" action to send back from Review to Doing
