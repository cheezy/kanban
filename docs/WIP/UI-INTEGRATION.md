# UI Integration

This document covers UI design decisions for the AI-optimized Kanban system, including Goal representation and task creation attribution.

## Goal Card Design

Goals appear as smaller cards on the Kanban board, visually distinct from regular tasks, with their child tasks listed beneath them.

### Visual Layout

**Board Column Structure:**
```
┌─────────────────────────────────┐
│ COLUMN: In Progress             │
├─────────────────────────────────┤
│ ┌─────────────────────────────┐ │ ← Goal Card (40% height)
│ │ G1: Implement AI System     │ │
│ │ ████████░░░░ 55% (6/11)    │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │ ← Task Card (100% height)
│ │ W1: Add API auth     [W1]   │ │
│ │ Description text...         │ │
│ │                             │ │
│ │ Goal: G1: Implement AI Sys  │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │ ← Task Card (100% height)
│ │ W2: Create endpoint  [W2]   │ │
│ │ Description text...         │ │
│ │                             │ │
│ │ Goal: G1: Implement AI Sys  │ │
│ └─────────────────────────────┘ │
└─────────────────────────────────┘
```

### Goal Card Specifications

**Visual Design:**
- **Height:** 40% of standard task card height
- **Background:** Light yellow (#FFF9C4) for visual distinction
- **Content:**
  - **Top Row:** Title + Identifier badge (G1, G2, etc.)
  - **Bottom Row:** Progress bar with percentage and fraction

**Example Goal Card:**
```
┌─────────────────────────────────┐
│ Implement AI System         [G1]│
│ ████████░░░░ 55% (6/11)        │
└─────────────────────────────────┘
```

**Behavior:**
- **Non-draggable:** Goals cannot be manually moved between columns
- **Automatic Movement:**
  - Moves to "In Progress" when first child task moves to "In Progress"
  - Stays in "In Progress" while any tasks are incomplete
  - Moves to "Done" when last child task moves to "Done"
- **Real-time Updates:** Progress bar updates via Phoenix PubSub as child tasks complete
- **Clickable:** Opens goal detail view showing full task tree

### Task Card with Goal Assignment

**Visual Design:**
```
┌─────────────────────────────────┐
│ Add API authentication   [W42]  │
│ Description text here...        │
│                                 │
│ Goal: [Select Goal ▼]          │ ← Dropdown if no goal assigned
│ or                              │
│ Goal: [G1: AI System      ×]   │ ← Badge if goal assigned
└─────────────────────────────────┘
```

**Dropdown Behavior:**
- **Visibility:** Only shown if goals exist on the board
- **Options:** Lists all available goals with identifiers (G1, G2, etc.)
- **Selection:** Assigns task to goal and displays as badge
- **Removal:** × button unassigns task from goal
- **Events:** `phx-change="assign-goal"` and `phx-click="remove-goal"`

### Implementation Approach

**Goal Card Component:**
```heex
<div class="goal-card bg-yellow-50 rounded-lg p-3 mb-2"
     style="height: 40%; min-height: 60px; cursor: default;"
     phx-click="view-goal-details"
     phx-value-goal-id={@goal.id}>

  <div class="flex items-center justify-between mb-2">
    <h3 class="font-semibold text-sm truncate flex-1">
      <%= @goal.title %>
    </h3>
    <span class="identifier-badge bg-yellow-200 px-2 py-1 rounded text-xs font-mono">
      <%= @goal.identifier %>
    </span>
  </div>

  <div class="progress-section">
    <div class="w-full bg-gray-200 rounded-full h-2 mb-1">
      <div class="bg-yellow-500 h-2 rounded-full"
           style={"width: #{@goal.progress_percentage}%"}>
      </div>
    </div>
    <p class="text-xs text-gray-600">
      <%= @goal.progress_percentage %>%
      (<%= @goal.completed_tasks %>/<%= @goal.total_tasks %>)
    </p>
  </div>
</div>
```

**Task Card Goal Dropdown:**
```heex
<%= if @board_has_goals do %>
  <div class="goal-selector mt-2">
    <%= if @task.parent_id do %>
      <div class="goal-badge inline-flex items-center gap-2 px-2 py-1 bg-yellow-50 rounded text-xs">
        <span class="font-medium">
          <%= @task.parent_goal.identifier %>: <%= @task.parent_goal.title %>
        </span>
        <button
          phx-click="remove-goal"
          phx-value-task-id={@task.id}
          class="text-gray-500 hover:text-gray-700"
          aria-label="Remove from goal">
          ×
        </button>
      </div>
    <% else %>
      <select
        phx-change="assign-goal"
        phx-value-task-id={@task.id}
        class="goal-dropdown text-xs border rounded px-2 py-1">
        <option value="">Select Goal...</option>
        <%= for goal <- @available_goals do %>
          <option value={goal.id}>
            <%= goal.identifier %>: <%= goal.title %>
          </option>
        <% end %>
      </select>
    <% end %>
  </div>
<% end %>
```

### Progress Calculation

**Formula:**
```
progress_percentage = (completed_tasks / total_tasks) × 100
```

**Automatic Status:**
- **"Not Started":** 0 tasks completed (goal in "Open" column)
- **"In Progress":** 1+ tasks completed but not all (goal in "In Progress" column)
- **"Completed":** All tasks completed (goal in "Done" column)

**Real-time Updates:**
- Phoenix PubSub broadcasts when task status changes
- All connected clients update goal progress bar
- Goal automatically moves to appropriate column

### LiveView Event Handlers

**Goal Assignment:**
```elixir
def handle_event("assign-goal", %{"task-id" => task_id, "value" => goal_id}, socket) do
  task = Tasks.get_task!(task_id)
  {:ok, _task} = Tasks.update_task(task, %{parent_id: goal_id})

  Phoenix.PubSub.broadcast(
    Kanban.PubSub,
    "board:#{socket.assigns.board_id}",
    {:task_updated, task_id}
  )

  {:noreply, socket}
end

def handle_event("remove-goal", %{"task-id" => task_id}, socket) do
  task = Tasks.get_task!(task_id)
  {:ok, _task} = Tasks.update_task(task, %{parent_id: nil})

  Phoenix.PubSub.broadcast(
    Kanban.PubSub,
    "board:#{socket.assigns.board_id}",
    {:task_updated, task_id}
  )

  {:noreply, socket}
end
```

**Automatic Goal Movement:**
```elixir
def handle_info({:task_updated, task_id}, socket) do
  task = Tasks.get_task!(task_id)

  if task.parent_id do
    goal = Tasks.get_task!(task.parent_id)
    new_column = determine_goal_column(goal)

    if goal.column_id != new_column.id do
      {:ok, _goal} = Tasks.update_task(goal, %{column_id: new_column.id})

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{socket.assigns.board_id}",
        {:goal_moved, goal.id}
      )
    end
  end

  {:noreply, reload_board(socket)}
end

defp determine_goal_column(goal) do
  child_tasks = Tasks.list_tasks_for_goal(goal.id)

  cond do
    Enum.all?(child_tasks, & &1.status == :completed) ->
      Boards.get_column_by_name("Done")
    Enum.any?(child_tasks, & &1.status in [:in_progress, :completed]) ->
      Boards.get_column_by_name("In Progress")
    true ->
      Boards.get_column_by_name("Open")
  end
end
```

### Benefits of This Design

**Visual Clarity:**
- Goals and tasks both visible on board (no separate page needed)
- Smaller goal cards don't clutter the board
- Yellow background makes goals instantly recognizable
- Clear parent-child relationship

**Automatic Movement:**
- No manual dragging of goals reduces errors
- Progress automatically tracked and displayed
- Status always reflects true state of child tasks

**Easy Assignment:**
- Dropdown makes goal assignment quick and simple
- No need to drag tasks under goals
- Badge shows current assignment at a glance

**Real-time Collaboration:**
- Multiple users see progress updates immediately
- PubSub ensures everyone stays in sync
- Automatic goal movement visible to all

## Task Creation Attribution

Do you want the Kanban board to show "AI-created" vs "human-created" tasks differently?

I think showing them the same is the right default approach. Here's my reasoning:

## ✅ Show Them the Same (Recommended)

### Why This Works Better

#### 1. Tasks Are Tasks

- What matters is the work, not who created it
- Both need the same lifecycle: open → in progress → done
- Both get assigned, prioritized, blocked the same way
- Treating them differently creates artificial hierarchy

#### 2. Seamless Handoff

- Human creates task → AI implements it
- AI creates subtasks → Human reviews/tweaks them
- Creating a visual distinction suggests they're fundamentally different (they're not)

