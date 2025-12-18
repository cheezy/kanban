# Epic: Implement AI-Optimized Task System

**Type:** Epic
**Identifier:** E1 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Large (26 hours estimated)
**Created:** 2025-12-17

## Description

Enable the Kanban application to store and manage tasks using the rich format defined in `docs/WIP/TASKS.md`, including 18 categories of task information, key files, verification commands, observability requirements, and completion summaries.

This epic transforms the Kanban application from a simple task tracker into an AI-friendly task management system that can be read and updated by AI agents while remaining useful for human developers.

## Business Value

**Problem Being Solved:**
- Current task schema only stores title/description - insufficient for AI agents to understand and execute tasks
- No way to track AI vs human task creation/completion
- Missing structured format for verification steps, key files, and observability requirements
- No API for AI agents to interact with tasks programmatically

**Expected Benefits:**
- AI agents can create, read, update, and complete tasks with full context
- Developers see rich task details including verification steps and key files
- Clear tracking of who (human or AI) created and completed each task
- Board owners can customize field visibility to avoid information overload
- Structured completion summaries provide audit trail and learning for future tasks

## Features

This epic is organized into 4 features with 13 tasks total. All tasks are flat (no parent/child relationships) but use dependencies to ensure proper execution order.

### Feature 1: Database Schema Foundation

**Goal:** Extend database to store all task metadata

- [ ] **01** - [01-extend-task-schema.md](01-extend-task-schema.md) - **Large** - Add database columns for TASKS.md fields
- [ ] **02** - [02-add-task-metadata-fields.md](02-add-task-metadata-fields.md) - **Medium** - Add lifecycle tracking (created_by, completed_at, status, dependencies)

### Feature 2: Rich Task UI

**Goal:** Build UI for viewing and creating tasks with all new fields

- [ ] **03** - [03-display-rich-task-details.md](03-display-rich-task-details.md) - **Medium** - Display all 18 TASKS.md categories in UI
- [ ] **04** - [04-add-task-creation-form.md](04-add-task-creation-form.md) - **Large** - Comprehensive form with all fields
- [ ] **05** - [05-add-field-visibility-toggles.md](05-add-field-visibility-toggles.md) - **Medium** - Board-level field visibility controls

### Feature 3: AI Agent API

**Goal:** Enable AI agents to interact with tasks via JSON API

- [ ] **06** - [06-create-api-authentication.md](06-create-api-authentication.md) - **Large** - Bearer token authentication for AI agents
- [ ] **07** - [07-implement-task-crud-api.md](07-implement-task-crud-api.md) - **Large** - JSON API endpoints for task CRUD operations
- [ ] **08** - [08-add-task-ready-endpoint.md](08-add-task-ready-endpoint.md) - **Medium** - GET /api/tasks/next and POST /api/tasks/claim with atomic claiming
- [ ] **12** - [12-add-hierarchical-task-tree-endpoint.md](12-add-hierarchical-task-tree-endpoint.md) - **Medium** - GET /api/tasks/:id/tree for epic/feature/task hierarchy
- [ ] **15** - [15-add-agent-info-endpoint.md](15-add-agent-info-endpoint.md) - **Small** - GET /api/agent/info for agent documentation

### Feature 4: Task Management & AI Integration

**Goal:** Add task completion tracking, dependencies, and AI metadata

- [ ] **09** - [09-add-task-completion-tracking.md](09-add-task-completion-tracking.md) - **Medium** - Task completion with detailed summary storage
- [ ] **10** - [10-implement-task-dependencies.md](10-implement-task-dependencies.md) - **Large** - Dependency graph, circular detection, auto-unblocking
- [ ] **11** - [11-add-ai-created-metadata.md](11-add-ai-created-metadata.md) - **Small** - Track AI agent metadata and show badges in UI

## Dependencies

```text
01 → 02 → 03 → 04 → 05
          ↓
          06 → 07 → 08 → 15
          ↓    ↓    ↓
          09 → 10 → 11
               ↓
               12
```

## Total Effort Estimate

- Small: 2 tasks (~2 hours)
- Medium: 6 tasks (~9 hours)
- Large: 5 tasks (~15 hours)

