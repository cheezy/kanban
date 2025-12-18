# Real-Time UI Updates via PubSub

**Date:** 2025-12-18
**Feature:** Real-Time Task Updates
**Related Tasks:** All API tasks (02, 04, 06, 08, 09, etc.)

## Overview

When AI agents make changes to tasks via the API (claiming, completing, moving columns, updating fields), the UI must update in real-time for all connected users. This is accomplished using Phoenix PubSub to broadcast changes and Phoenix LiveView (or Phoenix Channels) to receive and apply updates on the client.

## Design Principles

1. **Broadcast All Changes**: Every task modification via API triggers a PubSub broadcast
2. **Granular Events**: Different event types for different changes (claimed, completed, moved, etc.)
3. **Efficient Payloads**: Only send changed fields, not entire task object
4. **Board-Scoped**: Users subscribe to boards they're viewing
5. **Task-Scoped**: Can also subscribe to specific tasks for detail views

## PubSub Topics

### Board-Level Topic

**Topic:** `tasks:board:{board_id}`

**Purpose:** Broadcast all task changes for a specific board

**Subscribers:** All users viewing the board (LiveView or Channel)

**Events:**
- `task_created` - New task added to board
- `task_updated` - Task fields changed
- `task_claimed` - Agent claimed a task
- `task_unclaimed` - Agent released a task
- `task_completed` - Task marked complete
- `task_status_changed` - Status field changed (open, in_progress, completed, blocked)
- `task_moved` - Task moved to different column
- `task_reviewed` - Human review status set
- `task_deleted` - Task removed from board

### Task-Level Topic

**Topic:** `tasks:task:{task_id}`

**Purpose:** Broadcast changes to a specific task

**Subscribers:** Users viewing task detail modal/page

**Events:** Same as board-level, but scoped to single task

### Column-Level Topic (Optional)

**Topic:** `tasks:column:{column_id}`

**Purpose:** Broadcast task changes within a specific column

**Subscribers:** Users viewing kanban board with column filters

**Use Case:** Optimize updates when viewing filtered/column-specific views

## Broadcast Events

### Event: task_created

**When:** Task created via API (POST /api/tasks)

**Payload:**
```elixir
%{
  event: "task_created",
  task: %{
    id: 42,
    title: "Add user authentication",
    description: "Implement JWT authentication",
    status: "open",
    column_id: 5,
    priority: 0,
    complexity: "medium",
    needs_review: true,
    created_by_id: 1,
    created_by_agent: "claude-sonnet-4.5",
    inserted_at: ~U[2025-12-18 15:00:00Z]
  }
}
```

**UI Action:**
- Add new task card to appropriate column
- Update task count in column header
- Trigger animation for new task

### Event: task_claimed

**When:** Agent claims task via POST /api/tasks/claim

**Payload:**
```elixir
%{
  event: "task_claimed",
  task_id: 42,
  changes: %{
    status: {"open", "in_progress"},
    claimed_at: {nil, ~U[2025-12-18 15:05:00Z]},
    claim_expires_at: {nil, ~U[2025-12-18 16:05:00Z]}
  },
  metadata: %{
    claimed_by: "claude-sonnet-4.5",
    api_token_id: 123
  }
}
```

**UI Action:**
- Update task card status badge
- Show "claimed by" indicator
- Show claim expiry countdown timer
- Move task to "In Progress" section if column has status sections

### Event: task_unclaimed

**When:** Agent unclaims task via POST /api/tasks/:id/unclaim

**Payload:**
```elixir
%{
  event: "task_unclaimed",
  task_id: 42,
  changes: %{
    status: {"in_progress", "open"},
    claimed_at: {~U[2025-12-18 15:05:00Z], nil},
    claim_expires_at: {~U[2025-12-18 16:05:00Z], nil}
  },
  metadata: %{
    unclaimed_by: "claude-sonnet-4.5",
    reason: "Missing OAuth2 library dependencies",
    was_claimed_for_minutes: 5
  }
}
```

**UI Action:**
- Update task card status badge
- Remove "claimed by" indicator
- Remove claim expiry timer
- Move task back to "Open" section
- Optionally show unclaim reason as tooltip

### Event: task_moved

**When:** Task moved to different column via API

