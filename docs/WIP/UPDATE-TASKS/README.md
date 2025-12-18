# Epic: Implement AI-Optimized Task System

**Type:** Epic
**Status:** Planning
**Complexity:** Large (25 hours estimated)

## Description

Enable the Kanban application to store and manage tasks using the rich format defined in `docs/WIP/TASKS.md`, including 18 categories of task information, key files, verification commands, observability requirements, and completion summaries.

## Features & Tasks

This epic is organized into 4 features with 12 tasks total. All tasks are flat (no parent/child relationships) but use dependencies to ensure proper execution order.

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
- [ ] **08** - [08-add-task-ready-endpoint.md](08-add-task-ready-endpoint.md) - **Medium** - GET /api/tasks/next and POST /api/tasks/claim endpoints with atomic claiming
- [ ] **12** - [12-add-hierarchical-task-tree-endpoint.md](12-add-hierarchical-task-tree-endpoint.md) - **Medium** - GET /api/tasks/:id/tree endpoint for epic/feature/task hierarchy

### Feature 4: Task Management & AI Integration
**Goal:** Add task completion tracking, dependencies, and AI metadata

- [ ] **09** - [09-add-task-completion-tracking.md](09-add-task-completion-tracking.md) - **Medium** - Task completion with detailed summary storage
- [ ] **10** - [10-implement-task-dependencies.md](10-implement-task-dependencies.md) - **Large** - Dependency graph, circular detection, auto-unblocking
- [ ] **11** - [11-add-ai-created-metadata.md](11-add-ai-created-metadata.md) - **Small** - Track AI agent metadata and show badges in UI

## Dependencies

```
01 → 02 → 03 → 04 → 05
          ↓
          06 → 07 → 08
          ↓    ↓    ↓
          09 → 10 → 11
               ↓
               12
```

## Total Effort Estimate

- Small: 1 task (~1 hour)
- Medium: 6 tasks (~9 hours)
- Large: 5 tasks (~15 hours)

**Total: ~25 hours**

## Implementation Strategy

1. Start with database schema (tasks 01-02)
2. Build UI immediately to use new fields (tasks 03-05)
3. Add API layer for AI agents (tasks 06-08)
4. Implement task management features (tasks 09-11)
