# Goal: Implement AI-Optimized Task System

**Type:** Goal
**Identifier:** G1 (see [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md))
**Status:** Planning
**Complexity:** Large (26 hours estimated)

## Description

Enable the Kanban application to store and manage tasks using the rich format defined in `docs/WIP/TASKS.md`, including 18 categories of task information, key files, verification commands, observability requirements, and completion summaries.

**Important:** Tasks have two types: **Work** (new functionality, enhancements) and **Defect** (bug fixes, corrections). This goal contains Work tasks only.

## Tasks

This goal is organized into 13 tasks total. All tasks are flat (no parent/child relationships) but use dependencies to ensure proper execution order.

### Database Schema Foundation

**Goal:** Extend database to store all task metadata

- [ ] **01A** - [01A-extend-task-schema-scalar-fields.md](01A-extend-task-schema-scalar-fields.md) - **Medium** - Add scalar fields for task metadata (complexity, why, what, where, patterns, etc.)
- [ ] **01B** - [01B-extend-task-schema-jsonb-collections.md](01B-extend-task-schema-jsonb-collections.md) - **Medium** - Add JSONB collections with embedded schemas (key_files, verification_steps, etc.)
- [ ] **02** - [02-add-task-metadata-fields.md](02-add-task-metadata-fields.md) - **Medium** - Add lifecycle tracking (created_by, completed_at, status, dependencies)

### Rich Task UI

**Description:** Build UI for viewing and creating tasks with all new fields

- [ ] **03** - [03-display-rich-task-details.md](03-display-rich-task-details.md) - **Medium** - Display all 18 TASKS.md categories in UI
- [ ] **04** - [04-add-task-creation-form.md](04-add-task-creation-form.md) - **Large** - Comprehensive form with all fields
- [ ] **05** - [05-add-field-visibility-toggles.md](05-add-field-visibility-toggles.md) - **Medium** - Board-level field visibility controls

### AI Agent API

**Description:** Enable AI agents to interact with tasks via JSON API

- [ ] **06** - [06-create-api-authentication.md](06-create-api-authentication.md) - **Large** - Bearer token authentication for AI agents
- [ ] **07** - [07-implement-task-crud-api.md](07-implement-task-crud-api.md) - **Large** - JSON API endpoints for task CRUD operations
- [ ] **08** - [08-add-task-ready-endpoint.md](08-add-task-ready-endpoint.md) - **Medium** - GET /api/tasks/next and POST /api/tasks/claim endpoints with atomic claiming
- [ ] **12** - [12-add-hierarchical-task-tree-endpoint.md](12-add-hierarchical-task-tree-endpoint.md) - **Medium** - GET /api/tasks/:id/tree endpoint for goal/task hierarchy
- [ ] **15** - [15-add-agent-info-endpoint.md](15-add-agent-info-endpoint.md) - **Small** - GET /api/agent/info endpoint for agent documentation

### Task Management & AI Integration

**Description:** Add task completion tracking, dependencies, and AI metadata

- [ ] **09** - [09-add-task-completion-tracking.md](09-add-task-completion-tracking.md) - **Medium** - Task completion with detailed summary storage
- [ ] **10** - [10-implement-task-dependencies.md](10-implement-task-dependencies.md) - **Large** - Dependency graph, circular detection, auto-unblocking
- [ ] **11** - [11-add-ai-created-metadata.md](11-add-ai-created-metadata.md) - **Small** - Track AI agent metadata and show badges in UI

## Dependencies

```text
01A → 01B → 02 → 03 → 04 → 05
                  ↓
                  06 → 07 → 08 → 15
                  ↓    ↓    ↓
                  09 → 10 → 11
                       ↓
                       12
```

## Total Effort Estimate

- Small: 2 tasks (~2 hours)
- Medium: 8 tasks (~15 hours)
- Large: 4 tasks (~12 hours)

### Total: ~29 hours

**Note:** Task 01 was split into 01A (scalar fields) and 01B (JSONB collections) for smaller, more manageable increments.

## Implementation Strategy

1. Start with database schema (tasks 01A-02)
   - 01A: Add scalar fields first for quick validation
   - 01B: Add JSONB collections with embedded schemas
   - 02: Add lifecycle tracking and PubSub broadcasts
