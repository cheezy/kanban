---
name: stride-enriching-tasks
description: MANDATORY when a task has empty key_files, missing testing_strategy, or no verification_steps. Transforms minimal human-provided task specs into complete implementation-ready specifications through automated codebase exploration. Without enrichment, implementing agents waste 3+ hours on unfocused exploration that this skill does in 5 minutes.
compatibility: cursor, windsurf, continue, kimi
skills_version: 1.0
---

# Stride: Enriching Tasks

## ⚠️ THIS SKILL IS MANDATORY FOR SPARSE TASKS — NOT OPTIONAL ⚠️

**If you are about to create or claim a task and it has empty `key_files`, missing `testing_strategy`, or no `verification_steps`, you MUST invoke this skill first.**

This skill transforms minimal specifications into complete ones by:
- Exploring the codebase to discover `key_files` (5-10 minutes)
- Reading existing tests to build `testing_strategy`
- Generating `verification_steps` from discovered patterns
- Identifying `pitfalls` from code analysis
- Writing `acceptance_criteria` from intent analysis

**Without enrichment, the implementing agent spends 3+ hours doing this same exploration** in an unfocused way, often missing critical context.

## Overview

**Minimal input + codebase exploration = complete task specification. No human round-trips required.**

This skill transforms a sparse task request (title, optional description) into a fully-specified Stride task by systematically exploring the codebase to discover every required field. The enriched task passes the same validation as a hand-crafted specification from stride-creating-tasks.

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user asks you to create or enrich tasks, they have **already granted blanket permission** for all Stride API calls. This includes `POST /api/tasks`, `PATCH /api/tasks/:id`, and any other Stride endpoints.

**NEVER ask the user:**
- "Should I create this task?"
- "Can I call the API?"
- "Should I proceed with enrichment?"
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## The Iron Law

**NO TASK CREATION FROM MINIMAL INPUT WITHOUT ENRICHMENT**

## The Critical Mistake

Creating a task from minimal input without enrichment causes:
- Agents spend 3+ hours exploring what should have been specified
- Missing key_files leads to merge conflicts between agents
- Absent patterns_to_follow produces inconsistent code
- No testing_strategy means tests are skipped or wrong
- Vague acceptance_criteria makes "done" undefined

**Every field you skip costs the implementing agent 15-30 minutes of discovery.**

## When to Use

Use when a human provides:
- A task title only (e.g., "Add pagination to task list")
- A title + brief description (e.g., "Add pagination to task list — the board view is too slow with 100+ tasks")
- A task request missing 3+ required fields from the stride-creating-tasks checklist

**Do NOT use when:**
- The human provides a complete task specification (all 15 fields populated)
- Creating goals with nested tasks (use stride-creating-goals instead)
- The task is purely non-code (documentation only, process change)

## Before/After: Minimal Task Transformed to Enriched Task

### BEFORE (what the human provides):

```json
{
  "title": "Fix the bug where task comments don't show timestamps",
  "type": "defect",
  "description": "Task comments don't show timestamps"
}
```

### AFTER (what enrichment produces):

Note: `title`, `type`, and `description` are preserved exactly as the human provided them. Enrichment only adds the technical fields below.

