# Stride Superpowers Skills - Implementation Plan

**Status:** Planning Complete - Ready for Implementation
**Created:** 2026-01-07
**Purpose:** Create Superpowers plugin skills to enforce Stride workflow discipline for AI agents

## Overview

This plan details the creation of 4 Superpowers skills that will enforce proper Stride task management workflows for AI agents. These skills will provide strict enforcement (agents MUST invoke before actions) and automatic hook integration (reading and executing .stride.md hooks).

## User Requirements Summary

- **Type:** Superpowers plugin skills (NOT slash commands)
- **Coverage:** 4 workflows - claiming, completion, task creation, goal/batch creation
- **Enforcement:** Strict (mandatory invocation before actions)
- **Hook Integration:** Automatic (read .stride.md and execute hooks)

## Proposed Skills Architecture

### Skill 1: `stride-claiming-tasks`

**Description:** "Use when you want to claim a task from Stride, before making any API calls to /api/tasks/claim. After successful claiming, immediately begin implementation."

**Purpose:** Enforce the proper claiming workflow including hook execution, then transition to active work

**Key Sections:**
- **The Iron Law:** NO CLAIMING WITHOUT HOOK EXECUTION
- **The Complete Claiming Process** (numbered steps with TodoWrite integration)
- **Hook Execution Pattern** (how to read .stride.md and execute before_doing)
- **Red Flags** (thoughts that signal skipping the skill)
- **Rationalization Table** (common excuses and rebuttals)
- **Quick Reference** (API endpoint, required fields, hook timing)

**Enforcement Strategy:**
- Must invoke BEFORE calling `/api/tasks/claim`
- Requires TodoWrite todos for each step
- Blocks progress until before_doing hook succeeds
- Validates .stride_auth.md and .stride.md exist first

**Content Outline:**
```markdown
## The Iron Law
NO TASK CLAIMING WITHOUT PROPER SETUP AND HOOK EXECUTION

## Prerequisites Checklist
1. Verify .stride_auth.md exists
2. Verify .stride.md exists
3. Extract API token and URL

## The Complete Claiming Process
[Step-by-step with TodoWrite integration]

## Hook Execution Pattern
[How to read .stride.md before_doing section]
[How to set environment variables]
[How to execute with 60s timeout]
[What to do if hook fails]

## When Hooks Fail

**If before_doing fails:**
1. Read the error output carefully
2. Fix the underlying issue (usually: outdated code, missing deps, merge conflicts)
3. Re-run the hook manually to verify fix
4. Only proceed to claim task after hook succeeds
5. Never skip a failing hook

**Common before_doing failures:**
- Merge conflicts → Resolve conflicts first
- Missing dependencies → Run deps.get
- Test failures → Fix tests before claiming new work

## After Successful Claim

**CRITICAL: Once the task is claimed, you MUST immediately begin implementation.**

Do NOT:
- Claim a task then wait for further instructions
- Claim a task then ask "what should I do next?"
- Claim multiple tasks before starting work

DO:
- Read the task description, acceptance criteria, and key files
- Start implementing the solution immediately
- Follow patterns_to_follow and avoid pitfalls
- Work continuously until ready to complete (using `stride-completing-tasks` skill)

**The claiming skill's job ends when you start coding. Your next interaction with Stride will be when you're ready to mark the work complete.**

## Red Flags - STOP
- "I'll just claim quickly and run hooks later"
- "The hook is just git pull, I can skip it"
- "I can fix hook failures after claiming"
- "I'll claim this task and then figure out what to do"

## Rationalization Table
| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "This is urgent" | Hooks prevent merge conflicts | Wastes 2+ hours fixing conflicts later |
| "I know the code is current" | Hooks ensure consistency | Outdated deps cause runtime failures |
| "Just a quick claim" | Setup takes 30 seconds | Skip it and lose 30 minutes debugging |
| "The hook is just git pull" | May also run deps.get, migrations | Missing deps break implementation |
| "I'll claim and ask what's next" | Claiming means you're ready to work | Wastes claim time, blocks other agents |

## Quick Reference Card

```
CLAIMING WORKFLOW:
├─ 1. Verify .stride_auth.md exists ✓
├─ 2. Verify .stride.md exists ✓
├─ 3. Extract API token and URL ✓
├─ 4. Call GET /api/tasks/next ✓
├─ 5. Review task details ✓
├─ 6. Read before_doing hook from .stride.md ✓
├─ 7. Execute before_doing (60s timeout) ✓
├─ 8. Capture exit_code, output, duration_ms ✓
├─ 9. Hook succeeds? → Call POST /api/tasks/claim WITH result ✓
├─ 10. Hook fails? → Fix issues, retry, never skip ✓
└─ 11. Task claimed? → BEGIN IMPLEMENTATION IMMEDIATELY ✓

