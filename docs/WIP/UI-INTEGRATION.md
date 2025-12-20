# UI Integration

This document covers UI design decisions for the AI-optimized Kanban system, including Goal representation and task creation attribution.

## Goal Card Design

Goals appear on the Kanban board with a distinct but minimalist design that emphasizes their organizational role.

### Visual Specifications

**Card Height:** Shorter than regular task cards (approximately 40% height)

**Background Color:** Light yellow (#FFF9C4 or similar) to distinguish from tasks

**Layout:**
```
┌─────────────────────────────────┐
│ Goal Title               [G1]   │ ← Top row: title + identifier
│ ████████░░░░░░░ 55% (6/11)     │ ← Progress bar with percentage + count
└─────────────────────────────────┘
```

**Components:**
1. **Top Row:**
   - Goal title (truncated with ellipsis if too long)
   - Identifier badge (G1, G2, etc.) right-aligned

2. **Progress Bar:**
   - Visual progress indicator showing completion percentage
   - Text showing: "XX% (completed/total)"
   - Example: "55% (6/11)" means 6 out of 11 tasks completed

### Behavior

**Non-Draggable:**
- Goals cannot be manually dragged between columns
- User attempts to drag are prevented/ignored
- Goals move automatically based on task status

**Automatic Column Movement:**

1. **Starting State:** Goal begins in the first column (typically "Open" or "Backlog")

2. **Move to In Progress:**
   - Triggered when the **first** child task moves to "In Progress"
   - Goal card automatically transitions to "In Progress" column

3. **Stay In Progress:**
   - Goal remains in "In Progress" as long as at least one task is incomplete
   - Progress bar updates with each task completion
   - Percentage and count update in real-time

4. **Move to Done:**
   - Triggered when the **last** task is completed
   - Goal card automatically transitions to "Done" column
   - Progress bar shows 100% (total/total)

**Progress Calculation:**
- Completed tasks / Total tasks × 100
- Only counts direct child tasks (not nested tasks if any)
- Updates in real-time via LiveView or PubSub events

### Technical Implementation Notes

**LiveView Component:**
```heex
<div class="goal-card bg-yellow-50 h-20 rounded-lg shadow-sm p-3 cursor-default">
  <div class="flex justify-between items-center mb-2">
    <span class="font-medium text-sm truncate"><%= @goal.title %></span>
    <span class="badge badge-goal text-xs"><%= @goal.identifier %></span>
  </div>

  <div class="progress-container">
    <div class="progress-bar bg-gray-200 rounded-full h-2 overflow-hidden">
      <div class="progress-fill bg-yellow-500 h-full transition-all duration-300"
           style={"width: #{@goal.completion_percentage}%"}>
      </div>
    </div>
    <div class="progress-text text-xs text-gray-600 mt-1">
      <%= @goal.completion_percentage %>% (<%= @goal.completed_tasks %>/<%= @goal.total_tasks %>)
    </div>
  </div>
</div>
```

**Data Requirements:**
- `completion_percentage` - Calculated field (completed_tasks/total_tasks * 100)
- `completed_tasks` - Count of child tasks with status="completed"
- `total_tasks` - Count of all child tasks
- Real-time updates via PubSub when child task status changes

### Hover/Interaction States

**Hover:**
- Slight shadow increase or subtle highlight
- No drag cursor (remains default cursor)
- Optional: Show tooltip with full title if truncated

**Click:**
- Opens goal detail view showing all child tasks
- Tree/hierarchical view of tasks and their status
- Option to add new tasks to the goal

### Accessibility

- ARIA label: "Goal: [title], [X]% complete, [Y] of [Z] tasks done"
- Keyboard navigation: Tab to focus, Enter to open details
- Screen reader announces progress updates
- Color contrast meets WCAG AA standards (yellow background with dark text)

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
