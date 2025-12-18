# AI-Optimized Kanban System - Work in Progress Docs

This directory contains planning documents for making the Kanban system work seamlessly with AI agents.

## Core Documents

### [TASKS.md](TASKS.md) - **START HERE**
The definitive guide for task structure that AI can both create and execute.

**Contains:**
- 18 categories of essential information for implementation
- Copy-paste ready template for creating tasks
- Completion summary format for updating tasks after work is done
- Full lifecycle: creation → execution → completion

**Key Innovation:** The "Related Code Locations" section eliminates exploration time - AI can jump straight to the right files.

**Use this when:** Creating any task, whether manually or via AI

## Integration Documents

### [AI-WORKFLOW.md](AI-WORKFLOW.md)
How AI interacts with the Kanban system throughout the development lifecycle.

**Workflow:**
1. AI explores codebase
2. Creates tasks using TASKS.md template
3. POSTs to `/api/tasks` endpoint
4. GETs `/api/tasks/ready` to find unblocked work
5. Claims task (PATCH status=in_progress)
6. Implements
7. Updates with completion summary
8. Marks complete (PATCH status=completed)

**Key Feature:** Completion updates include actual implementation details, deviations from plan, and follow-up tasks created.

### [API-FORMAT.md](API-FORMAT.md)
JSON structure for the AI workflow API.

**Recommendation:** Use structured JSON based on TASKS.md template for maximum AI efficiency.

**Includes:**
- Full JSON schema matching TASKS.md structure
- Completion payload format
- Batch creation endpoint design

### [TASK-BREAKDOWN.md](TASK-BREAKDOWN.md)
Flat tasks vs. hierarchical subtasks - which to implement?

**Recommendation:** Start with flat tasks + dependencies, add subtasks in v2

**Integration:** When creating tasks (flat or hierarchical), use the TASKS.md template structure in JSON format.

### [AI-AUTHENTICATION.md](AI-AUTHENTICATION.md)
How AI agents authenticate to the API.

### [UI-INTEGRATION.md](UI-INTEGRATION.md)
How the Kanban UI displays AI-created vs. human-created tasks.

### [RICH-CONTENT.md](RICH-CONTENT.md)
Deep dive into structured JSON for technical context. Provides a comprehensive JSON schema for tasks with granular fields for files, modules, database changes, testing, patterns, etc.

**Relationship to TASKS.md:** TASKS.md is the practical, production-ready template. RICH-CONTENT.md provides the full schema if you need more detailed structure later.

## How These Docs Fit Together

```
TASKS.md (Core Template)
    ├── Defines structure for ALL tasks
    ├── 18 categories of information
    ├── Template for creation
    └── Format for completion updates

API-FORMAT.md
    └── JSON representation of TASKS.md template

AI-WORKFLOW.md
    ├── Uses TASKS.md structure for task creation
    └── Uses completion format for task updates

TASK-BREAKDOWN.md
    └── Whether flat or hierarchical, uses TASKS.md structure
```

## Quick Start: Creating AI-Friendly Tasks

1. **Read** [TASKS.md](TASKS.md) to understand the template
2. **Copy** the template from TASKS.md
3. **Fill out** as many sections as possible (especially "Key Files to Read First")
4. **Store** in your task system (Beads, GitHub Issues, etc.)
5. **Convert to JSON** using [API-FORMAT.md](API-FORMAT.md) structure if using the API

## Quick Start: AI Completing Tasks

1. **Read** the task (ideally created with TASKS.md template)
2. **Start with** "Key Files to Read First" section
3. **Implement** following patterns specified
4. **Run** verification commands exactly as listed
5. **Update** task with completion summary (see TASKS.md completion format)
6. **Mark complete** with all completion data

## Key Benefits of This System

### For Task Creation
- **Less exploration needed** - key files listed upfront
- **Clear success criteria** - exact verification commands
- **Unambiguous scope** - what's in/out explicitly stated

### For Task Execution
- **Faster implementation** - no time wasted searching for files
- **Correct verification** - knows exactly what commands to run
- **Proper observability** - knows which telemetry events to add

### For Task Completion
- **Audit trail** - what actually changed vs. planned
- **Knowledge transfer** - future work references actual implementation
- **Continuous improvement** - deviations inform future task creation

## Next Steps

1. Implement the API endpoints described in AI-WORKFLOW.md
2. Add task schema fields for the structured data in TASKS.md
3. Build the Kanban UI to display the rich task information
4. Integrate with AI workflow for real-time task creation and updates

## Questions?

See the individual documents for detailed discussions and recommendations. Each document explores a specific aspect of the AI-optimized task system.