API ENDPOINT: POST /api/tasks/claim
REQUIRED: {
  "identifier": "W47",
  "agent_name": "Claude",
  "before_doing_result": {
    "exit_code": 0,
    "output": "Hook output...",
    "duration_ms": 450
  }
}
HOOK TIMING: before_doing executes BEFORE claim
CRITICAL: Must include before_doing_result in claim request
NEXT STEP: Immediately begin working on the task after successful claim
```
```

---

### Skill 2: `stride-completing-tasks`

**Description:** "Use when you've finished work on a Stride task and need to mark it complete, before calling /api/tasks/:id/complete"

**Purpose:** Enforce proper completion workflow with after_doing AND before_review hooks BEFORE completion endpoint

**Key Sections:**
- **The Iron Law:** EXECUTE BOTH after_doing AND before_review BEFORE CALLING COMPLETE
- **The Critical Mistake** (why calling complete before validation fails)
- **The Complete Completion Process**
- **Hook Execution Pattern** (after_doing, before_review, after_review)
- **Review vs. Auto-Approval Decision Tree**
- **Red Flags**
- **Rationalization Table**

**Enforcement Strategy:**
- Must invoke BEFORE calling `/api/tasks/:id/complete`
- Must execute after_doing hook first (blocking, 120s)
- Must execute before_review hook second (blocking, 60s)
- Must only call complete endpoint AFTER both hooks succeed
- Must include both hook results in the API request
- Must handle review cycle properly based on needs_review flag

**Content Outline:**
```markdown
## The Iron Law
EXECUTE BOTH after_doing AND before_review HOOKS BEFORE CALLING COMPLETE ENDPOINT

## The Critical Mistake
Calling PATCH /api/tasks/:id/complete before running BOTH hooks causes:
- Task marked done prematurely
- Failed tests hidden (after_doing skipped)
- Review preparation skipped (before_review skipped)
- Quality gates bypassed

## The Complete Completion Process
1. Mark todo as in_progress: "Completing task"
2. Read .stride.md after_doing section
3. Execute after_doing hook (120s timeout, blocking)
4. Capture exit_code, output, duration_ms from after_doing
5. If hook fails: FIX ISSUES, do not proceed
6. Read .stride.md before_review section
7. Execute before_review hook (60s timeout, blocking)
8. Capture exit_code, output, duration_ms from before_review
9. If hook fails: FIX ISSUES, do not proceed
10. If both hooks succeed: Call PATCH /api/tasks/:id/complete with BOTH hook results
11. If needs_review=true: STOP and wait
12. If needs_review=false: Execute after_review hook (60s timeout, blocking)

## Completion Workflow Flowchart

```
Work Complete
    ↓
Execute after_doing (120s)
    ↓
Success? ─NO→ Fix Issues → Retry after_doing
    ↓ YES
Execute before_review (60s)
    ↓
Success? ─NO→ Fix Issues → Retry before_review
    ↓ YES
Call PATCH /api/tasks/:id/complete
    ↓
needs_review=true? ─YES→ STOP (wait for human)
    ↓ NO
Execute after_review (60s)
    ↓
Success? ─NO→ Log warning, task still complete
    ↓ YES
Claim next task
```

## Review vs Auto-Approval Decision

```
Task marked complete via API
    ↓
Check needs_review flag
    ↓
    ├─ needs_review=true
    │      ↓
    │  Task → Review column
    │      ↓
    │  Agent MUST STOP
    │      ↓
    │  Wait for human approval
    │      ↓
    │  Human calls /mark_reviewed
    │      ↓
    │  Execute after_review hook
    │      ↓
    │  Task → Done column
    │
    └─ needs_review=false
           ↓
       Task → Done column immediately
           ↓
       Execute after_review hook
           ↓
       Claim next task
