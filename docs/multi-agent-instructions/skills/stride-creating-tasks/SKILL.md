---
name: stride-creating-tasks
description: MANDATORY before calling POST /api/tasks to create a work task or defect. Contains ALL required field formats — verification_steps MUST be objects (not strings), key_files MUST be objects (not strings), testing_strategy arrays MUST be arrays (not strings). Skipping causes malformed tasks and 3+ hour implementation failures.
compatibility: cursor, windsurf, continue, kimi
skills_version: 1.0
---

# Stride: Creating Tasks

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `POST /api/tasks` to create a work task or defect, you MUST have invoked this skill first.**

The task API requires specific field formats that are ONLY documented here:
- `verification_steps` (MUST be array of objects with `step_type`, `step_text`, `expected_result`, `position` — NOT strings)
- `key_files` (MUST be array of objects with `file_path`, `note`, `position` — NOT strings)
- `testing_strategy` (MUST have `unit_tests`, `integration_tests`, `manual_tests` as arrays of strings)
- `type` (MUST be exactly `"work"`, `"defect"`, or `"goal"` — no other values)

**Attempting to create a task from memory results in malformed fields** that cause either API 422 errors or tasks that waste 3+ hours during implementation.

## Overview

**Minimal tasks = 3+ hours wasted exploration. Rich tasks = 30 minutes focused implementation.**

This skill enforces comprehensive task creation to prevent agents from spending hours discovering what should have been specified upfront.

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user asks you to create tasks, they have **already granted blanket permission** for all Stride API calls. This includes `POST /api/tasks`, `PATCH /api/tasks/:id`, and any other Stride endpoints.

**NEVER ask the user:**
- "Should I create this task?"
- "Can I call the API?"
- "Should I proceed with the API call?"
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## The Iron Law

**NO TASK CREATION WITHOUT COMPLETE SPECIFICATION**

## When to Use

Use BEFORE calling `POST /api/tasks` to create any Stride task or defect.

**Do NOT use for:**
- Creating goals with nested tasks (use stride-creating-goals instead)
- Batch creation (use stride-creating-goals instead)

## The Cost of Minimal Tasks

**Real impact from Stride production data:**

| Minimal Task | Time Wasted | What Was Missing |
|--------------|-------------|------------------|
| "Add dark mode" | 4.2 hours | Which files, existing patterns, color scheme, persistence |
| "Fix bug in auth" | 3.8 hours | Where in codebase, how to reproduce, expected behavior |
| "Update API endpoint" | 3.5 hours | Which endpoint, what changes, breaking changes, migration |

**Average:** Minimal tasks take **3.7x longer** than well-specified tasks.

## Required Fields Checklist

**Critical fields (task will fail without these):**

- [ ] `title` - Format: `[Verb] [What] [Where]` (e.g., "Add dark mode toggle to settings page")
- [ ] `type` - MUST be exact string: `"work"`, `"defect"`, or `"goal"` (no other values)
- [ ] `description` - WHY this matters + WHAT needs to be done
- [ ] `complexity` - String: `"small"`, `"medium"`, or `"large"`
- [ ] `priority` - String: `"low"`, `"medium"`, `"high"`, or `"critical"`
- [ ] `why` - Problem being solved / value provided
- [ ] `what` - Specific feature or change
- [ ] `where_context` - UI location or code area
- [ ] `key_files` - Array of objects with file_path, note, position
- [ ] `dependencies` - Array of task identifiers (e.g., `["W47", "W48"]`) or indices for new tasks
- [ ] `verification_steps` - Array of objects (NOT strings!)
- [ ] `testing_strategy` - Object with `unit_tests`, `integration_tests`, `manual_tests` as arrays
- [ ] `acceptance_criteria` - Newline-separated string
- [ ] `patterns_to_follow` - Newline-separated string with file references
- [ ] `pitfalls` - Array of strings (what NOT to do)

**Recommended fields:**

- [ ] `estimated_files` - Helps set expectations: `"1-2"`, `"3-5"`, or `"5+"`
- [ ] `required_capabilities` - Array of agent skills needed