**Payload:**
```elixir
%{
  event: "task_moved",
  task_id: 42,
  changes: %{
    column_id: {5, 6}
  },
  metadata: %{
    from_column: "In Progress",
    to_column: "Review",
    moved_by: "claude-sonnet-4.5"
  }
}
```

**UI Action:**
- Remove task card from source column
- Add task card to destination column
- Trigger slide/fade animation
- Update column task counts

### Event: task_completed

**When:** Task marked complete via PATCH /api/tasks/:id/complete

**Payload:**
```elixir
%{
  event: "task_completed",
  task_id: 42,
  changes: %{
    status: {"in_progress", "completed"},
    completed_at: {nil, ~U[2025-12-18 16:00:00Z]},
    completed_by_agent: {nil, "claude-sonnet-4.5"},
    actual_complexity: {nil, "large"},
    actual_files_changed: {nil, 8},
    time_spent_minutes: {nil, 55}
  },
  metadata: %{
    completed_by: "claude-sonnet-4.5",
    needs_review: true
  }
}
```

**UI Action:**
- Update task card status badge to "completed"
- Move to "Review" column if needs_review = true
- Move to "Done" column if needs_review = false
- Show completion checkmark animation
- Update completion metrics display

### Event: task_reviewed

**When:** Human reviews task via PATCH /api/tasks/:id/review

**Payload:**
```elixir
%{
  event: "task_reviewed",
  task_id: 42,
  changes: %{
    review_status: {nil, "approved"},
    review_notes: {nil, "Looks good, security audit passed"},
    reviewed_by_id: {nil, 5},
    reviewed_at: {nil, ~U[2025-12-18 17:00:00Z]}
  },
  metadata: %{
    reviewed_by: "john@example.com"
  }
}
```

**UI Action:**
- Update task card with review badge (approved/changes_requested/rejected)
- Show review notes in tooltip or modal
- Move to "Done" column if approved
- Move back to "In Progress" if changes_requested
- Show notification to agent if changes requested

### Event: task_status_changed

**When:** Task status field updated via API

**Payload:**
```elixir
%{
  event: "task_status_changed",
  task_id: 42,
  changes: %{
    status: {"in_progress", "blocked"}
  },
  metadata: %{
    changed_by: "admin@example.com",
    reason: "Waiting for external dependency"
  }
}
```

**UI Action:**
- Update task card status badge
- Show "blocked" indicator
- Optionally display reason in tooltip

### Event: task_updated

**When:** Generic task fields updated via PATCH /api/tasks/:id

**Payload:**
```elixir
%{
  event: "task_updated",
  task_id: 42,
  changes: %{
    title: {"Old title", "New title"},
    priority: {2, 0},
    needs_review: {false, true}
  },
  metadata: %{
    updated_by: "admin@example.com"
  }
}
```

**UI Action:**
- Update task card fields
- Re-sort column if priority changed
- Update review indicator if needs_review changed

### Event: task_deleted

**When:** Task deleted via DELETE /api/tasks/:id

**Payload:**
```elixir
%{
  event: "task_deleted",
  task_id: 42,
  metadata: %{
    deleted_by: "admin@example.com",
    column_id: 5
  }
}
```

**UI Action:**
- Remove task card from column
- Trigger fade-out animation
- Update column task count

## Implementation

### Broadcasting Changes (Server-Side)

**In Tasks Context:**
```elixir
defmodule Kanban.Tasks do
  alias Phoenix.PubSub

  @doc """
  Broadcast task change to all subscribers.
  """
  def broadcast_task_change(task, event, metadata \\ %{}) do
    task = Repo.preload(task, [:column])
    board_id = task.column.board_id

    payload = %{
      event: to_string(event),
      task_id: task.id,
      changes: extract_changes(task),
      metadata: metadata
    }

    # Broadcast to board subscribers
    PubSub.broadcast(
      Kanban.PubSub,
      "tasks:board:#{board_id}",
      {:task_changed, payload}
    )

    # Broadcast to task subscribers
    PubSub.broadcast(
      Kanban.PubSub,
      "tasks:task:#{task.id}",
      {:task_changed, payload}
    )

    :ok
  end

  defp extract_changes(%Ecto.Changeset{} = changeset) do
    changeset.changes
    |> Enum.map(fn {field, new_value} ->
      old_value = Map.get(changeset.data, field)
      {field, {old_value, new_value}}
    end)
    |> Enum.into(%{})
  end

  defp extract_changes(_), do: %{}
end
```

