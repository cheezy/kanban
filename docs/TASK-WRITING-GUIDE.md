# Task Writing Guide for AI Agents

This guide helps create clear, actionable tasks that AI agents (and human developers) can implement efficiently. Well-written tasks reduce back-and-forth, minimize exploration time, and lead to better implementations.

## Important: Task Identifiers Are Auto-Generated

**DO NOT specify identifiers when creating tasks.** The system automatically generates human-readable identifiers for all tasks:

- **G1, G2, G3...** - Goals (large initiatives, 25+ hours, contain multiple tasks)
- **W1, W2, W3...** - Work tasks (individual work items, 1-3 hours)
- **D1, D2, D3...** - Defects (bug fixes and defect corrections)

**What this means for you:**
- When creating tasks via `POST /api/tasks`, **never** include an `identifier` field
- The system will automatically assign the next available identifier (e.g., W42, G5, D12)
- Identifiers are globally unique and sequential
- You can reference tasks by identifier after they're created (e.g., "W42 depends on W15")

**Example - Creating a Goal with Tasks:**
```json
{
  "goal": {
    "title": "Implement search feature",
    "tasks": [
      {
        "title": "Add search schema",
        "type": "work"
      },
      {
        "title": "Build search UI",
        "type": "work"
      }
    ]
  }
}
```

**System generates:**
- Goal: `G1 - Implement search feature`
- Task 1: `W1 - Add search schema`
- Task 2: `W2 - Build search UI`

## Essential Information for Easy Implementation

1. Clear Acceptance Criteria
    - What does "done" look like?
    - Specific behaviors or outcomes expected
    - Examples of what should/shouldn't happen

2. Context & Why
    - What problem does this solve?
    - Who is the user/stakeholder?
    - What value does this provide?

3. Technical Constraints
    - Which files/modules are affected?
    - Any existing patterns to follow?
    - Performance requirements?
    - Security considerations?

4. Dependencies & Prerequisites
    - What must be done first?
    - What other issues does this relate to?
    - Are there blockers?

5. Examples & Test Cases
    - Input/output examples
    - Edge cases to handle
    - Error scenarios

6. UI/UX Details (if applicable)
    - Where does it appear in the UI?
    - What should the user see/experience?
    - Any specific styling or component requirements?

7. Scope Boundaries
    - What is explicitly OUT of scope?
    - What NOT to change/refactor?
    - Minimal vs. full implementation?

8. Related Code Locations (Discovery Shortcuts)
    - Specific file paths to start reading
    - Module/function names that are central to the task
    - Database tables/schemas involved
    - Routes or URLs affected
    - This saves exploration time - jump straight to the right files

9. Verification Commands
    - Exact commands to run to verify the task works
    - Expected output from those commands
    - How to know if tests pass vs. fail
    - Manual testing steps

10. Data Shape Examples
    - Actual data structures (maps, structs, JSON)
    - Before/after examples for mutations
    - Sample database records
    - API request/response examples

11. Common Pitfalls / What NOT to Do
    - Known issues in this area of code
    - Previous bugs or mistakes to avoid
    - "Don't forget to..." reminders
    - Anti-patterns specific to this codebase

12. Task Size/Complexity Indicator
    - Small (< 30 min), Medium (1-2 hours), Large (> 2 hours)
    - Number of files expected to change
    - Whether this needs careful planning vs. can start coding immediately

13. Success Indicators Beyond Tests
    - What should visibly work in the UI
    - What should appear in logs
    - Database state changes
    - Performance benchmarks (if applicable)

14. Integration Points
    - What other systems/features does this touch?
    - WebSocket/Phoenix Channel events involved
    - Background jobs triggered
    - External API calls
    - PubSub broadcasts needed

15. Observability Requirements
    - Should telemetry events be added?
    - What metrics should be tracked?
    - Any specific logging needed for debugging/monitoring?
    - Performance metrics to capture

16. Environment & Configuration
    - Environment variables or config needed
    - Feature flags that affect this code path
    - Database state assumptions (migrations, seed data)
    - External service dependencies

17. Error Handling Expectations
    - How to communicate errors to users
    - What happens on failure (rollback, retry, silent fail)
    - Logging requirements (level, info to include)
    - Specific error messages or validation messages

18. Migration Path (for changes)
    - Is this a breaking change?
    - Do existing records need data migration?
    - Backwards compatibility requirements?
    - Deployment order (migration before/after deploy)

### Task Template (Copy-Paste Ready)

```markdown
## [Verb] [What] [Where/Context]

**Complexity:** [Small/Medium/Large] | **Est. Files:** [1-2 / 3-5 / 5+]

### Description

**WHY:** [Problem being solved / Value provided]
**WHAT:** [Specific feature/change]
**WHERE:** [UI location / code area]

### Acceptance Criteria

- [ ] [Specific behavior 1]
- [ ] [Specific behavior 2]
- [ ] [Specific behavior 3]

### Key Files to Read First

- `path/to/main/file.ex` - [Brief description of relevance]
- `path/to/context.ex` - [Brief description]

### Technical Notes

**Patterns to Follow:**
- [Existing pattern/convention to use]

**Database/Schema:**
- Tables: [table_names]
- Migrations needed: [yes/no - description if yes]

**Integration Points:**
- [ ] PubSub broadcasts: [channel/event names]
- [ ] Phoenix Channels: [socket/topic names]
- [ ] External APIs: [which services]

### Verification

**Commands to Run:**
```bash
mix test path/to/test.exs
mix precommit
```

**Manual Testing:**
1. [Step-by-step testing instructions]
2. [Expected outcome]

**Success Looks Like:**
- [UI shows X]
- [Database has Y]
- [Logs contain Z]

### Data Examples

**Input:**
```elixir
%{field: value}
```

**Output:**
```elixir
%Model{field: value, ...}
```

### Observability

- [ ] Telemetry event: `[:app, :domain, :action]`
- [ ] Metrics: [counter/sum/summary of what]
- [ ] Logging: [info/warn/error for what scenarios]

### Error Handling

- User sees: [error message/UI state]
- On failure: [rollback/retry/silent fail]
- Validation: [what to validate and messages]

### Common Pitfalls

- [ ] Don't forget to [common mistake]
- [ ] Remember to [important step]
- [ ] Avoid [anti-pattern]

### Dependencies

**Requires:** [task-id or "none"]
**Blocks:** [task-id or "none"]

### Out of Scope

- [What NOT to do/change]
- [Future enhancements to skip]
```