#### 3. Reduces Friction

- No cognitive overhead: "Is this an AI task or human task?"
- One mental model for all work
- Simpler UI/UX

#### 4. Trust Building

- If AI tasks are "second-class citizens" visually, you won't trust them
- Equal presentation implies equal validity
- Encourages treating AI as a collaborator, not a separate system

#### 5. Ownership Can Transfer

- AI creates a task, human edits it → whose is it now?
- Human creates task, AI breaks it into subtasks → mixed ownership
- Marking origin becomes meaningless quickly

## 🤔 When Differentiation Might Help

There are subtle ways to show origin without making them "different":

### Metadata (Not Visual Distinction)

Track `created_by` in the database:

```json
{
  "id": "kanban-123",
  "title": "Add priority filter",
  "created_by": {
    "type": "ai_agent",  // or "user"
    "agent": "claude-sonnet-4.5",
    "user_id": 42  // AI acted on behalf of this user
  }
}
```

#### Show it subtly

- Small badge on hover: "Created by AI"
- In task details sidebar (not on card)
- In activity log: "Claude created this task"

#### Don't

- Different card colors
- Different columns
- Visual hierarchy

### Benefits of Tracking (Without Visual Distinction)

1. **Analytics**: "How many AI-created tasks get completed vs. human-created?"
2. **Debugging**: "Did AI misunderstand? Check its created tasks"
3. **Audit trail**: "Who created this confusing task?"
4. **Filtering**: Optional filter "Show only AI-created" for review

But these are power user features, not core UX.

## My Recommendation

**Default View**: All tasks look identical Optional power features:

- Task detail view shows `created_by: Claude on Dec 13, 2025`
- Activity log shows creation: "🤖 Claude created 'Add auth API'"
- Filter option (hidden by default): "Created by: All / Me / AI"

*Visual equality = functional equality*. The real question is: Do you trust the AI enough to create tasks that stand alongside yours? If yes → same appearance. If no → fix the AI's task quality, don't mark them as "different."

## Counter-Example: GitHub Issues

GitHub doesn't visually distinguish between:

- Issues created by bots (Dependabot, GitHub Actions)
- Issues created by humans

They're all just issues. You only know the creator if you look at the metadata. Works great! What's your intuition? Do you see value in visual distinction that I'm missing?