```

## When Hooks Fail

**If after_doing fails:**
1. DO NOT call complete endpoint
2. Read test/build failures carefully
3. Fix the failing tests or build issues
4. Re-run after_doing hook to verify
5. Only call complete endpoint after success

**If before_review fails:**
1. DO NOT call complete endpoint
2. Fix the issue (usually: PR creation, doc generation)
3. Re-run before_review hook
4. Only proceed after success

**Common after_doing failures:**
- Test failures → Fix tests first
- Build errors → Resolve compilation issues
- Linting errors → Fix code quality issues
- Coverage below target → Add missing tests

## Red Flags - STOP
- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
- "I'll skip the hooks this time"

## Rationalization Table
| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |

## Quick Reference Card

```
COMPLETION WORKFLOW:
├─ 1. Work is complete ✓
├─ 2. Read after_doing hook from .stride.md ✓
├─ 3. Execute after_doing (120s timeout, blocking) ✓
├─ 4. Capture exit_code, output, duration_ms ✓
├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 6. Read before_review hook ✓
├─ 7. Execute before_review (60s timeout, blocking) ✓
├─ 8. Capture exit_code, output, duration_ms ✓
├─ 9. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 10. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
├─ 11. needs_review=true? → STOP, wait for human ✓
└─ 12. needs_review=false? → Execute after_review, claim next ✓

API ENDPOINT: PATCH /api/tasks/:id/complete
REQUIRED: {
  "agent_name": "Claude",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing...",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Tests passed...",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "PR created...",
    "duration_ms": 2340
  }
}
CRITICAL: Execute BOTH after_doing AND before_review BEFORE calling complete
HOOK ORDER: after_doing → before_review → complete (with both results) → after_review
```
```

---

### Skill 3: `stride-creating-tasks`

**Description:** "Use when creating a new Stride task or defect, before calling POST /api/tasks"

**Purpose:** Ensure tasks are created with comprehensive specifications to prevent 3+ hour exploration failures

**Key Sections:**
- **The Iron Law:** NO MINIMAL TASKS
- **The Cost of Minimal Tasks** (3+ hours exploration vs. 30 min implementation)
- **Required Fields Checklist**
- **Task Schema Deep Dive**
- **Testing Strategy Pattern**
- **Verification Steps Pattern**
- **Key Files Documentation**
- **Red Flags**
- **Rationalization Table**

**Enforcement Strategy:**
- Must invoke BEFORE calling POST /api/tasks
- Must include ALL required fields
- Must provide comprehensive testing_strategy
- Must provide actionable verification_steps as objects, not strings
- Must document key_files to prevent merge conflicts