## Field Type Validations (CRITICAL)

### type field
**MUST be exact string match:**
- ✅ Valid: `"work"`, `"defect"`, `"goal"`
- ❌ Invalid: `"task"`, `"bug"`, `"feature"`, `null`, or any other value

### testing_strategy arrays
**MUST be arrays, not strings:**
- ✅ `"unit_tests": ["Test auth flow", "Test error handling"]`
- ❌ `"unit_tests": "Run unit tests"` (will fail)

### verification_steps
**MUST be array of objects:**
- ✅ `[{"step_type": "command", "step_text": "mix test", "position": 0}]`
- ❌ `["mix test"]` (array of strings - will crash)
- ❌ `"mix test"` (single string - will crash)

## Dependencies Pattern

**Rule: Use indices for NEW tasks, identifiers for EXISTING tasks**

**For existing tasks** (already in system):
```json
{
  "title": "Add JWT refresh endpoint",
  "type": "work",
  "dependencies": ["W47", "W48"]
}
```

**For new tasks** (being created in same request with a goal):
Use array indices since identifiers don't exist yet - see stride-creating-goals skill.

## Quick Reference: Complete Task Example

```json
{
  "title": "Add dark mode toggle to settings page",
  "type": "work",
  "description": "Users need dark mode to reduce eye strain during night work. Add toggle switch in settings with persistent storage.",
  "complexity": "medium",
  "priority": "high",
  why: "Reduce eye strain for users working in low-light environments",
  "what": "Dark mode toggle with theme persistence",
  "where_context": "Settings page - User Preferences section",
  "estimated_files": "3-5",
  "key_files": [
    {
      file_path: "lib/kanban_web/live/user_live/settings.ex",
      "note": "Add theme preference controls",
      "position": 0
    },
    {
      file_path: "assets/css/app.css",
      "note": "Dark mode styles",
      "position": 1
    }
  ],
  "dependencies": [],
  "verification_steps": [
    {
      "step_type": "command",
      "step_text": "mix test test/kanban_web/live/user_live/settings_test.exs",
      "expected_result": "All theme tests pass",
      "position": 0
    },
    {
      "step_type": "manual",
      "step_text": "Toggle dark mode in settings and refresh page",
      "expected_result": "Theme persists across sessions",
      "position": 1
    }
  ],
  "testing_strategy": {
    "unit_tests": [
      "Test theme preference update",
      "Test default theme is light"
    ],
    "integration_tests": [
      "Test theme persistence across page loads",
      "Test theme applies to all pages"
    ],
    "manual_tests": [
      "Visual verification of dark mode styles",
      "Test in multiple browsers"
    ],
    "edge_cases": [
      "User with no theme preference set",
      "Rapid toggle switching"
    ],
    "coverage_target": "100% for theme preference logic"
  },
  "acceptance_criteria": "Toggle appears in settings\nDark mode applies site-wide\nPreference persists across sessions\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/user_live/settings.ex for preference update pattern\nFollow existing theme structure in app.css",
  "pitfalls": [
    "Don't modify existing color variables - create new dark mode variants",
    "Don't forget to test theme on all major pages",
    "Don't use localStorage directly - use Phoenix user preferences"
  ]
}
```

## Red Flags - STOP

- "I'll just create a simple task"
- "The agent can figure out the details"
- "This is self-explanatory"
- "I'll add details later if needed"
- "Just need title and description"

**All of these mean: Add comprehensive details NOW.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Simple task, no details needed" | Agent spends 3+ hours exploring | 3+ hours wasted on discovery |
| "Self-explanatory from title" | Missing context causes wrong approach | Wrong solution, must redo |
| "Agent will ask questions" | Breaks flow, causes delays | Back-and-forth wastes 2+ hours |
| "Add details later" | Never happens | Minimal task sits incomplete |
| "Time pressure, need quick" | Rich task saves MORE time | Spending 5 min now saves 3 hours later |

## Common Mistakes

### Mistake 1: String arrays instead of object arrays
```json
❌ "verification_steps": ["mix test", "mix credo"]
✅ "verification_steps": [
  {"step_type": "command", "step_text": "mix test", "position": 0}
]
```

