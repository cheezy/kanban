# TASKS - what is needed to implement a task efficiently - from Claude Code

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

### Ideal Task Structure

Title: [Verb] [What] [Where/Context]
e.g., "Add priority filter to board list view"

Description:

- WHY: Users need to focus on high-priority tasks
- WHAT: Add a dropdown filter for task priority (0-4)
- WHERE: Board list view header

Acceptance Criteria:

- [ ] Dropdown shows priorities 0-4 with labels
- [ ] Filtering updates the task list in real-time
- [ ] Filter state persists in URL params
- [ ] Shows "All" option to clear filter

Technical Notes:

- Files: lib/kanban_web/live/board_live.ex
- Use existing filter pattern from status filter
- Update get_tasks/2 in Kanban.Boards context

Dependencies:

- Blocks: beads-xyz (needs priority field in schema)

Out of Scope:

- Don't add sorting by priority (separate task)
- Don't modify the task card layout

The more specific and complete the task description, the faster and more accurately I can implement it! Does this help? Are you thinking about how to structure issues in the Beads system for better AI implementation?

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

### What I Use to Track This

In this project, I should be using Beads (bd) to track tasks instead of my TodoWrite tool. The Beads system is better because:
    - It persists across sessions
    - It's git-synced
    - It handles dependencies
    - It's visible to you and other developers

However, internally during a single session, I also benefit from having a working memory of:
    - The current task breakdown
    - What step I'm on
    - What's blocked/waiting

So ideally, a Beads issue would contain enough detail that I can rebuild this mental model quickly when I start working on it! Is this the kind of information you're thinking about storing in Beads tasks to make implementation smoother?