### Example Task (Filled Out)

```markdown
## Add priority filter to board list view

**Complexity:** Medium | **Est. Files:** 2-3

### Description

**WHY:** Users need to focus on high-priority tasks without manually scanning
**WHAT:** Add a dropdown filter for task priority (0-4) in board header
**WHERE:** Board list view header, next to existing status filter

### Acceptance Criteria

- [ ] Dropdown shows priorities 0-4 with labels (Critical, High, Medium, Low, None)
- [ ] Filtering updates task list in real-time via LiveView
- [ ] Filter state persists in URL params (?priority=3)
- [ ] Shows "All Priorities" option to clear filter
- [ ] Works with existing status filter (combines filters)

### Key Files to Read First

- `lib/kanban_web/live/board_live.ex` - Main LiveView handling board display
- `lib/kanban/boards.ex` - Context with get_tasks/2 function to update
- `lib/kanban/schemas/task.ex` - Check if priority field exists

### Technical Notes

**Patterns to Follow:**
- Use same filter pattern as existing status filter in board_live.ex
- Follow LiveView handle_event pattern for filter changes

**Database/Schema:**
- Tables: tasks
- Migrations needed: Yes - add priority:integer field if not exists

**Integration Points:**
- [ ] PubSub broadcasts: Not needed (read-only filter)
- [ ] Phoenix Channels: None
- [ ] External APIs: None

### Verification

**Commands to Run:**
```bash
mix test test/kanban/boards_test.exs
mix test test/kanban_web/live/board_live_test.exs
mix precommit
```

**Manual Testing:**
1. Navigate to /boards
2. Click priority filter dropdown
3. Select "High (3)" priority
4. Verify only priority 3 tasks show
5. Check URL contains ?priority=3
6. Refresh page - filter should persist
7. Select "All Priorities" - should show all tasks

**Success Looks Like:**
- Dropdown appears in board header
- Task list updates without page reload
- URL updates with query param
- Page refresh maintains filter state

### Data Examples

**Query Params:**
```elixir
%{"priority" => "3", "status" => "in_progress"}
```

**Filtered Query:**
```elixir
# In Boards.get_tasks/2
from t in Task,
  where: t.priority == ^priority,
  where: t.status == ^status
```

### Observability

- [ ] Telemetry event: Not needed for this feature
- [ ] Metrics: Could add `[:kanban, :filter, :used]` counter (optional)
- [ ] Logging: No logging needed (simple read operation)

### Error Handling

- User sees: No special errors (graceful degradation if invalid priority)
- On failure: Show all tasks (don't break the page)
- Validation: Ensure priority is 0-4 or nil

### Common Pitfalls

- [ ] Don't forget to broadcast filter changes via PubSub (actually not needed - read-only)
- [ ] Remember to handle nil priority (tasks without priority set)
- [ ] Avoid N+1 queries - filters happen at DB level

### Dependencies

**Requires:** None (can add migration in this task)
**Blocks:** None

### Out of Scope

- Don't add sorting by priority (separate task)
- Don't modify the task card layout or styling
- Don't add bulk priority assignment
```

## Internal Mental Model During Task Execution

1. Task Context
    - Original user request (exact words matter!)
    - The "why" behind the request
    - Success criteria / definition of "done"

2. Discovery & Understanding
    - Files I've read and their purpose
    - Existing patterns I've found
    - How the current system works
    - Dependencies between components

3. Implementation Plan
    - Step-by-step approach
    - Which files need changes
    - Order of operations (what must happen first)
    - Testing strategy

4. Progress Tracking
    - What I've completed
    - What's in progress
    - What's still pending
    - Blockers or questions that arise

5. Code Changes Map
    - Files modified and why
    - Functions/components added/changed
    - Migration/database changes
    - Configuration updates

6. Quality Checklist
    - Tests written/updated
    - Error handling added
    - Edge cases covered
    - Styling matches existing patterns
    - Security considerations addressed

7. Verification Plan
    - How to test the changes
    - Commands to run (mix test, mix precommit, etc.)
    - Manual testing steps
    - What success looks like

8. Open Questions & Assumptions
    - Things I'm uncertain about
    - Assumptions I'm making
    - Questions for the user

### Task Tracking in Stride

In this project, tasks are tracked in the Stride kanban system with the following benefits:
- Persists across sessions
- API accessible for AI agents
- Handles dependencies between tasks and goals
- Visible to all team members and agents
- Hook-based workflow for automation

When creating tasks in Stride, include enough detail from this guide so that any agent (or developer) can:
- Understand the context immediately
- Start implementing without extensive exploration
- Know exactly what success looks like
- Verify their work is complete

Well-written tasks with clear acceptance criteria, code locations, and verification steps make the difference between a 30-minute implementation and a 3-hour exploration session.