**Usage in API Controllers:**
```elixir
defmodule KanbanWeb.API.TaskController do
  def claim(conn, _params) do
    case Tasks.claim_next_task(agent_capabilities) do
      {:ok, task} ->
        # Broadcast change
        Tasks.broadcast_task_change(task, :task_claimed, %{
          claimed_by: conn.assigns.api_token.metadata["ai_agent"],
          api_token_id: conn.assigns.api_token.id
        })

        render(conn, "show.json", task: task)

      {:error, :no_tasks_available} ->
        # ...
    end
  end
end
```

### Receiving Updates (Client-Side - LiveView)

**In BoardLive:**
```elixir
defmodule KanbanWeb.BoardLive do
  use KanbanWeb, :live_view

  @impl true
  def mount(%{"id" => board_id}, _session, socket) do
    if connected?(socket) do
      # Subscribe to board updates
      Phoenix.PubSub.subscribe(Kanban.PubSub, "tasks:board:#{board_id}")
    end

    {:ok, assign(socket, board_id: board_id, tasks: load_tasks(board_id))}
  end

  @impl true
  def handle_info({:task_changed, %{event: "task_claimed"} = payload}, socket) do
    # Update task in state
    updated_tasks = update_task_in_list(socket.assigns.tasks, payload.task_id, fn task ->
      Map.merge(task, %{
        status: "in_progress",
        claimed_at: payload.changes[:claimed_at] |> elem(1)
      })
    end)

    {:noreply, assign(socket, tasks: updated_tasks)}
  end

  @impl true
  def handle_info({:task_changed, %{event: "task_moved"} = payload}, socket) do
    # Re-fetch tasks or update position in state
    updated_tasks = move_task_to_column(
      socket.assigns.tasks,
      payload.task_id,
      payload.changes.column_id |> elem(1)
    )

    {:noreply, assign(socket, tasks: updated_tasks)}
  end

  @impl true
  def handle_info({:task_changed, %{event: "task_created"} = payload}, socket) do
    # Add new task to list
    new_task = payload.task
    updated_tasks = [new_task | socket.assigns.tasks]

    {:noreply, assign(socket, tasks: updated_tasks)}
  end

  # Handle other events...
end
```

### Receiving Updates (Client-Side - Channels)

**JavaScript Channel Subscription:**
```javascript
// Join board channel
const boardChannel = socket.channel(`tasks:board:${boardId}`, {})

boardChannel.on("task_changed", (payload) => {
  switch(payload.event) {
    case "task_claimed":
      updateTaskStatus(payload.task_id, "in_progress")
      showClaimedIndicator(payload.task_id, payload.metadata.claimed_by)
      break

    case "task_moved":
      const [fromColumn, toColumn] = payload.changes.column_id
      moveTaskBetweenColumns(payload.task_id, fromColumn, toColumn)
      break

    case "task_completed":
      updateTaskStatus(payload.task_id, "completed")
      showCompletionAnimation(payload.task_id)
      break

    case "task_reviewed":
      updateReviewStatus(payload.task_id, payload.changes.review_status[1])
      showReviewBadge(payload.task_id, payload.changes.review_status[1])
      break

    // ... handle other events
  }
})

boardChannel.join()
  .receive("ok", () => console.log("Joined board channel"))
  .receive("error", (resp) => console.error("Failed to join:", resp))
```

## API Integration Points

### All Task Modification Endpoints Must Broadcast

**Endpoints that trigger broadcasts:**

1. **POST /api/tasks** → `task_created`
2. **POST /api/tasks/batch** → Multiple `task_created` events
3. **POST /api/tasks/claim** → `task_claimed`
4. **POST /api/tasks/:id/unclaim** → `task_unclaimed`
5. **PATCH /api/tasks/:id** → `task_updated`
6. **PATCH /api/tasks/:id/complete** → `task_completed`
7. **PATCH /api/tasks/:id/review** → `task_reviewed`
8. **PATCH /api/tasks/:id/move** → `task_moved`
9. **PATCH /api/tasks/:id/status** → `task_status_changed`
10. **DELETE /api/tasks/:id** → `task_deleted`

### Background Jobs Must Broadcast

**Oban Workers:**