**Content Outline:**
```markdown
## The Iron Law
NO MINIMAL TASKS - Detailed specs save hours

Minimal task = 3+ hours exploration
Rich task = 30 minutes implementation

## The Cost of Minimal Tasks
[Real examples from Stride docs]

## Required Fields Checklist
- [ ] title (clear, specific verb + what + where)
- [ ] type (MUST be string: "work", "defect", or "goal" - no other values)
- [ ] description (WHY problem + WHAT solution)
- [ ] complexity (string: "small", "medium", "large")
- [ ] priority (string: "low", "medium", "high", "critical")
- [ ] why (problem being solved / value provided)
- [ ] what (specific feature/change)
- [ ] where_context (UI location / code area)
- [ ] estimated_files (helps set expectations: "1-2", "3-5", "5+")
- [ ] key_files (array of objects - CRITICAL for preventing merge conflicts)
- [ ] dependencies (array of identifiers/indices - CRITICAL for execution order)
- [ ] verification_steps (array of objects with step_type, step_text, position)
- [ ] testing_strategy (object with unit_tests/integration_tests/manual_tests as arrays)
- [ ] acceptance_criteria (newline-separated string)
- [ ] patterns_to_follow (newline-separated string with file references)
- [ ] pitfalls (array of strings - what NOT to do)

## Field Type Validations (CRITICAL)

**type field** - MUST be exact string match:
- ✅ Valid: "work", "defect", "goal" (strings only)
- ❌ Invalid: "task", "bug", "feature", null, or any other value

**testing_strategy arrays** - MUST be arrays, not strings:
- ✅ "unit_tests": ["Test 1", "Test 2"] (array of strings)
- ❌ "unit_tests": "Run tests" (single string - will fail)
- Same requirement for integration_tests and manual_tests

**verification_steps** - MUST be array of objects:
- ✅ [{"step_type": "command", "step_text": "mix test", "position": 0}]
- ❌ ["mix test"] (array of strings - will crash)
- ❌ "mix test" (single string - will crash)

## Dependencies Pattern (CRITICAL for Task Order)

**Rule: Use indices for NEW tasks, identifiers for EXISTING tasks**

**When creating tasks in the SAME request (use array indices):**
```json
{
  "title": "Auth System",
  "type": "goal",
  "tasks": [
    {"title": "Schema", "type": "work"},
    {"title": "Endpoints", "type": "work", "dependencies": [0]},
    {"title": "Tests", "type": "work", "dependencies": [0, 1]}
  ]
}
```
**Why indices?** Identifiers (W47, G12) are auto-generated when tasks are created. For tasks being created in the same request, you don't know their identifiers yet, so use their position index (0, 1, 2).

**When depending on EXISTING tasks already in the system (use identifiers):**
```json
{
  "title": "New Feature",
  "type": "work",
  "dependencies": ["W47", "W48"]
}
```
**Why identifiers?** The tasks W47 and W48 already exist in the system with assigned identifiers, so you reference them directly.

**Critical:** Dependencies control when tasks become claimable. Tasks with unmet dependencies won't appear in /api/tasks/next.

## Testing Strategy Pattern
```json
"testing_strategy": {
  "unit_tests": ["Test case 1", "Test case 2"],
  "integration_tests": ["E2E scenario"],
  "manual_tests": ["Manual verification"],
  "edge_cases": ["Null values", "Concurrent access"],
  "coverage_target": "100% for module"
}
```

## Key Files Pattern (Prevents Merge Conflicts)
```json
"key_files": [
  {
    "file_path": "lib/kanban_web/controllers/auth_controller.ex",
    "note": "Add authentication endpoints",
    "position": 0
  },
  {
    "file_path": "lib/kanban/accounts.ex",
    "note": "User account logic",
    "position": 1
  }
]
```

**Critical:** Tasks with overlapping key_files cannot be claimed simultaneously.

## Verification Steps Pattern (CRITICAL)
MUST be array of objects, NOT strings:
```json
"verification_steps": [
  {
    "step_type": "command",
    "step_text": "mix test path/to/test.exs",
    "expected_result": "All tests pass",
    "position": 0
  },
  {
    "step_type": "manual",
    "step_text": "Navigate to /login and test",
    "expected_result": "Login works correctly",
    "position": 1
  }
]
```

## Red Flags - STOP
- "I'll just create a simple task"
- "The agent can figure out the details"
- "This is self-explanatory"
- "I'll add details later if needed"

## Rationalization Table
| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Simple task" | Agent spends 3+ hours exploring | 3 hours wasted on discovery |
| "Self-explanatory" | Missing context causes wrong approach | Implement wrong solution, have to redo |
| "Add details later" | Never happens | Minimal task sits incomplete for days |
| "Agent will ask" | Breaks flow, causes delays | Back-and-forth wastes 2+ hours |

## Quick Reference Card

```
TASK CREATION CHECKLIST:
├─ title ✓ (verb + what + where)
├─ type ✓ (string: "work", "defect", "goal" ONLY)
├─ why ✓ (problem/value)
├─ what ✓ (specific change)
├─ where_context ✓ (UI/code location)
├─ description ✓ (WHY + WHAT combined)
├─ complexity ✓ (string: small/medium/large)
├─ priority ✓ (string: low/medium/high/critical)
├─ estimated_files ✓ ("1-2", "3-5", "5+")
├─ key_files ✓ (array of objects - prevents conflicts)
├─ dependencies ✓ (array - controls execution order)
├─ verification_steps ✓ (array of objects, not strings!)
├─ testing_strategy ✓ (object with arrays for unit/integration/manual)
├─ acceptance_criteria ✓ (newline-separated string)
├─ patterns_to_follow ✓ (newline-separated with file refs)
└─ pitfalls ✓ (array of strings)
```

---

### Skill 4: `stride-creating-goals`

**Description:** "Use when creating a Stride goal with nested tasks or using batch creation, before calling POST /api/tasks or POST /api/tasks/batch"

**Purpose:** Ensure goals are properly structured with dependencies, nested tasks, and correct batch format

**Key Sections:**
- **The Iron Law:** GOALS REQUIRE STRUCTURE
- **When to Create Goals vs. Flat Tasks**
- **Batch Endpoint Critical Format** (root key must be "goals")
- **Dependency Patterns**
- **Task Nesting Rules**
- **The Most Common Mistake** (using "tasks" instead of "goals" as root key)
- **Red Flags**
- **Rationalization Table**

**Enforcement Strategy:**
- Must invoke BEFORE calling POST /api/tasks with nested tasks OR POST /api/tasks/batch
- Must use correct batch format with "goals" root key
- Must handle dependencies properly (indices for nested, identifiers for existing)
- Must ensure each nested task follows stride-creating-tasks skill requirements

**Content Outline:**
```markdown
## The Iron Law
GOALS REQUIRE PROPER STRUCTURE AND DEPENDENCIES