**Total: ~26 hours**

## Implementation Strategy

1. **Phase 1: Database Foundation** (tasks 01-02)
   - Extend task schema with all TASKS.md fields
   - Add metadata for tracking creators and completion
   - Result: Database ready to store rich task data

2. **Phase 2: Rich Task UI** (tasks 03-05)
   - Build UI to display all new fields
   - Create comprehensive task creation form
   - Add board-level field visibility controls
   - Result: Users can view and create rich tasks

3. **Phase 3: AI Agent API** (tasks 06-08, 12, 15)
   - Implement bearer token authentication
   - Build JSON API for task CRUD operations
   - Add atomic claiming endpoint for multi-agent coordination
   - Add hierarchical tree endpoint for task context
   - Add agent documentation endpoint for system guidance
   - Result: AI agents can interact with tasks programmatically

4. **Phase 4: Task Management** (tasks 09-11)
   - Add task completion tracking with summaries
   - Implement dependency graph and auto-unblocking
   - Track AI agent metadata and show badges
   - Result: Full task lifecycle management with AI integration

**Note:** Tasks 13-14 (Agent Workflow Hooks) are documented separately in [IMPROVEMENTS.md](IMPROVEMENTS.md) and [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) as additional features beyond this epic's scope.

## Eating Our Own Dog Food Strategy

**Philosophy:** Use the system we're building to manage its own development starting from task 07 onwards.

### Transition Timeline

- **Tasks 01-06:** Traditional development (manual task management)
- **Task 07:** Create task 08 via POST /api/tasks (**transition point**)
- **Tasks 08-15:** Full API usage (claim, update, complete via API)

### Why This Matters

1. **Validates API works** for real task management workflow
2. **Discovers UX issues** before AI agents encounter them
3. **Proves system ready** for production agent usage
4. **Creates real examples** for documentation
5. **Builds confidence** in the implementation

See [README.md](README.md#eating-our-own-dog-food) for detailed phase-by-phase adoption plan and example API calls.

## Success Criteria

- [ ] All 13 tasks completed successfully
- [ ] All existing tests still pass (no regressions)
- [ ] New tests cover all new functionality
- [ ] Database migrations run cleanly on existing data
- [ ] UI displays rich task fields without information overload
- [ ] API accepts and returns tasks in TASKS.md format
- [ ] AI agents can create, update, and complete tasks via API
- [ ] AI agents can atomically claim tasks without race conditions
- [ ] AI agents can retrieve hierarchical task structure for context
- [ ] Board owners can control field visibility
- [ ] Task dependencies prevent work on blocked tasks
- [ ] Completion summaries provide clear audit trail
- [ ] AI-created tasks clearly marked in UI

## Risks & Mitigations

**Risk:** Database migration might be slow on large datasets
- **Mitigation:** All new columns are nullable, migration adds columns without data transformation

**Risk:** UI might become cluttered with too many fields
- **Mitigation:** Field visibility toggles (task 05) allow board owners to hide fields

**Risk:** API authentication might be complex to implement
- **Mitigation:** Use simple bearer token approach (task 06), similar to GitHub personal access tokens

**Risk:** Dependency graph might have circular dependencies
- **Mitigation:** Circular dependency detection built into task 10

**Risk:** Breaking changes to existing task workflow
- **Mitigation:** All new fields are optional, existing tasks continue to work

## Follow-up Work (Out of Scope)

- AI agent performance analytics dashboard
- Task templates based on TASKS.md format
- Bulk import of tasks from markdown files
- Task cloning with all rich fields
- Advanced dependency visualization (graph view)
- Per-user field visibility overrides
- Task field version history
- Real-time collaboration on task editing
- Task comments/discussions
- File attachment support

## Reference Documentation

- [docs/WIP/TASKS.md](../TASKS.md) - Task format specification
- [docs/WIP/AI-WORKFLOW.md](../AI-WORKFLOW.md) - AI agent workflow and completion format
- [docs/WIP/TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md) - Epic/Feature/Task structure guidelines
- [docs/WIP/UPDATE-TASKS/TASK-ID-GENERATION.md](TASK-ID-GENERATION.md) - Prefixed ID system (E, F, W, D)