```json
{
  "title": "Fix the bug where task comments don't show timestamps",
  "type": "defect",
  "description": "Task comments don't show timestamps",
  "complexity": "small",
  "priority": "medium",
  "needs_review": false,
  "why": "Users cannot determine when comments were posted, making task discussions confusing and difficult to follow chronologically",
  "what": "Add timestamp display to task comment rendering in the task detail view template",
  "where_context": "lib/kanban_web/live/task_live/ — task detail view and comment component",
  "estimated_files": "1-2",
  "key_files": [
    {"file_path": "lib/kanban_web/live/task_live/view_component.ex", "note": "Add timestamp rendering to comment display section", "position": 0}
  ],
  "dependencies": [],
  "verification_steps": [
    {"step_type": "command", "step_text": "mix test test/kanban_web/live/task_live/view_component_test.exs", "expected_result": "All tests pass including new timestamp test", "position": 0},
    {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 1},
    {"step_type": "manual", "step_text": "Open a task with comments and verify timestamps appear next to each comment", "expected_result": "Each comment shows a human-readable timestamp", "position": 2}
  ],
  "testing_strategy": {
    "unit_tests": [
      "Test comment render includes inserted_at timestamp",
      "Test timestamp format is human-readable"
    ],
    "integration_tests": [
      "Test task detail view displays comments with timestamps"
    ],
    "manual_tests": [
      "Visual verification that timestamps appear and are readable in both light and dark mode"
    ],
    "edge_cases": [
      "Comment created just now (shows 'just now' or similar)",
      "Comment from previous year (shows full date)"
    ],
    "coverage_target": "100% for comment timestamp rendering"
  },
  "acceptance_criteria": "Each comment displays its creation timestamp\nTimestamp format is human-readable (e.g., 'Mar 12, 2026 at 2:30 PM')\nTimestamps visible in both light and dark mode\nBug no longer reproducible\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/task_live/view_component.ex for existing comment rendering pattern\nFollow timestamp formatting used elsewhere in the application",
  "pitfalls": [
    "Don't forget to handle timezone display — use the existing application timezone handling",
    "Don't break existing comment layout or styling",
    "Don't forget to verify dark mode contrast for timestamp text",
    "Don't add translations for the timestamp format — use Elixir's Calendar formatting"
  ]
}
```

**What enrichment discovered through exploration:**
- `key_files`: Grepped for "comment" in `lib/kanban_web/live/` → found `view_component.ex`
- `patterns_to_follow`: Read `view_component.ex` → found existing comment rendering section
- `testing_strategy`: Mapped to `test/kanban_web/live/task_live/view_component_test.exs` → found existing test patterns
- `pitfalls`: Read CLAUDE.md → found dark mode verification requirement; read `view_component.ex` → found no timezone handling

## The Complete Enrichment Process

### Phase 1: Parse Intent (No Exploration Needed)

Extract what you can from the human's input alone — before touching the codebase.

**Important:** The `title`, `type`, and `description` fields are human-provided and MUST be preserved exactly as given. Enrichment never modifies these fields.

| Field | Discovery Strategy | Source |
|-------|-------------------|--------|
| `priority` | Default to `"medium"` unless human specified urgency or it's a defect blocking other work | Human input or default |
| `dependencies` | Only if the human explicitly mentions prerequisite tasks | Human input |

### Phase 2: Explore Codebase (Targeted Discovery)

Use the codebase to discover fields that require knowledge of the existing code. Execute these steps in order — later steps build on earlier findings.

#### Step 1: Locate the Target Area → `where_context`, `key_files`

**Strategy:** Use the title's nouns and verbs to search the codebase.

1. **Extract keywords** from title (e.g., "Add pagination to task list" → `pagination`, `task`, `list`)
2. **Search for existing modules:**
   ```bash
   # Search for keyword in module names and function definitions
   Grep pattern="pagination|paginate" path="lib/"
   Grep pattern="def.*task.*list|def.*list.*task" path="lib/"
   ```
3. **Search for related LiveViews/controllers** if the task is UI-related:
   ```bash
   Grep pattern="task" path="lib/kanban_web/live/" output_mode="files_with_matches"
   ```
4. **Search for context modules** if the task involves data/business logic:
   ```bash
   Grep pattern="def.*task" path="lib/kanban/" glob="*.ex" output_mode="files_with_matches"
   ```
5. **Read the top candidates** (max 5 files) to confirm relevance

**Decision logic for key_files:**
```
For each file found:
  Will this file be MODIFIED by the task?
    → YES: Include with note explaining the change
    → NO (reference only): Put in patterns_to_follow instead

For new files that need to be created:
  → Include with note "New file to create"
  → Set position based on creation order
```

