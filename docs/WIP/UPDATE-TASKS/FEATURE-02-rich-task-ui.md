# Feature 2: Rich Task UI

**Epic:** [EPIC-ai-optimized-task-system.md](EPIC-ai-optimized-task-system.md)
**Type:** Feature
**Identifier:** F2 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Large (7.5 hours estimated)

## Description

Build user interface components to display and create tasks with all the rich fields from the extended schema. Users need to see task complexity, key files, verification steps, dependencies, and other metadata in an organized, readable format. Board owners need control over which fields are visible to prevent information overload.

## Goal

By the end of this feature, users can view task details with all 18 TASKS.md categories beautifully displayed, create new tasks with comprehensive forms, and board owners can toggle field visibility for their boards.

## Business Value

**Why This Matters:**
- Makes rich task data accessible to human users
- Prevents information overload through field visibility controls
- Enables users to create fully-specified tasks without AI assistance
- Improves task clarity with structured display of verification steps and key files

**What Changes:**
- Task detail modal shows all rich fields in organized sections
- Task creation form includes inputs for all new fields
- Board settings include field visibility checkboxes (owner only)
- Field visibility changes broadcast to all users in real-time
- Task cards show AI badges for AI-created tasks

## Tasks

- [ ] **03** - [03-display-rich-task-details.md](03-display-rich-task-details.md) - **Medium** (1.5 hours)
  - Create TaskDetailComponent with all field sections
  - Display key files, verification steps, dependencies
  - Show completion summary for completed tasks
  - Handle nil values gracefully

- [ ] **04** - [04-add-task-creation-form.md](04-add-task-creation-form.md) - **Large** (5 hours)
  - Build comprehensive form with all fields
  - Multi-step form or collapsible sections
  - Field-specific inputs (dropdowns for complexity, text areas for collections)
  - Client-side validation

- [ ] **05** - [05-add-field-visibility-toggles.md](05-add-field-visibility-toggles.md) - **Medium** (1.5 hours)
  - Add field_visibility JSONB column to boards table
  - Owner-only settings panel in board UI
  - Real-time broadcast of visibility changes via PubSub
  - Default: show acceptance criteria, hide everything else

## Dependencies

**Requires:** Feature 1 (Database Schema Foundation)
**Blocks:** None (can work in parallel with Feature 3)

## Acceptance Criteria

- [ ] Task detail view displays all 18 TASKS.md field categories
- [ ] Key files shown as clickable file paths
- [ ] Verification steps displayed as checklists
- [ ] Dependencies shown as links to other tasks
- [ ] Complexity badge prominently displayed
- [ ] Pitfalls and out-of-scope clearly marked with icons
- [ ] Task creation form includes all new fields
- [ ] Form validation prevents invalid data
- [ ] Board owners can toggle field visibility
- [ ] Non-owners see fields but cannot change settings
- [ ] Field visibility changes update all clients in real-time
- [ ] Settings persist in database (not localStorage)
- [ ] UI remains responsive on mobile
- [ ] No layout breaks with long text/many items

## Technical Approach

**UI Components:**
- TaskDetailComponent (LiveView component)
- TaskFormComponent (LiveView form)
- FieldVisibilityPanel (owner-only controls)
- Reusable field section components

**LiveView Integration:**
- Subscribe to PubSub for field visibility changes
- Handle real-time updates without page refresh
- Optimize rendering with :if conditions

**Field Visibility Storage:**
- JSONB column in boards table
- Default: {"acceptance_criteria": true, all others: false}
- Validation ensures all keys present
- Broadcast changes on "board:#{board_id}" topic

**Form Design:**
- Collapsible sections to reduce visual clutter
- Smart defaults (e.g., complexity dropdown)
- Helper text explaining each field
- Multi-line text areas for collections

## Success Metrics

- [ ] Task detail modal loads < 200ms
- [ ] All fields render correctly with sample data
- [ ] Form validation catches invalid input
- [ ] Field visibility updates < 100ms across clients
- [ ] No console errors or warnings
- [ ] Accessibility score 90+ (screen reader, keyboard nav)
- [ ] Works on mobile (320px width)

## Verification Steps

```bash
# Start server
mix phx.server

# Manual testing checklist
# 1. Create task with rich fields
# 2. View task detail - verify all sections show
# 3. Create task with minimal fields - verify nil handling
# 4. As board owner, toggle field visibility
# 5. Open board in second browser - verify real-time update
# 6. As non-owner, verify cannot change settings
# 7. Test on mobile viewport
# 8. Test with screen reader

# Run tests
mix test test/kanban_web/live/board_live_test.exs
mix precommit
```

## UI Mockup Sections

**Task Detail Modal:**
1. Header: Title, complexity badge, estimated files
2. Context: Why/What/Where
3. Key Files: Clickable file paths with notes
4. Verification: Command/manual steps with expected results
5. Technical Notes: Patterns, database changes
6. Observability: Telemetry, metrics, logging
7. Error Handling: User messages, failure behavior
8. Dependencies: Links to blocking tasks
9. Pitfalls: Warning icons with descriptions
10. Out of Scope: X icons with items
11. Completion Summary: Files changed, verification results (if completed)

**Field Visibility Panel:**
- Checkboxes in 2-3 column grid
- Only visible to board owner
- Hover shows field description
- Real-time updates as you toggle

## Out of Scope

- Inline editing of task fields (view only)
- Task activity history/timeline
- Task comments/discussions
- File preview/syntax highlighting
- Drag-and-drop reordering of collections
- Copy-to-clipboard for verification commands
- Per-user visibility overrides (board-level only)
- Visibility presets (Developer view, Manager view)
