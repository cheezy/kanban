# Task Form Field Visibility

This document explains which fields are visible in the task creation and editing form, and under what conditions they appear.

## Board-Level Field Visibility Settings

As a board owner, you can control which optional task fields appear on task forms by toggling their visibility in the board settings:

1. Navigate to your board
2. Click "Edit board"
3. Scroll to the "Field Visibility Settings" section
4. Toggle checkboxes to show/hide fields

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
- **Integration Points** - Telemetry events, PubSub broadcasts, external APIs

## Always-Visible Fields

These fields appear on every task form, regardless of board settings:

### Basic Information
- **Title** - Task title (required)
- **Description** - Detailed description
- **Type** - Work, Defect, or Goal (required)
- **Parent Goal** - Link to parent goal (if applicable)
- **Priority** - Low, Medium, High, or Critical (required)
- **Assigned To** - User assigned to task
- **Column** - Which column to place the task in (new tasks only)
- **Needs Review** - Whether task requires human review before completion

### Always-Visible Management Fields
- **Dependencies** - Task identifiers that must complete first
- **Actual Metrics** - Actual complexity, files changed, time spent
- **Review Queue** - Review status and review notes

## Conditionally Visible: Status & Agent Tracking

The **Status & Agent Tracking** section is special - it only appears when a task has been interacted with by an AI agent.

### When It Appears

This section is visible when **either** of these conditions is met:
- The task has a value in `created_by_agent` (task was created by an AI agent)
- The task has a value in `completed_by_agent` (task was completed by an AI agent)

### When It's Hidden

For human-created tasks that haven't been completed by an agent, this section is hidden to reduce form clutter.

### Fields in This Section

When visible, the Status & Agent Tracking section includes:
- **Status** - Open, In Progress, Completed, or Blocked
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

1. **Human creates task** → Status & Agent Tracking section is hidden
2. **Agent creates task via API** → Section visible (shows `created_by_agent`)
3. **Human edits agent-created task** → Section remains visible
4. **Agent completes human-created task** → Section becomes visible (shows `completed_by_agent`)

## API Behavior

When creating or updating tasks via the API, all fields are available regardless of board visibility settings:

- Field visibility settings only affect the **UI form**
- API endpoints accept all fields at all times
- This allows agents to populate any field they need

For example, an agent can set `acceptance_criteria` via API even if that field is hidden in the UI form. The data is saved, but won't appear in the form unless the board owner enables that field.

## Updating Field Visibility

When a board owner changes field visibility settings:

1. Changes take effect immediately
2. No data is lost - hidden fields retain their values
3. Hidden fields can be shown again at any time
4. All connected users see the updated form in real-time (via PubSub)

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