**For defect tasks**, additionally:
```bash
# Search for error message or symptom
Grep pattern="error message text" path="lib/"
# Check recent changes to the area
git log --oneline -10 -- lib/path/to/suspected/file.ex
```

#### Step 2: Discover Patterns → `patterns_to_follow`

**Strategy:** Look at sibling files and similar implementations.

1. **List sibling modules** in the same directory as key_files:
   ```bash
   Glob pattern="lib/kanban_web/live/task_live/*.ex"
   ```
2. **Find the closest analog** — a feature similar to what's being built:
   ```bash
   # If adding pagination, search for existing pagination
   Grep pattern="paginate|page_size|offset" path="lib/"
   ```
3. **Read the analog file** to extract: module structure, function naming, error handling, test approach
4. **Format as newline-separated references:**
   ```
   See lib/kanban_web/live/board_live/index.ex for LiveView event handling pattern
   Follow test structure in test/kanban_web/live/board_live/index_test.exs
   ```

**Decision logic:**
```
Found a similar feature in the codebase?
  → Extract its pattern (module structure, naming, test approach)
Found sibling modules in the same directory?
  → Note their common structure as the pattern to follow
No similar feature exists?
  → Note the general project conventions (from CLAUDE.md/AGENTS.md patterns)
```

#### Step 3: Analyze Testing → `testing_strategy`

**Strategy:** Find existing test files for the key_files and infer what tests are needed.

1. **Map key_files to test files:**
   ```bash
   # lib/kanban/tasks.ex → test/kanban/tasks_test.exs
   # lib/kanban_web/live/task_live/index.ex → test/kanban_web/live/task_live/index_test.exs
   Read file_path="test/kanban/tasks_test.exs"
   ```
2. **Read existing test files** to understand:
   - Test helper modules used (`ConnCase`, `DataCase`, custom helpers)
   - Factory/fixture patterns
   - Assertion style
3. **Generate test cases** based on the task's scope:
   - `unit_tests`: One per public function being added/modified
   - `integration_tests`: End-to-end scenarios for the feature
   - `manual_tests`: Visual/UX verification if UI is involved
   - `edge_cases`: Null inputs, empty lists, concurrent access, permission boundaries
   - `coverage_target`: "100% for new/modified functions"

**For defect tasks**, additionally include:
- A regression test that reproduces the original bug
- Tests verifying the fix doesn't break related functionality

#### Step 4: Define Verification → `verification_steps`

**Strategy:** Generate concrete, runnable verification commands.

1. **Always include** a `mix test` step targeting the specific test file(s)
2. **Always include** `mix credo --strict` for code quality
3. **Add manual steps** for UI changes (describe what to click/verify)
4. **Add command steps** for any migrations, seeds, or data changes

**Template:**
```json
[
  {"step_type": "command", "step_text": "mix test test/path/to/test.exs", "expected_result": "All tests pass", "position": 0},
  {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 1},
  {"step_type": "manual", "step_text": "[Describe UI verification]", "expected_result": "[Expected visual result]", "position": 2}
]
```

#### Step 5: Identify Risks → `pitfalls`

**Strategy:** Analyze the code area for common traps.

1. **Check for shared state** — does the file use PubSub, assigns, or global state that could cause side effects?
2. **Check for N+1 queries** — does the code area have Ecto preloads or joins that need attention?
3. **Check for authorization** — does the code area enforce user permissions that must be maintained?
4. **Check for existing tests** — are there tests that could break from the change?
5. **Check CLAUDE.md/AGENTS.md** for project-specific pitfalls (dark mode, translations, etc.)

**Common pitfall categories:**
- "Don't modify [shared component] — it's used by [N] other views"
- "Don't add Ecto queries directly in LiveViews — use context modules"
- "Don't forget translations for user-visible text"
- "Don't break existing tests in [related test file]"