## When to Create Goals vs. Flat Tasks

**Create a Goal when:**
- 25+ hours total work
- Multiple related tasks
- Dependencies between tasks

**Create flat tasks when:**
- <8 hours total
- Independent features
- Single issue/fix

## Batch Endpoint Critical Format

**CRITICAL:** Root key must be "goals", NOT "tasks"

```json
{
  "goals": [
    {
      "title": "Goal 1",
      "type": "goal",
      "complexity": "large",
      "tasks": [
        {"title": "Task 1", "type": "work"},
        {"title": "Task 2", "type": "work", "dependencies": [0]}
      ]
    }
  ]
}
```

**Note:** Root key MUST be `"goals"` (not `"tasks"`)

## The Most Common Mistake
Using root key "tasks" instead of "goals" - This is the #1 batch creation error

## Dependency Patterns

**Within goals (batch creation):**
Use array indices: [0, 1, 2]

**Across goals or existing tasks:**
Use identifiers: ["W47", "W48"]

**DON'T specify identifiers when creating:**
System auto-generates (G1, W47, D12, etc.)

## Red Flags - STOP
- "I'll use 'tasks' as the root key"
- "I'll specify identifiers for new tasks"
- "Dependencies across goals will work in batch"
- "I'll skip nested task details"

## Rationalization Table
| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "'tasks' works too" | API requires "goals" root key | 422 error, batch rejected entirely |
| "I'll add identifiers" | System auto-generates them | Validation error, creation fails |
| "Cross-goal deps work" | Only within-goal indices work | Dependencies ignored silently |
| "Simple nested tasks" | Each must follow full task spec | Minimal nested tasks fail same way |

## Quick Reference Card

```
BATCH CREATION FORMAT:
{
  "goals": [  ← MUST be "goals" not "tasks"
    {
      "title": "Goal Title",
      "type": "goal",
      "complexity": "large",
      "tasks": [
        {
          "title": "Task 1",
          "type": "work",
          // Full task spec required!
        },
        {
          "title": "Task 2",
          "type": "work",
          "dependencies": [0]  ← Array index
        }
      ]
    }
  ]
}

DEPENDENCY RULES:
├─ Within goal → Use indices [0, 1, 2]
├─ Existing tasks → Use IDs ["W47", "W48"]
├─ Across goals in batch → DON'T (create sequentially)
└─ Never specify IDs for new tasks (auto-generated)
```
```

---

## Skill Dependencies and Hierarchy

```
stride-creating-goals
  └─ REQUIRES: stride-creating-tasks (for nested task structure)

stride-completing-tasks
  └─ REQUIRES: (none, standalone)

stride-claiming-tasks
  └─ REQUIRES: (none, standalone)

stride-creating-tasks
  └─ REQUIRES: (none, foundational)
