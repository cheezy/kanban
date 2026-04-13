---
name: stride-subagent-workflow
description: MANDATORY after claiming any Stride task (Claude Code only). Contains the decision matrix for dispatching stride:task-explorer, stride:task-reviewer, stride:task-decomposer, and stride:hook-diagnostician agents. Skipping means no codebase exploration before implementation and no code review before completion — causing wrong approaches and missed acceptance criteria. Invoke IMMEDIATELY after claim succeeds, BEFORE writing any code.
compatibility: cursor, windsurf, continue, kimi
skills_version: 1.0
---

# Stride: Subagent Workflow

## ⚠️ THIS SKILL IS MANDATORY AFTER CLAIMING — NOT OPTIONAL ⚠️

**If you just claimed a Stride task and are about to start implementation, you MUST invoke this skill first.**

This skill contains the decision matrix that determines which agents to dispatch:
- `stride:task-explorer` — Read key_files and discover patterns before coding
- `stride:task-reviewer` — Review your changes against acceptance criteria before completion
- `stride:task-decomposer` — Break goals into properly-sized subtasks
- `stride:hook-diagnostician` — Diagnose hook failures with prioritized fix plans

**Skipping this skill means:**
- No codebase exploration before implementation (wrong approach, 2+ hours wasted)
- No code review before completion hooks (acceptance criteria violations missed)
- No goal decomposition (goals attempted as monolithic work)

**Skill chain position:** `stride:stride-claiming-tasks` → **THIS SKILL** → implementation → `stride:stride-completing-tasks`

## Overview

**Coding without context = wrong approach and rework. Exploring and planning first = confident, first-pass quality.**

This skill orchestrates subagents at four points in the Stride workflow: decomposition for goals, exploration after claiming, planning for complex tasks, and code review before completion hooks. It tells you WHEN to dispatch each subagent — the agents themselves handle the HOW.

## Claude Code Only

This skill requires the Claude Code Agent tool with access to subagent types. If you are not running in Claude Code (e.g., Cursor, Windsurf, Continue, Kimi Code), skip this skill entirely and proceed directly to implementation using the task's `key_files`, `patterns_to_follow`, and `acceptance_criteria` as your guide.

## The Iron Law

**DISPATCH SUBAGENTS BASED ON TASK COMPLEXITY — NEVER SKIP FOR MEDIUM/LARGE TASKS, NEVER ADD OVERHEAD FOR SIMPLE TASKS**

## The Critical Mistake

Skipping exploration and planning for complex tasks causes:
- Implementing the wrong approach (2+ hours wasted)
- Missing existing patterns and utilities (duplicate code)
- Violating pitfalls the task author explicitly warned about
- Failing acceptance criteria discovered too late

Adding subagent overhead to simple tasks causes:
- Unnecessary context window consumption
- Slower task completion with no quality benefit
- Exploration of files that don't need understanding

## When to Use

Invoke this skill **after claiming a task** (via `stride-claiming-tasks`) and **before beginning implementation**. Also invoke the Code Review section **after implementation** but **before running the after_doing hook** (via `stride-completing-tasks`).

## Decision Matrix

Use this matrix to determine which subagents to dispatch based on task attributes:

| Task Attributes | stride:task-decomposer | stride:task-explorer | Plan Agent | stride:task-reviewer |
|---|---|---|---|---|
| small, 0-1 key_files | Skip | Skip | Skip | Skip |
| small, 2+ key_files | Skip | Run | Skip | Run |
| medium (any) | Skip | Run | Run | Run |
| large (any) | Skip | Run | Run | Run |
| Defect type | Skip | Run | Skip (unless large) | Run |
| Goal type | Run | Skip* | Skip* | Skip* |
| Large complexity, not yet decomposed | Run | Skip* | Skip* | Skip* |
| 25+ hour estimate, not yet decomposed | Run | Skip* | Skip* | Skip* |

*After decomposition, each resulting child task follows its own row in this matrix when claimed individually.

**Quick rules:**
- If the task is a **goal** or has **large complexity without child tasks** or a **25+ hour estimate**: dispatch the decomposer first. The decomposer breaks it into claimable child tasks — you don't implement goals directly.
- If the task is small with 0-1 key_files, skip all subagents and code directly.
- Otherwise, at minimum run the explorer and reviewer.

