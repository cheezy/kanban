# Task Form Field Visibility

This document explains which fields are visible in the task creation and editing form, and under what conditions they appear.

## Board-Level Field Visibility Settings

As a board owner, you can control which optional task fields appear on task forms by toggling their visibility in the board settings:

1. Navigate to your board
2. Open the **Settings** tab
3. Find the "Field visibility" section
4. Toggle checkboxes to show/hide fields

Each checkbox saves as soon as you click it; there is no separate save step for
field visibility. Only the board owner can change these settings. Other members
see a note that only the owner can change them.

The older Edit Board page, opened from the pencil icon ("Edit board") on the
board's card in your boards list, has the same checkboxes under "Field
Visibility Settings", except **Behaviour/Test Matrix**, which only the Settings
tab offers.

### Configurable Fields

The following fields can be shown or hidden via board settings:

- **Acceptance Criteria** - Define what "done" looks like
- **Complexity & Scope** - Complexity level and estimated files
- **Context (Why/What/Where)** - Problem context and implementation details
- **Key Files** - Files that will be modified
- **Verification Steps** - Commands and manual steps to verify completion
- **Technical Notes** - Patterns to follow, database changes, validation rules
- **Observability** - Telemetry events, metrics, logging requirements
- **Error Handling** - User error messages and failure handling
- **Technology Requirements** - Libraries and dependencies needed
- **Pitfalls** - Common mistakes to avoid
- **Out of Scope** - What NOT to do
- **Required Agent Capabilities** - Agent capabilities needed for claiming
- **Security Considerations** - Security requirements and warnings
- **Testing Strategy** - Unit tests, integration tests, manual tests
- **Integration Points** - Telemetry events, PubSub broadcasts, Phoenix Channels, external APIs
- **Technical Details** - Free-form technical notes, as a JSON object
- **Behaviour/Test Matrix** - Behaviours paired with the tests that cover them (Settings tab only)

On a new board only **Acceptance Criteria** is shown; every other field starts
hidden until the owner turns it on.

On a board whose paid fields are locked, **Observability** still shows Logging
Requirements but hides Telemetry Event and Metrics to Track. Paid fields are
locked only while paid plans are enforced and the board is not in an
Organization's workspace; with enforcement off, which is the default, they are
never locked.

## Always-Visible Fields

These fields appear on every task form, regardless of board settings:

### Basic Information
- **Title** - Task title (required)
- **Description** - Detailed description
- **Type** - Work, Defect, or Goal (required)
- **Parent Goal** - Link to parent goal (if applicable)
- **Priority** - Low, Medium, High, or Critical (required)
- **Status** - Open, In Progress, Blocked, or Completed (required)
  - When set to "Completed", automatically sets `completed_at` timestamp
  - Tasks that depend on this one become claimable once all of their dependencies are completed
- **Assigned To** - User assigned to task
- **Column** - Which column to place the task in (new tasks only)
- **Human Task** - Marks the task for people only, so agents are never offered it
- **Labels** - The board's labels to attach to the task

**Needs Review** - whether the task requires human review before completion -
appears only on AI-optimized boards.

### Always-Visible Management Fields
- **Dependencies** - Task identifiers that must complete first

## Conditionally Visible Fields

### Actual Metrics

The **Actual Metrics** section only appears when a task has actual metrics data recorded.

**When It Appears:**
- The task has a value in `actual_complexity`, `actual_files_changed`, or `time_spent_minutes`

**When It's Hidden:**
- For tasks that have no actual metrics recorded yet, this section is hidden to reduce form clutter

**Fields in This Section:**
- **Actual Complexity** - Actual complexity level (Small, Medium, Large)
- **Actual Files Changed** - The files actually modified, as free text (agents send a comma-separated list of paths)
- **Time Spent (minutes)** - Actual time spent on the task

**Why This Design?**
- Reduces clutter for tasks that haven't been worked on yet
- Actual metrics are only relevant once work has been completed
- Preserves metrics data when it exists

### Review Queue

The **Review Queue** section only appears on AI-optimized boards, and only for a task that is in the review workflow.

**When It Appears:**
- The board is AI-optimized, **and** any of these is true:
  - The task has a value in `review_status` (pending, approved, changes_requested, or rejected)
  - The task is in the Review column
  - The task has `needs_review` set