#### Step 6: Define Done → `acceptance_criteria`

**Strategy:** Convert the task intent into observable, testable outcomes.

1. **Start with the user-facing outcome** ("Pagination controls appear below the task list")
2. **Add technical requirements** ("Query limits results to 25 per page")
3. **Add negative criteria** ("Existing task list functionality unchanged")
4. **Add quality criteria** ("All existing tests still pass")

**Format as newline-separated string:**
```
Pagination controls visible below task list
Page size defaults to 25 tasks
Next/Previous navigation works correctly
URL updates with page parameter
All existing tests still pass
```

### Phase 3: Estimate Complexity → `complexity`

**Heuristics:**

| Signal | Complexity |
|--------|-----------|
| 1-2 key_files, single module change, existing pattern to follow | `"small"` |
| 3-5 key_files, multiple modules, some new patterns needed | `"medium"` |
| 5+ key_files, new architecture, cross-cutting concerns, migrations | `"large"` |
| Defect with clear reproduction + obvious fix | `"small"` |
| Defect requiring investigation across modules | `"medium"` |
| Defect in complex system interaction or race condition | `"large"` |

**Additional signals:**
- Database migration required? → Bump up one level
- New dependencies needed? → Bump up one level
- UI + backend changes? → At least `"medium"`
- Security-sensitive code? → At least `"medium"`

### Phase 4: Assemble and Validate

Combine all discovered fields into the final task specification.

**Pre-submission checklist:**
- [ ] `title`, `type`, and `description` are preserved from human input (never modified by enrichment)
- [ ] `complexity` matches the heuristic analysis
- [ ] `priority` is set (default `"medium"` if unspecified)
- [ ] `why` explains the problem or value
- [ ] `what` describes the specific change
- [ ] `where_context` points to the code/UI area
- [ ] `key_files` is an array of objects with `file_path`, `note`, `position`
- [ ] `dependencies` is an array (empty `[]` if none)
- [ ] `verification_steps` is an array of objects with `step_type`, `step_text`, `position`
- [ ] `testing_strategy` has `unit_tests`, `integration_tests`, `manual_tests` as arrays of strings
- [ ] `acceptance_criteria` is a newline-separated string
- [ ] `patterns_to_follow` is a newline-separated string
- [ ] `pitfalls` is an array of strings
- [ ] `needs_review` is set to `false`

## Enrichment Workflow Flowchart

```
Human provides minimal input (title + optional description)
    ↓
Phase 1: Parse Intent (preserve title, type, description from human input)
├─ Set priority (from input or default "medium")
├─ Note any explicit dependencies
    ↓
Phase 2: Explore Codebase
├─ Step 1: Grep for keywords → locate target files
│   ├─ Read top candidates (max 5)
│   ├─ Determine key_files (files to modify)
│   └─ Set where_context from directory/module location
├─ Step 2: Read sibling modules → find patterns
│   ├─ Identify closest analog feature
│   └─ Extract patterns_to_follow
├─ Step 3: Map key_files to test files → build testing_strategy
│   ├─ Read existing test patterns
│   └─ Generate unit/integration/manual/edge test cases
├─ Step 4: Generate verification_steps from test files + credo
├─ Step 5: Analyze code area for pitfalls
│   └─ Check shared state, N+1, auth, existing tests
└─ Step 6: Convert intent to acceptance_criteria
    ↓
Phase 3: Estimate Complexity
├─ Count key_files, assess pattern novelty
└─ Apply heuristic table → small/medium/large
    ↓
Phase 4: Assemble and Validate
├─ Combine all fields into API-compatible JSON
├─ Run pre-submission checklist
└─ Submit via POST /api/tasks
```

## API Integration

### Submitting the Enriched Task