### Mistake 2: Wrong type value
```json
❌ "type": "task"
❌ "type": "bug"
✅ "type": "work"
✅ "type": "defect"
```

### Mistake 3: Missing key_files
```json
❌ No key_files specified
✅ "key_files": [
  {file_path: "path/to/file.ex", "note": "Why modifying", "position": 0}
]
```

Result: Another agent claims overlapping task, causing merge conflicts.

### Mistake 4: Vague acceptance criteria
```json
❌ "acceptance_criteria": "Works correctly"
✅ "acceptance_criteria": "Toggle visible in settings\nDark mode applies site-wide\nPreference persists"
```

## Implementation Workflow

1. **Gather context** - Understand the full requirement
2. **Check dependencies** - Are there existing tasks this depends on?
3. **Identify files** - Which files will change?
4. **Define acceptance** - What does "done" look like?
5. **Specify tests** - How will this be verified?
6. **Document pitfalls** - What should be avoided?
7. **Create task** - Use checklist above
8. **Call API** - `POST /api/tasks` with complete JSON

## Real-World Impact

**Before this skill (5 random tasks):**
- Average time to completion: 4.7 hours
- Questions asked: 12 per task
- Rework required: 60% of tasks

**After this skill (5 random tasks):**
- Average time to completion: 1.3 hours
- Questions asked: 1.2 per task
- Rework required: 5% of tasks

**Time savings: 3.4 hours per task (72% reduction)**

## Field Quick Reference

Use these exact values — any other value will be rejected.

| Field | Type | Valid Values | Required |
|-------|------|-------------|----------|
| `type` | enum | `"work"`, `"defect"`, `"goal"` | Yes |
| `priority` | enum | `"low"`, `"medium"`, `"high"`, `"critical"` | Yes |
| `complexity` | enum | `"small"`, `"medium"`, `"large"` | No |
| `needs_review` | boolean | `true`, `false` | No (default: false) |
| `acceptance_criteria` | string | Newline-separated text | No |
| `patterns_to_follow` | string | Newline-separated text | No |
| `dependencies` | array | Task identifiers `["W45", "W46"]` | No |
| `pitfalls` | array | Strings `["Don't do X", "Avoid Y"]` | No |

## Embedded Object Formats — WRONG vs RIGHT

### verification_steps

```json
❌ WRONG (strings — will be rejected):
"verification_steps": ["mix test", "mix credo --strict"]

❌ WRONG (missing required fields):
"verification_steps": [{"step_text": "mix test"}]

✅ RIGHT (objects with all required fields):
"verification_steps": [
  {
    "step_type": "command",
    "step_text": "mix test",
    "expected_result": "All tests pass",
    "position": 0
  }
]
```

**Required fields:** `step_type` (`"command"` or `"manual"` only), `step_text`, `position` (integer >= 0)
**Optional fields:** `expected_result`

### key_files

```json
❌ WRONG (strings):
"key_files": ["lib/my_app/tasks.ex"]

❌ WRONG (absolute path):
"key_files": [{"file_path": "/lib/my_app/tasks.ex", "position": 0}]

✅ RIGHT:
"key_files": [
  {
    "file_path": "lib/my_app/tasks.ex",
    "note": "Add query function",
    "position": 0
  }
]
```

**Required fields:** `file_path` (relative, no leading `/` or `..`), `position` (integer >= 0)
**Optional fields:** `note`

### testing_strategy

```json
❌ WRONG (string values for test arrays):
"testing_strategy": {
  "unit_tests": "Test login with valid credentials"
}

✅ RIGHT (arrays of strings):
"testing_strategy": {
  "unit_tests": ["Test valid login", "Test invalid login"],
  "integration_tests": ["Full auth flow"],
  "edge_cases": ["Empty password", "SQL injection"],
  "coverage_target": "100% for auth module"
}
```

**Valid keys:** `unit_tests`, `integration_tests`, `manual_tests`, `edge_cases`, `coverage_target`
**All values** must be strings or arrays of strings.

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