**When It's Hidden:**
- For tasks that have not yet been reviewed, this section is hidden to reduce form clutter

**Fields in This Section:**
- **Review Status** - Pending, Approved, Changes Requested, or Rejected
- **Review Notes** - Notes from the reviewer about the task

**Why This Design?**
- Reduces clutter for tasks that haven't entered the review workflow yet
- Review fields are only relevant once a task is being reviewed
- Preserves review data when it exists

### Agent Tracking

The **Agent Tracking** section is special - it only appears when a task has been interacted with by an AI agent.

### When It Appears

This section is visible when **either** of these conditions is met:
- The task has a value in `created_by_agent` (task was created by an AI agent)
- The task has a value in `completed_by_agent` (task was completed by an AI agent)

### When It's Hidden

For human-created tasks that haven't been completed by an agent, this section is hidden to reduce form clutter.

### Fields in This Section

When visible, the Agent Tracking section includes:
- **Created By Agent** - Name of the AI agent that created the task
- **Completed By Agent** - Name of the AI agent that completed the task
- **Completion Summary** - Summary provided by the agent upon completion

### Why This Design?

**Reduces clutter for human users:**
- Humans typically don't need to see or set agent-specific fields
- Agent tracking fields are most relevant when reviewing agent work
- Conditional visibility keeps the form focused and easier to use

**Preserves agent tracking data:**
- When agents create or complete tasks, tracking data is preserved
- Humans can see which agent worked on a task
- The fields become visible when reviewing agent-created or agent-completed work

**Example scenarios:**

1. **Human creates task** → Agent Tracking section is hidden
2. **Agent creates task via API** → Section visible (shows `created_by_agent`)
3. **Human edits agent-created task** → Section remains visible
4. **Agent completes human-created task** → Section becomes visible (shows `completed_by_agent`)

## API Behavior

When creating or updating tasks via the API, board visibility settings never decide which fields are accepted:

- Field visibility settings only affect the **UI**: the task form and the sections shown when you view a task
- A field hidden on the board is still accepted by the API whenever a client may set it at all
- This allows agents to populate any field they need

Fields the server owns are a separate rule that visibility does not change: some
are ignored on create and some are refused on update. See
[Fields ignored on create](TASK-WRITING-GUIDE.md#fields-ignored-on-create) and
[Fields PATCH will not change](TASK-WRITING-GUIDE.md#fields-patch-will-not-change).

For example, an agent can set `acceptance_criteria` via API even if that field is hidden in the UI form. The data is saved, but won't appear in the form or the task view unless the board owner enables that field.

Board settings are not the only limit on what the API stores. When paid plans
are enforced, `telemetry_event` and `metrics_to_track` are dropped on a board
that is not in an Organization's workspace, and the response carries a
`warnings` list saying so (see [Warnings](api/post_tasks.md#warnings)).

## Updating Field Visibility

When a board owner changes field visibility settings:

1. Changes take effect immediately, as each checkbox is clicked
2. No data is lost - hidden fields retain their values
3. Hidden fields can be shown again at any time
4. The change is broadcast to everyone viewing the board (via PubSub)

## Best Practices

**For board owners:**
- Enable fields your team actually uses
- Disable fields to reduce form complexity
- Review field visibility periodically as needs change

**For AI agents:**
- Populate structured fields when creating tasks (see [TASK-WRITING-GUIDE.md](TASK-WRITING-GUIDE.md))
- Don't worry about field visibility - use the API to set any field
- Field visibility is a UI concern, not an API restriction

**For human users:**
- Use the fields your board owner has enabled
- If you need a field that's hidden, ask your board owner to enable it
- Agent tracking fields appear automatically when relevant

## Related Documentation

- [TASK-WRITING-GUIDE.md](TASK-WRITING-GUIDE.md) - Comprehensive guide for creating well-structured tasks
- [AI-WORKFLOW.md](AI-WORKFLOW.md) - AI agent workflow and API usage
- [api/post_tasks.md](api/post_tasks.md) - Creating tasks via API
- [api/patch_tasks_id.md](api/patch_tasks_id.md) - Updating tasks via API