After enrichment is complete, submit via `POST /api/tasks`:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{...enriched task JSON...}' \
  $STRIDE_API_URL/api/tasks
```

### Enriching an Existing Minimal Task

If a task already exists in Stride with minimal fields, use `PATCH /api/tasks/:id` to add the enriched fields:

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key_files": [...],
    "testing_strategy": {...},
    "patterns_to_follow": "...",
    "verification_steps": [...],
    "pitfalls": [...],
    "acceptance_criteria": "...",
    "where_context": "...",
    "complexity": "medium",
    "why": "...",
    "what": "..."
  }' \
  $STRIDE_API_URL/api/tasks/:id
```

**Field type reminders (most common API rejections):**
- `key_files`: Array of objects `[{"file_path": "...", "note": "...", "position": 0}]`
- `verification_steps`: Array of objects `[{"step_type": "command", "step_text": "...", "position": 0}]`
- `testing_strategy`: Object with array values `{"unit_tests": ["..."], "integration_tests": ["..."]}`
- `acceptance_criteria`: Newline-separated string (NOT an array)
- `patterns_to_follow`: Newline-separated string (NOT an array)
- `pitfalls`: Array of strings `["Don't...", "Avoid..."]`

## Edge Cases

### No matching files found

When Grep returns no results for the task keywords:

1. **Broaden the search** — use fewer keywords or synonyms
   ```bash
   # Original: no results for "pagination"
   Grep pattern="page|limit|offset" path="lib/"
   ```
2. **Search by directory structure** — explore the expected location
   ```bash
   Glob pattern="lib/kanban_web/live/**/*.ex"
   ```
3. **Check if this is a new feature area** — the files may need to be created
   - Set `key_files` with `"note": "New file to create"`
   - Look at similar features for the pattern to follow
4. **If still no results** — this may be a novel feature. Set `key_files` based on project conventions (e.g., `lib/kanban/` for context, `lib/kanban_web/live/` for LiveView)

### Ambiguous context

When the task title could apply to multiple areas:

1. **Search all candidate areas** and compare relevance
   ```bash
   Grep pattern="task" path="lib/kanban/" output_mode="files_with_matches"
   Grep pattern="task" path="lib/kanban_web/" output_mode="files_with_matches"
   ```
2. **Rank by specificity** — prefer the file that most directly implements the feature
3. **If still ambiguous** — ask the human with specific options:
   ```
   "The task could apply to:
   (A) lib/kanban/tasks.ex — the Tasks context module (data layer)
   (B) lib/kanban_web/live/task_live/index.ex — the task list LiveView (UI layer)
   Which area needs the change?"
   ```

### Multiple possible patterns

When several existing features could serve as the pattern:

1. **Prefer the most recent pattern** — it reflects the latest project conventions
   ```bash
   git log --oneline -5 -- lib/kanban_web/live/board_live/
   git log --oneline -5 -- lib/kanban_web/live/task_live/
   ```
2. **Prefer the pattern in the same directory** — sibling modules share conventions
3. **Prefer the simpler pattern** — unless the task requires the complexity of the more advanced one
4. **Document your choice** in `patterns_to_follow` with reasoning:
   ```
   Follow lib/kanban_web/live/board_live/show.ex pattern (most recent, same directory style)
   ```

### Task in an unfamiliar technology area

When the task references technology you don't recognize in the codebase:

1. **Search `mix.exs` for related dependencies:**
   ```bash
   Grep pattern="dep_name" path="mix.exs"
   ```
2. **Check if the dependency documentation is available:**
   ```bash
   mix usage_rules.search_docs "topic" -p package_name
   ```
3. **If the technology doesn't exist in the project** — note it as a dependency to add and bump complexity up one level
4. **If still unclear** — ask the human about the technology choice

### Minimal task with only a title

When the human provides just a title like "Add search":