2. Build UI immediately to use new fields (tasks 03-05)
3. Add API layer for AI agents (tasks 06-08, 15)
4. Implement task management features (tasks 09-12)

**Note:** Tasks 13-14 (Agent Workflow Hooks) are documented separately in [IMPROVEMENTS.md](IMPROVEMENTS.md) and [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) as additional features beyond this goal's scope.

## Eating Our Own Dog Food

**Philosophy:** Start using the system we're building as soon as each feature becomes available.

### Phase-by-Phase Adoption

#### Phase 1-2 (Tasks 01-05): Manual/UI Entry

- Tasks created and managed via UI
- Use existing kanban board functionality
- Manual status updates and tracking

#### Phase 3 (Tasks 06-08): API Transition

- Task 06: Create API token for yourself
- Task 07: **START HERE** - Use POST /api/tasks to create task 08
- Task 08: Use POST /api/tasks/claim to claim remaining tasks

#### Phase 3-4 (Tasks 09-15): Full API Usage

- All tasks created via POST /api/tasks
- All claims via POST /api/tasks/claim
- All updates via PATCH /api/tasks/:id
- Verify GET /api/tasks/next returns correct task
- Test unclaim if you get blocked
- Use GET /api/agent/info for guidance

### Benefits

1. **Real-World Testing**: Find API issues immediately
2. **Dogfooding**: Experience what AI agents will experience
3. **Feedback Loop**: Fix UX problems before agents encounter them
4. **Validation**: Proves the system works end-to-end
5. **Documentation**: Creates real examples for other agents

### Transition Point

**After Task 07 completes**, the system is ready for API-first workflow. Create a script or use curl/httpie for remaining tasks.

**Example:**

```bash
# Create task 09
curl -X POST http://localhost:4000/api/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Add task completion tracking",
    "complexity": "medium",
    "type": "work",
    "dependencies": [7, 8]
  }'

# Claim next task
curl -X POST http://localhost:4000/api/tasks/claim \
  -H "Authorization: Bearer $TOKEN"
```

## Key Documentation

### Core Specifications

- **[TASK-ID-GENERATION.md](TASK-ID-GENERATION.md)** - Prefixed ID system (G=Goal, W=Work, D=Defect)
- [docs/WIP/TASKS.md](../TASKS.md) - Task format specification
- [docs/WIP/TASK-BREAKDOWN.md](../TASK-BREAKDOWN.md) - Goal/Task structure guidelines
- [docs/WIP/AI-WORKFLOW.md](../AI-WORKFLOW.md) - AI agent workflow and completion format

### Feature Improvements

- [IMPROVEMENTS.md](IMPROVEMENTS.md) - System improvements (#1-10) and agent workflow hooks
- [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) - Agent configuration and workflow hook system
- [PUBSUB-REALTIME-UPDATES.md](PUBSUB-REALTIME-UPDATES.md) - Real-time UI updates via PubSub
- [NEEDS-REVIEW-FEATURE-SUMMARY.md](NEEDS-REVIEW-FEATURE-SUMMARY.md) - Optional human review flag

### Implementation Summaries

- [TIMEOUT-IMPLEMENTATION-SUMMARY.md](TIMEOUT-IMPLEMENTATION-SUMMARY.md) - Task claiming timeout (60 min)
- [CAPABILITY-MATCHING-IMPLEMENTATION-SUMMARY.md](CAPABILITY-MATCHING-IMPLEMENTATION-SUMMARY.md) - Agent capability matching
- [ESTIMATION-FEEDBACK-IMPLEMENTATION-SUMMARY.md](ESTIMATION-FEEDBACK-IMPLEMENTATION-SUMMARY.md) - Work estimation feedback loop
- [UNCLAIM-IMPLEMENTATION-SUMMARY.md](UNCLAIM-IMPLEMENTATION-SUMMARY.md) - Task unclaim mechanism
- [AGENT-HOOKS-IMPLEMENTATION-SUMMARY.md](AGENT-HOOKS-IMPLEMENTATION-SUMMARY.md) - Workflow hooks for agents