## Phase 0: Decomposition (Goals and Large Undecomposed Tasks)

**When:** Task type is `goal`, OR task has `large` complexity with no child tasks, OR task has a 25+ hour estimate.

**What to do:** Dispatch the `stride:task-decomposer` agent, passing the goal/task metadata.

Provide the agent with:
- The task's `title` and `description`
- The task's `acceptance_criteria`
- The task's `key_files` array (if any)
- The task's `where_context` text
- The task's `patterns_to_follow` text
- The project's technology stack context

The decomposer will return an ordered list of child tasks with:
- Titles and descriptions for each task
- Dependency ordering between tasks
- Complexity estimates per task
- Key files and testing strategies per task

**After decomposition:**
1. Use `POST /api/tasks` or `POST /api/tasks/batch` to create the child tasks under the goal
2. Do NOT implement the goal directly — claim and implement the child tasks individually
3. Each child task follows its own row in the Decision Matrix when claimed

**Skip decomposition when:**
- Task type is `work` or `defect` (already at implementation level)
- Goal already has child tasks (already decomposed)
- Task complexity is `small` or `medium` without a 25+ hour estimate

## Phase 1: Exploration (After Claim, Before Coding)

**When:** Task complexity is medium or large, OR task has 2+ key_files.

**What to do:** Dispatch the `stride:task-explorer` agent, passing the task metadata.

Provide the agent with:
- The task's `key_files` array (file paths and notes)
- The task's `patterns_to_follow` text
- The task's `where_context` text
- The task's `testing_strategy` object

The explorer will return a structured summary of: each key file's current state, related test files, existing patterns found, and module APIs to reuse.

**Use the explorer's output** to inform your implementation — don't discard it. It tells you what exists, what patterns to follow, and what utilities to reuse.

## Phase 2: Planning (Conditional, Before Coding)

**When:** Task complexity is medium or large, OR task has 3+ key_files, OR task has 3+ acceptance criteria lines.

**What to do:** Dispatch a **Plan** subagent (built-in type, not a custom agent), passing:
- The explorer's output from Phase 1
- The task's `acceptance_criteria`
- The task's `testing_strategy`
- The task's `pitfalls` array
- The task's `verification_steps`

The Plan agent will return an ordered implementation plan. Follow this plan during implementation.

**Skip planning for:** Small tasks, defects (unless large), tasks with simple/obvious implementations.

## Phase 3: Code Review (After Implementation, Before Hooks)

**When:** Task complexity is medium or large, OR task has 2+ key_files. Skip only for small tasks with 0-1 key_files.

**What to do:** Dispatch the `stride:task-reviewer` agent, passing:
- The git diff of all your changes
- The task's `acceptance_criteria`
- The task's `pitfalls` array
- The task's `patterns_to_follow` text
- The task's `testing_strategy` object

The reviewer will return either "Approved" or a list of issues categorized as Critical, Important, or Minor.

**Capture the reviewer's output as `review_report`:** Save the full structured review output returned by the task-reviewer agent. You will include this as the `review_report` field in the completion API call (via `stride-completing-tasks`). Capture it regardless of whether the review found issues — an "Approved" report is still valuable for traceability. When the reviewer is skipped (small tasks with 0-1 key_files), simply omit `review_report` from the completion call.

**If issues are found:**
- Fix all Critical issues before proceeding
- Fix Important issues before proceeding
- Minor issues are optional but recommended
- After fixing, you do NOT need to re-run the reviewer — proceed to the after_doing hook

## Workflow Flowchart