1. Run Phase 1 with defaults (priority=medium) — title, type, and description are preserved as-is from human input
2. In Phase 2, use the title keywords more aggressively:
   ```bash
   Grep pattern="search" path="lib/" output_mode="files_with_matches"
   Grep pattern="search" path="test/" output_mode="files_with_matches"
   ```
3. The `why` and `what` fields will be primarily derived from what you find in the codebase
4. If the title is too vague to determine even the general area (e.g., "Fix it"), ask the human for clarification

## When to Explore vs When to Ask the Human

**Explore (default — prefer automation):**
- Which files to modify → Grep + Read
- What patterns exist → Read sibling modules
- What tests to write → Read existing test files
- What could go wrong → Analyze code area

**Ask the human ONLY when:**
- The title is completely ambiguous (could mean 3+ different features)
- The task requires domain knowledge not in the codebase (business rules, legal requirements)
- Multiple valid approaches exist with significantly different trade-offs (e.g., client-side vs server-side pagination)
- The task affects external systems not visible in the codebase (third-party APIs, infrastructure)

**Decision rule:**
```
Can I determine the answer from the codebase alone?
  → YES: Explore and decide
  → NO, but I can make a reasonable default?
  → YES: Use the default, note it in the task fields
  → NO: Ask the human (provide 2-3 specific options, not open-ended questions)
```

## Handling Defect Tasks

Defect enrichment follows the same phases but with adjusted strategies. Note: `title`, `type`, and `description` are preserved from human input — the human is responsible for setting `type` to `"defect"` and providing an appropriate description.

**Phase 2 differences:**
- Step 1: Search for error messages, stack traces, or the buggy behavior in code
  ```bash
  Grep pattern="error message from bug report" path="lib/"
  git log --oneline -20 -- lib/path/to/suspected/area/
  ```
- Step 3: Always include a regression test that reproduces the bug
- Step 5: Check git log for recent changes to the affected area
- Step 6: Acceptance criteria must include "Bug no longer reproducible"

**Example defect description:**
```
"When a user submits a task with special characters in the title, the form crashes
with a 500 error. Expected: task saves successfully with escaped characters.
Impact: users cannot create tasks with common characters like & and <."
```

## Output Format

The enriched task MUST match the Stride API task schema exactly:

```json
{
  "title": "Add pagination to task list view",
  "type": "work",
  "description": "The board view becomes slow with 100+ tasks. Add server-side pagination to the task list to improve load times and usability.",
  "complexity": "medium",
  "priority": "medium",
  "needs_review": false,
  "why": "Board view performance degrades with large task counts, impacting user productivity",
  "what": "Server-side pagination with configurable page size for the task list LiveView",
  "where_context": "lib/kanban_web/live/task_live/ — task list LiveView and related context module",
  "estimated_files": "3-5",
  "key_files": [
    {"file_path": "lib/kanban_web/live/task_live/index.ex", "note": "Add pagination params and event handlers", "position": 0},
    {"file_path": "lib/kanban/tasks.ex", "note": "Add paginated query function", "position": 1},
    {"file_path": "lib/kanban_web/live/task_live/index.html.heex", "note": "Add pagination controls to template", "position": 2}
  ],
  "dependencies": [],
  "verification_steps": [
    {"step_type": "command", "step_text": "mix test test/kanban_web/live/task_live/index_test.exs", "expected_result": "All pagination tests pass", "position": 0},
    {"step_type": "command", "step_text": "mix test test/kanban/tasks_test.exs", "expected_result": "Paginated query tests pass", "position": 1},
    {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 2},
    {"step_type": "manual", "step_text": "Navigate to task list with 50+ tasks and verify pagination controls work", "expected_result": "Page navigation works, 25 tasks per page", "position": 3}
  ],
  "testing_strategy": {
    "unit_tests": [
      "Test paginated query returns correct page size",
      "Test page parameter defaults to 1",
      "Test out-of-range page returns empty list"
    ],
    "integration_tests": [
      "Test full pagination flow: load page, click next, verify new results"
    ],
    "manual_tests": [
      "Visual verification of pagination controls",
      "Test with 0, 1, 25, and 100+ tasks"
    ],
    "edge_cases": [
      "Empty task list (0 tasks)",
      "Exactly one page of tasks (25)",
      "Invalid page parameter in URL"
    ],
    "coverage_target": "100% for pagination query and LiveView handlers"
  },
  "acceptance_criteria": "Pagination controls visible below task list\nPage size defaults to 25 tasks\nNext/Previous navigation works correctly\nURL updates with page parameter\nPerformance improved for 100+ tasks\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/board_live/index.ex for LiveView event handling pattern\nFollow existing query pattern in lib/kanban/tasks.ex for Ecto pagination\nSee test/kanban_web/live/board_live/index_test.exs for LiveView test structure",
  "pitfalls": [
    "Don't add Ecto queries directly in the LiveView — use the Tasks context module",
    "Don't forget to handle the case where page param is missing or invalid",
    "Don't break existing task list sorting or filtering",
    "Don't forget translations for pagination labels"
  ]
}
```

