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

**Description:** "Use when you want to claim a task from Stride, before making any API calls to /api/tasks/claim"

**Purpose:** Enforce the proper claiming workflow including hook execution

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

## Red Flags - STOP
- "I'll just claim quickly and run hooks later"
- "The hook is just git pull, I can skip it"

## Rationalization Table
| Excuse | Reality |
|--------|---------|
| "This is urgent" | Hooks prevent merge conflicts |
| "I know the code is current" | Hooks ensure consistency |
```

---

### Skill 2: `stride-completing-tasks`

**Description:** "Use when you've finished work on a Stride task and need to mark it complete, before calling /api/tasks/:id/complete"

**Purpose:** Enforce proper completion workflow with after_doing hook BEFORE completion endpoint

**Key Sections:**
- **The Iron Law:** EXECUTE AFTER_DOING BEFORE CALLING COMPLETE
- **The Critical Mistake** (why calling complete before validation fails)
- **The Complete Completion Process**
- **Hook Execution Pattern** (after_doing, before_review, after_review)
- **Review vs. Auto-Approval Decision Tree**
- **Red Flags**
- **Rationalization Table**

**Enforcement Strategy:**
- Must invoke BEFORE calling `/api/tasks/:id/complete`
- Must execute after_doing hook first (blocking, 120s)
- Must only call complete endpoint AFTER hook succeeds
- Must handle review cycle properly based on needs_review flag

**Content Outline:**
```markdown
## The Iron Law
EXECUTE after_doing HOOK BEFORE CALLING COMPLETE ENDPOINT

## The Critical Mistake
Calling PATCH /api/tasks/:id/complete before running after_doing causes:
- Task marked done prematurely
- Failed tests hidden
- Quality gates bypassed

## The Complete Completion Process
1. Mark todo as in_progress: "Completing task"
2. Read .stride.md after_doing section
3. Execute after_doing hook (120s timeout, blocking)
4. If hook fails: FIX ISSUES, do not proceed
5. If hook succeeds: Call PATCH /api/tasks/:id/complete
6. Execute before_review hook (60s, non-blocking)
7. If needs_review=true: STOP and wait
8. If needs_review=false: Execute after_review hook

## Review Decision Flowchart
[Flowchart showing needs_review true/false paths]

## Red Flags - STOP
- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
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
- [ ] title (clear, specific)
- [ ] type ("work", "defect", or "goal")
- [ ] description (WHY and WHAT)
- [ ] complexity ("small", "medium", "large")
- [ ] key_files (prevents merge conflicts)
- [ ] verification_steps (objects with step_type, step_text, expected_result)
- [ ] testing_strategy (unit_tests, integration_tests, edge_cases)
- [ ] acceptance_criteria
- [ ] patterns_to_follow
- [ ] pitfalls

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

## Verification Steps Pattern (CRITICAL)
MUST be array of objects, NOT strings:
```json
"verification_steps": [
  {
    "step_type": "command",
    "step_text": "mix test path/to/test.exs",
    "expected_result": "All tests pass",
    "position": 0
  }
]
```

## Red Flags - STOP
- "I'll just create a simple task"
- "The agent can figure out the details"
- "This is self-explanatory"
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
  "goals": [  // ← MUST be "goals"
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
3. For blocking hooks (before_doing, after_doing):
   - If exit code ≠ 0: STOP, fix issues, do not proceed
4. For non-blocking hooks (before_review, after_review):
   - Log errors but continue workflow
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