```
Task Claimed
    |
    v
Is it a goal OR large+undecomposed OR 25+ hours?
    |
    +--> YES --> Dispatch stride:task-decomposer
    |               |
    |               v
    |           Create child tasks via API
    |               |
    |               v
    |           Claim first child task --> (re-enter this flowchart)
    |
    +--> NO --> Check decision matrix
                    |
                    +--> Small, 0-1 key_files? --> Skip all subagents --> Begin implementation
                    |
                    +--> Medium/Large OR 2+ key_files?
                            |
                            v
                        Dispatch stride:task-explorer
                            |
                            v
                        Medium/Large OR 3+ key_files OR 3+ criteria?
                            |
                            +--> YES --> Dispatch Plan agent
                            |             |
                            |             v
                            +--> NO  --> Begin implementation (using explorer output)
                            |
                            v
                        Begin implementation (using explorer + plan output)
                            |
                            v
                        Implementation complete
                            |
                            v
                        Check decision matrix for reviewer
                            |
                            +--> Small, 0-1 key_files? --> Skip reviewer --> Run after_doing hook
                            |
                            +--> Otherwise --> Dispatch stride:task-reviewer
                                                |
                                                v
                                            Issues found?
                                                |
                                                +--> YES --> Fix issues --> Run after_doing hook
                                                |
                                                +--> NO  --> Run after_doing hook
```

## Red Flags - STOP

- "This medium task is straightforward, I'll skip exploration"
- "I already know the codebase, no need to explore"
- "Planning takes too long, I'll just start coding"
- "The code review will slow me down"
- "I'll review my own code, no need for the reviewer agent"

**All of these lead to: wrong approach, missed patterns, violated pitfalls, and rework.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "I know this codebase" | Task metadata has specific patterns/pitfalls | Missed pitfalls cause rework |
| "It's obvious what to do" | Medium+ tasks have hidden complexity | Wrong approach wastes 2+ hours |
| "Exploration is slow" | Explorer runs in 10-30 seconds | Skipping costs 1+ hour of undirected reading |
| "Planning is overkill" | Plans catch wrong approaches early | Coding without a plan doubles rework rate |
| "I'll catch issues in tests" | Tests miss acceptance criteria gaps | Reviewer catches what tests can't |
| "This small task has 3 key_files" | 2+ key_files = explore | Missing context causes merge conflicts |

## Quick Reference Card

```
SUBAGENT WORKFLOW:
├─ 0. Task claimed successfully
├─ 1. Is it a goal OR large+undecomposed OR 25+ hours?
│     ├─ YES → Dispatch stride:task-decomposer
│     ├─ Create child tasks via API
│     └─ Claim first child task (re-enter workflow)
├─ 2. Check decision matrix (complexity + key_files count)
├─ 3. If medium+ OR 2+ key_files:
│     ├─ Dispatch stride:task-explorer with task metadata
│     └─ Read and use the explorer's output
├─ 4. If medium+ OR 3+ key_files OR 3+ criteria:
│     ├─ Dispatch Plan agent with explorer output + task metadata
│     └─ Follow the resulting plan
├─ 5. Implement the task
├─ 6. If medium+ OR 2+ key_files:
│     ├─ Dispatch stride:task-reviewer with diff + task metadata
│     └─ Fix any Critical/Important issues found
└─ 7. Proceed to after_doing hook (stride-completing-tasks)

CUSTOM AGENTS:
  stride:task-decomposer - Breaks goals into dependency-ordered child tasks
  stride:task-explorer   - Reads key_files, finds tests, searches patterns
  stride:task-reviewer   - Reviews diff against acceptance criteria & pitfalls

BUILT-IN AGENTS:
  Plan                   - Designs implementation approach from task metadata

DISPATCH DECOMPOSER WHEN:
  Task type is goal, OR large complexity without children, OR 25+ hour estimate

SKIP ALL OTHER SUBAGENTS WHEN:
  Task is small complexity AND has 0-1 key_files
```

## MANDATORY: Skill Chain Position

This skill sits between claiming and completing in the workflow:

1. **`stride:stride-claiming-tasks`** ← You should have invoked this BEFORE this skill
2. **`stride:stride-subagent-workflow`** ← YOU ARE HERE
3. **`stride:stride-completing-tasks`** ← Invoke WHEN implementation is done

**FORBIDDEN:** Skipping from claiming directly to completing without checking the decision matrix here. Even for small tasks, you must check the matrix — it takes 5 seconds and prevents wrong decisions.

---
**References:** This skill works with `stride-claiming-tasks` (invoke after claim) and `stride-completing-tasks` (code review before hooks). Agent definitions are in `stride/agents/task-decomposer.md`, `stride/agents/task-explorer.md`, and `stride/agents/task-reviewer.md`.