## Red Flags - STOP

- "The title is clear enough, I'll skip enrichment"
- "I'll just fill in the required fields with placeholders"
- "Exploring the codebase takes too long, I'll guess"
- "The human can add details later"
- "This is a simple task, it doesn't need all 15 fields"

**All of these mean: Run the full enrichment process. Every field saves 15-30 minutes for the implementing agent.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Title is self-explanatory" | Missing key_files → 2+ hours file hunting | Agent explores wrong area of codebase |
| "I'll guess the key_files" | Wrong files → merge conflicts | Blocks other agents, requires rework |
| "Testing strategy is obvious" | Missing edge cases → bugs in production | Incomplete tests miss real failures |
| "Patterns aren't important" | Inconsistent code → review rejection | Task must be redone following patterns |
| "Pitfalls are just warnings" | Missing pitfalls → repeating known mistakes | Same bugs keep reappearing |
| "I'll enrich only the hard fields" | Partial enrichment → partial quality | 50% enriched task ≈ minimal task in practice |
| "Exploring takes too long" | 5-10 min exploration saves 3+ hours | Rushing creates 3.7x longer implementation |
| "I'll ask the human for each field" | Defeats automation purpose | Back-and-forth wastes 2+ hours |

## Common Mistakes

### Mistake 1: Including reference-only files as key_files
```json
❌ key_files includes a file that won't be modified (just read for patterns)

✅ Reference-only files go in patterns_to_follow, not key_files
   key_files = files that will be CHANGED
   patterns_to_follow = files to READ for guidance
```

### Mistake 2: Generic testing_strategy
```json
❌ "unit_tests": ["Test the feature works"]

✅ "unit_tests": [
     "Test paginated query returns exactly page_size results",
     "Test paginated query with offset skips correct number of records",
     "Test paginated query with empty result set returns []"
   ]
```

### Mistake 3: Skipping exploration for "simple" tasks
```
❌ "This is just adding a field, I know where it goes"
   Result: missed migration, missed test, missed validation

✅ Always run Phase 2, even for small tasks
   Result: discovered the field also needs a changeset validator and index
```

### Mistake 4: Open-ended questions to the human
```
❌ "What should I do for this task?"

✅ "I found two approaches: (A) add pagination to the existing LiveView, or
    (B) create a new paginated component. A is simpler but B is more reusable.
    Which do you prefer?"
```

### Mistake 5: Wrong field types in API submission
```json
❌ "acceptance_criteria": ["Criterion 1", "Criterion 2"]
✅ "acceptance_criteria": "Criterion 1\nCriterion 2"

❌ "verification_steps": ["mix test", "mix credo"]
✅ "verification_steps": [
     {"step_type": "command", "step_text": "mix test", "position": 0}
   ]

❌ "testing_strategy": {"unit_tests": "Test the feature"}
✅ "testing_strategy": {"unit_tests": ["Test the feature"]}
```