1. **ReleaseExpiredClaims** → `task_unclaimed` (for each expired claim)
2. **AutoArchiveCompletedTasks** → `task_archived` (if implemented)

## Optimizations

### Batch Updates

For operations that affect multiple tasks (e.g., batch create, bulk status change):

```elixir
# Instead of:
Enum.each(tasks, fn task ->
  Tasks.broadcast_task_change(task, :task_created)
end)

# Use:
Tasks.broadcast_batch_changes(tasks, :task_created)

# Implementation:
def broadcast_batch_changes(tasks, event, metadata \\ %{}) do
  tasks_by_board = Enum.group_by(tasks, & &1.column.board_id)

  Enum.each(tasks_by_board, fn {board_id, board_tasks} ->
    payload = %{
      event: to_string(event),
      tasks: Enum.map(board_tasks, &summarize_task/1),
      metadata: metadata
    }

    PubSub.broadcast(
      Kanban.PubSub,
      "tasks:board:#{board_id}",
      {:tasks_batch_changed, payload}
    )
  end)
end
```

### Delta Updates

Only send changed fields, not entire task:

```elixir
# Instead of sending full task:
%{task: full_task_map}

# Send only changes:
%{
  task_id: 42,
  changes: %{
    status: {"open", "in_progress"},
    claimed_at: {nil, ~U[2025-12-18 15:00:00Z]}
  }
}
```

### Debouncing

For rapid successive changes, debounce broadcasts on the client:

```javascript
const debouncedUpdate = debounce((taskId, changes) => {
  updateTaskUI(taskId, changes)
}, 100)

boardChannel.on("task_changed", (payload) => {
  debouncedUpdate(payload.task_id, payload.changes)
})
```

## Testing

### Unit Tests

```elixir
defmodule Kanban.TasksTest do
  use Kanban.DataCase

  test "claiming task broadcasts change" do
    board = insert(:board)
    column = insert(:column, board: board)
    task = insert(:task, column: column, status: "open")

    Phoenix.PubSub.subscribe(Kanban.PubSub, "tasks:board:#{board.id}")

    {:ok, claimed_task} = Tasks.claim_task(task.id, api_token_id)

    assert_receive {:task_changed, %{
      event: "task_claimed",
      task_id: ^task.id
    }}
  end
end
```

### Integration Tests

```elixir
defmodule KanbanWeb.BoardLiveTest do
  use KanbanWeb.ConnCase
  import Phoenix.LiveViewTest

  test "UI updates when task claimed via API", %{conn: conn} do
    board = insert(:board)
    task = insert(:task, board: board, status: "open")

    {:ok, view, _html} = live(conn, "/boards/#{board.id}")

    # Simulate API claim
    Tasks.claim_task(task.id, api_token_id)

    # Verify UI updated
    assert render(view) =~ "in_progress"
  end
end
```

## Security Considerations

### Authorization

Users should only receive broadcasts for boards they have access to:

```elixir
defmodule KanbanWeb.BoardChannel do
  def join("tasks:board:" <> board_id, _payload, socket) do
    if authorized?(socket, board_id) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  defp authorized?(socket, board_id) do
    user = socket.assigns.current_user
    Boards.user_can_view?(user, board_id)
  end
end
```

### Payload Sanitization

Don't send sensitive data in broadcasts:

```elixir
def summarize_task(task) do
  %{
    id: task.id,
    title: task.title,
    status: task.status,
    # Don't include: API tokens, sensitive metadata, etc.
  }
end
```

## Monitoring

### Telemetry

```elixir
:telemetry.execute(
  [:kanban, :pubsub, :broadcast],
  %{message_count: 1},
  %{
    topic: "tasks:board:#{board_id}",
    event: "task_claimed"
  }
)
```

### Metrics

- Counter: PubSub messages sent by event type
- Counter: PubSub subscription count by topic
- Histogram: Broadcast latency
- Counter: Failed broadcasts

## Summary

Real-time UI updates via PubSub ensure that all users see task changes immediately when agents make API calls. This provides:

1. **Instant Feedback**: Users see agent progress in real-time
2. **Coordination**: Multiple users stay synchronized
3. **Transparency**: Clear visibility into what agents are doing
4. **Efficiency**: No polling required

All API endpoints that modify tasks must broadcast changes to the appropriate PubSub topics.
