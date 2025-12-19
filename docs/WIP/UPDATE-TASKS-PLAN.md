# Example Task: Update Project Tasks to New AI-Optimized Format

This is a **demonstration task** showing how to use the TASKS.md format for planning work. It describes the task of converting this project's existing tasks (from PLAN.md and other sources) to the new AI-optimized format.

**Important:** This file serves as an overview and example. The actual individual tasks have been broken down into separate files in the [UPDATE-TASKS/](UPDATE-TASKS/) directory.

**See:** [UPDATE-TASKS/README.md](UPDATE-TASKS/README.md) for the complete list of individual tasks with dependencies and status.

## Recent Enhancements

The implementation plan has been enhanced with several key improvements:

1. **JSONB Collections** (Task 01B) - Using PostgreSQL JSONB with embedded schemas instead of pipe-delimited text for collections like key_files and verification_steps
2. **API Authentication** (Task 06) - Comprehensive Bearer token system with scopes and capability matching
3. **PubSub Broadcasts** (Task 02) - Real-time updates for all task lifecycle events with telemetry integration
4. **API Integration Tests** (Task 02) - 27 comprehensive tests covering authentication, authorization, lifecycle events, and capability matching
5. **Data Migration Strategy** (Task 02) - Backward compatibility for existing tasks with intelligent status inference

---

## Update Project Documentation to Use AI-Optimized Task Format

**Complexity:** Medium | **Est. Files:** 3-5

### Description

**WHY:** The current task documentation in PLAN.md uses simple checklists. The new TASKS.md format provides 18 categories of structured information that dramatically improves AI's ability to execute tasks efficiently without exploration.

**WHAT:** Convert existing tasks from PLAN.md to the new TASKS.md format, creating individual task files with rich context including key files, verification commands, observability requirements, and completion workflows.

**WHERE:**
- Current tasks: `PLAN.md` (simple checklist format)
- New location: `docs/tasks/` directory (one .md file per task)
- Template source: `docs/WIP/TASKS.md`

### Acceptance Criteria

- [ ] Create `docs/tasks/` directory structure
- [ ] Extract all incomplete tasks from PLAN.md
- [ ] Convert each task to TASKS.md format with all 18 categories filled out
- [ ] Include "Key Files to Read First" for each task (eliminates exploration)
- [ ] Add verification commands and manual testing steps
- [ ] Specify observability requirements (telemetry events needed)
- [ ] Create index file linking all tasks
- [ ] Update PLAN.md to reference new task location
- [ ] Document completion summary format for each task type

### Key Files to Read First

- `PLAN.md` - Current task list (simple checklist format)
- `docs/WIP/TASKS.md` - New task template and format specification
- `lib/kanban/boards.ex` - Context module (understand current architecture)
- `lib/kanban/tasks.ex` - Task context module
- `lib/kanban_web/telemetry.ex` - Telemetry setup (for observability requirements)

### Technical Notes

**Patterns to Follow:**
- Use the exact template from `docs/WIP/TASKS.md` (lines 110-202)
- One markdown file per task in `docs/tasks/` directory
- Filename convention: `{category}-{short-description}.md` (e.g., `feature-add-task-priority.md`)
- Always include "Key Files to Read First" section - this is critical for AI efficiency

**Database/Schema:**
- Tables: None (documentation only)
- Migrations needed: No

**Integration Points:**
- [ ] PubSub broadcasts: Not applicable (documentation task)
- [ ] Phoenix Channels: Not applicable
- [ ] External APIs: Not applicable

**Directory Structure:**
```
docs/
├── tasks/
│   ├── README.md                          # Index of all tasks
│   ├── feature-add-task-priority.md       # Example: Add priority field
│   ├── feature-add-task-labels.md         # Example: Add label system
│   ├── enhancement-telemetry-events.md    # Add more telemetry
│   └── refactor-task-context.md           # Refactor example
└── WIP/
    └── TASKS.md                            # Template source
```

### Verification