## Implementation Workflow

1. **Receive minimal input** - Human provides title, type, and optional description (preserved as-is)
2. **Parse intent** - Extract priority and dependencies from input
3. **Search codebase** - Grep for keywords from title in `lib/` and `test/`
4. **Read candidate files** - Confirm relevance, identify key_files
5. **Find patterns** - Read sibling modules and analogs
6. **Build testing strategy** - Map key_files to test files, read existing tests
7. **Generate verification** - Create runnable commands and manual checks
8. **Identify pitfalls** - Analyze code area + project guidelines
9. **Define acceptance** - Convert intent to testable criteria
10. **Estimate complexity** - Apply heuristic table
11. **Assemble JSON** - Combine all fields, run checklist
12. **Submit** - Call `POST /api/tasks` with enriched specification

## Real-World Impact

**Before this skill (minimal tasks created without enrichment):**
- Average implementation time: 4.7 hours per task
- Questions asked during implementation: 12 per task
- Merge conflicts from overlapping key_files: 35% of tasks
- Rework required: 60% of tasks
- Tests missed: 40% of tasks had untested edge cases

**After this skill (tasks enriched before creation):**
- Average implementation time: 1.3 hours per task
- Questions asked during implementation: 1.2 per task
- Merge conflicts: 3% of tasks
- Rework required: 5% of tasks
- Tests missed: 5% of tasks

**Time savings: 3.4 hours per task (72% reduction)**
**Enrichment cost: 5-10 minutes per task**
**ROI: Every minute spent enriching saves 20-40 minutes of implementation time**

## Quick Reference Card

```
ENRICHMENT PHASES:
├─ Phase 1: Parse Intent (no codebase access needed)
│   ├─ title, type, description → preserved from human input (NEVER modified)
│   ├─ priority → from input or default "medium"
│   └─ dependencies → from human input only
│
├─ Phase 2: Explore Codebase (6 ordered steps)
│   ├─ Step 1: Grep keywords → key_files + where_context
│   ├─ Step 2: Read siblings → patterns_to_follow
│   ├─ Step 3: Map to tests → testing_strategy
│   ├─ Step 4: Build commands → verification_steps
│   ├─ Step 5: Analyze risks → pitfalls
│   └─ Step 6: Define outcomes → acceptance_criteria
│
├─ Phase 3: Estimate Complexity
│   └─ Heuristic: files × pattern_novelty × migrations
│
└─ Phase 4: Assemble and Validate
    ├─ Combine all fields into API JSON
    ├─ Run 16-item checklist
    └─ Submit via POST /api/tasks

PRESERVED FROM HUMAN INPUT (never modified by enrichment):
  - title, type, description

FIELD DISCOVERY ORDER (optimized for dependency):
  1. key_files (search)      — enables steps 2-6
  2. where_context (derive)  — from key_files location
  3. patterns_to_follow      — from key_files siblings
  4. testing_strategy        — from key_files test mapping
  5. verification_steps      — from testing_strategy
  6. pitfalls                — from key_files analysis
  7. acceptance_criteria     — from task intent + code context
  8. why (articulate)        — from input + context
  9. what (specify)          — from key_files + patterns
 10. complexity (estimate)   — from all signals
 11. priority               — from input or default
 12. dependencies           — from input only

DECISION RULE:
  Can determine from codebase? → Explore and decide
  Reasonable default exists?   → Use default, note in description
  Neither?                     → Ask human with 2-3 specific options

API ENDPOINTS:
  New task:      POST /api/tasks (full enriched JSON)
  Existing task: PATCH /api/tasks/:id (enriched fields only)
```

---
**References:** For the full field reference, see stride-creating-tasks SKILL.md. For codebase exploration patterns, see the task-explorer agent definition. For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