```

**Implementation Order:**
1. `stride-creating-tasks` (foundational, no dependencies)
2. `stride-claiming-tasks` (standalone workflow)
3. `stride-completing-tasks` (standalone workflow)
4. `stride-creating-goals` (builds on creating-tasks)

---

## Hook Integration Pattern

All skills that involve hooks will follow this pattern for instructing Claude:

### Reading Hook Scripts

```markdown
1. Read the .stride.md file
2. Locate the section matching the hook name (## before_doing, ## after_doing, etc.)
3. Extract all lines between that header and the next ## header
4. This is your hook script
```

### Setting Environment Variables

```markdown
The Stride API returns hook metadata including environment variables:
- Set each env var from hook.env before executing
- Common vars: TASK_ID, TASK_IDENTIFIER, TASK_TITLE, etc.
```

### Executing Hooks

```markdown
1. Execute the hook script using Bash tool
2. Set timeout based on hook type:
   - before_doing: 60s
   - after_doing: 120s
   - before_review: 60s
   - after_review: 60s
3. All hooks are blocking (before_doing, after_doing, before_review, after_review):
   - If exit code ≠ 0: STOP, fix issues, do not proceed with API calls
```

---

## File Structure and Storage

**Skills will be stored in:**
```
~/.claude/plugins/cache/superpowers-marketplace/superpowers/4.0.3/skills/
  stride-claiming-tasks/
    SKILL.md
  stride-completing-tasks/
    SKILL.md
  stride-creating-tasks/
    SKILL.md
  stride-creating-goals/
    SKILL.md
```

**Each SKILL.md follows:**
```markdown
---
name: skill-name-with-hyphens
description: Use when [specific trigger], before [specific action]
---

[Skill content with enforcement patterns]
```

---

## Testing Strategy

For each skill, create pressure scenarios to validate enforcement:

### Test 1: Baseline Without Skill
- Give agent a task that should trigger the skill
- Document all shortcuts and rationalizations made
- Identify specific failure patterns

### Test 2: With Skill Present
- Same task, but skill is available
- Verify agent invokes skill before acting
- Confirm workflow follows skill exactly

### Test 3: Rationalization Pressure
- Add time pressure ("quick task")
- Add confidence pressure ("I know this works")
- Verify skill's Red Flags and Rationalization Tables prevent shortcuts

### Test 4: Edge Cases
- Missing .stride.md or .stride_auth.md
- Hook execution failures
- API errors
- Verify skill handles errors gracefully

---

## References to Existing Documentation

Skills should reference these existing files:

- **Task Writing Guide:** `/Users/cheezy/dev/elixir/kanban/docs/TASK-WRITING-GUIDE.md`
- **AI Workflow Guide:** `/Users/cheezy/dev/elixir/kanban/docs/AI-WORKFLOW.md`
- **API Reference:** `/Users/cheezy/dev/elixir/kanban/docs/api/README.md`
- **Hook Execution Guide:** `/Users/cheezy/dev/elixir/kanban/docs/AGENT-HOOK-EXECUTION-GUIDE.md`
- **Onboarding Endpoint:** `https://www.stridelikeaboss.com/api/agent/onboarding`

Skills can also instruct agents to WebFetch these URLs for latest information.

---

## Coordination with Existing Files

**Keep existing `.claude/commands/stride.md` slash command:**
- Provides quick reference for experienced users
- Skills are for enforcement, slash command is for documentation

**Both can coexist:**
- `/stride` = quick API reference
- Skills = mandatory workflow enforcement

---

## Implementation Checklist

When implementing these skills:

- [ ] Create skill directory structure in `~/.claude/plugins/cache/superpowers-marketplace/superpowers/4.0.3/skills/`
- [ ] Write `stride-creating-tasks/SKILL.md` first (foundational)
- [ ] Test baseline vs. with-skill scenarios
- [ ] Write `stride-claiming-tasks/SKILL.md` second
- [ ] Test claiming workflow with hook execution
- [ ] Write `stride-completing-tasks/SKILL.md` third
- [ ] Test completion workflow with all hooks
- [ ] Write `stride-creating-goals/SKILL.md` fourth
- [ ] Test batch creation with correct format
- [ ] Document all rationalization patterns encountered during testing
- [ ] Add Red Flags sections based on real agent shortcuts observed
- [ ] Verify skills are discoverable (test with fresh Claude session)

---

## Success Criteria

Skills are successful when:

1. **Agents invoke skills automatically** - No manual reminders needed
2. **Hook execution is never skipped** - 100% compliance with before_doing and after_doing
3. **Tasks are comprehensive** - No more 3+ hour exploration on minimal tasks
4. **Batch creation uses correct format** - "goals" root key, proper dependencies
5. **Review workflow is respected** - Agents stop when needs_review=true

---

## Future Enhancements

Possible additions after initial 4 skills:

- `stride-handling-review-feedback` - For processing review requests/approvals
- `stride-unclaiming-tasks` - For releasing blocked tasks
- `stride-debugging-api-errors` - For troubleshooting 401, 422, etc.
- `stride-session-initialization` - For starting new Stride sessions (fetch onboarding, verify config)

---

## Notes

- Skills are documentation, not executable code
- They instruct Claude, who then uses tools (Bash, Read, WebFetch, etc.)
- Enforcement comes from language patterns, not technical restrictions
- Test-driven skill development prevents agent rationalization
- Balance between comprehensive and scannable - use tables and flowcharts

---

## Timeline (Optional)

**Not included per user request** - This is a reference document for future implementation when ready.

---

## Contact / Questions

When implementing, revisit:
1. Superpowers skill writing guide: `superpowers:writing-skills`
2. Existing enforcement patterns in TDD, debugging, verification skills
3. Stride documentation for latest API changes

This plan serves as a complete specification for creating Stride Superpowers skills that enforce workflow discipline and hook execution for AI agents.