**Commands to Run:**
```bash
# Verify all task files are valid markdown
find docs/tasks -name "*.md" -exec npx markdownlint {} \;

# Count tasks converted
ls -1 docs/tasks/*.md | wc -l

# Verify template compliance (check for required sections)
grep -l "### Key Files to Read First" docs/tasks/*.md
grep -l "### Verification" docs/tasks/*.md
grep -l "### Observability" docs/tasks/*.md
```

**Manual Testing:**
1. Open `docs/tasks/README.md` and verify all tasks are linked
2. Pick a random task file and verify it has all 18 categories
3. Check that "Key Files to Read First" actually lists relevant files
4. Verify verification commands are copy-paste ready
5. Confirm observability section specifies telemetry events or "none"

**Success Looks Like:**
- Directory `docs/tasks/` exists with 10+ task files
- Each task file follows TASKS.md template structure
- README.md provides clear index and status of all tasks
- Each task includes specific file paths AI should read
- Each task has concrete verification steps
- PLAN.md references new location with explanation

### Data Examples

**Before (PLAN.md format):**
```markdown
### 4. Task Management

- [ ] Create tasks within columns
- [ ] Edit task details (title, description)
- [ ] Delete tasks
- [ ] Move tasks between columns
- [ ] Reorder tasks within a column
```

**After (docs/tasks/feature-add-task-reordering.md):**
```markdown
## Add drag-and-drop task reordering within columns

**Complexity:** Medium | **Est. Files:** 3-4

### Description

**WHY:** Users need to prioritize tasks by reordering them within a column
**WHAT:** Implement drag-and-drop reordering of tasks within a single column
**WHERE:** Board LiveView, task cards

### Key Files to Read First

- `lib/kanban_web/live/board_live.ex` - Main board LiveView (lines 120-150 for task rendering)
- `lib/kanban/tasks.ex` - Task context module (add reorder_tasks/2 function)
- `lib/kanban/schemas/task.ex` - Task schema (check position field exists)
- `assets/js/hooks/sortable.js` - Existing drag-drop code (reference implementation)

### Verification

**Commands to Run:**
```bash
mix test test/kanban/tasks_test.exs
mix test test/kanban_web/live/board_live_test.exs
mix precommit
```

**Manual Testing:**
1. Navigate to board with multiple tasks in a column
2. Drag task from position 1 to position 3
3. Verify task order updates immediately
4. Refresh page - verify order persists
5. Check other users see updated order in real-time

### Observability

- [ ] Telemetry event: `[:kanban, :task, :reordered]`
- [ ] Metrics: Counter of reorder operations
- [ ] Logging: Log reorder events at info level with task_id and new_position
```

### Observability

- [ ] Telemetry event: Not applicable (documentation task)
- [ ] Metrics: Track number of tasks converted (manual count)
- [ ] Logging: No logging needed

### Error Handling

- User sees: Not applicable (offline documentation work)
- On failure: N/A
- Validation: Verify markdown files parse correctly, all required sections present

### Common Pitfalls

- [ ] Don't forget to actually identify the specific files and line numbers for "Key Files to Read First"
- [ ] Remember to specify exact verification commands (not vague like "test it")
- [ ] Avoid leaving observability section empty - explicitly state "none needed" or specify events
- [ ] Don't skip the "Common Pitfalls" section - it's valuable AI guidance
- [ ] Remember task complexity estimates help AI decide whether to plan first
- [ ] Don't use generic placeholders - be specific (actual file paths, actual commands)

### Dependencies

**Requires:** None - this is a documentation task
**Blocks:** None - can be done independently

### Out of Scope

- Don't implement any code changes (this is documentation only)
- Don't modify the TASKS.md template itself (it's the reference)
- Don't create tasks for already-completed work from PLAN.md
- Don't create Beads integration yet (future work)

---

## Task Conversion Reference

### Categories from Current PLAN.md

Based on PLAN.md analysis, here are the task categories to convert:

#### Phase 1: Foundation (Already Complete ✓)
- Skip these - already done per PLAN.md status

#### Phase 2-7: Remaining Work
Convert these into individual task files:

1. **Feature Tasks**
   - Task priority system
   - Task labels/tags
   - Task due dates
   - Task assignments
   - Task comments
   - Board templates

2. **Enhancement Tasks**
   - Additional telemetry events
   - Performance optimizations
   - Accessibility improvements
   - Mobile responsiveness

3. **Refactoring Tasks**
   - Extract reusable components
   - Improve test coverage
   - Code organization

4. **Documentation Tasks**
   - API documentation
   - User guide
   - Developer setup guide

### Mapping PLAN.md to TASKS.md Format

For each uncompleted item in PLAN.md:

1. **Title:** Convert checkbox text to action-oriented title
   - Before: `- [ ] Create tasks within columns`
   - After: `Add task creation within board columns`

2. **Complexity:** Estimate based on scope
   - Simple CRUD: Small
   - Multiple files + tests: Medium
   - Architecture changes: Large

3. **Key Files:** Identify from codebase structure
   - Look at existing similar features
   - Trace through LiveView → Context → Schema
   - Note test file locations

4. **Verification:** Specify exact commands
   - Always include `mix test` with specific test file
   - Always include `mix precommit`
   - Add manual testing steps for UI changes

5. **Observability:** Check telemetry.ex
   - Pattern: `[:kanban, :domain, :action]`
   - Existing: user.registration, user.login, board.creation, task.creation
   - Add similar events for new features

6. **Common Pitfalls:** Extract from experience
   - Check for N+1 queries
   - Remember PubSub broadcasts for real-time updates
   - Don't forget to update both contexts and LiveViews

### Example Conversion Workflow

**Step 1:** Pick task from PLAN.md
```markdown
- [ ] Add task priority field
```

**Step 2:** Research codebase
- Read `lib/kanban/schemas/task.ex` - see current fields
- Read `lib/kanban/tasks.ex` - see CRUD functions
- Read `lib/kanban_web/live/board_live.ex` - see task display
- Check `lib/kanban_web/telemetry.ex` - see telemetry pattern

**Step 3:** Create task file `docs/tasks/feature-add-task-priority.md`
- Use TASKS.md template
- Fill in all 18 categories with specific information
- Include actual file paths from Step 2
- Specify exact test commands
- Define telemetry event following existing pattern

**Step 4:** Add to README.md index
```markdown
## Open Tasks

### Features
- [Add task priority field](feature-add-task-priority.md) - Medium - Adds 0-4 priority system
```

---

## Benefits of This Format

### For AI Task Creation
- AI can generate properly structured tasks during planning
- Template ensures no critical information is missed
- Consistent format across all tasks

### For AI Task Execution
- **"Key Files to Read First"** eliminates exploration phase (huge time savings)
- **Verification commands** provide unambiguous "done" criteria
- **Observability requirements** ensure telemetry is added upfront
- **Common Pitfalls** prevent known mistakes
- **Data Examples** show exact input/output formats

### For Human Review
- Quick scan shows complexity and scope
- Verification section shows exactly how to test
- Dependencies show task ordering
- Out of scope prevents scope creep

### For Post-Completion
- Completion summary format provides audit trail
- Deviations from plan improve future task creation
- Follow-up tasks are explicitly tracked

---

## Next Steps After Conversion

1. **Trial Run:** Pick one task and execute it using the new format
2. **Measure:** Compare execution time vs. old format
3. **Iterate:** Refine template based on what worked/didn't work
4. **Scale:** Convert remaining tasks
5. **Integrate:** Build Beads integration for task management
6. **Automate:** AI can auto-generate tasks in this format during planning

---

## Meta Note

This document itself demonstrates the TASKS.md format! Notice how it includes:
- ✅ Clear WHY/WHAT/WHERE description
- ✅ Specific file paths to read
- ✅ Exact verification commands
- ✅ Data examples (before/after task formats)
- ✅ Common pitfalls specific to this task
- ✅ Out of scope boundaries

When AI receives a task in this format, it can execute immediately without asking clarifying questions or exploring the codebase blindly.
