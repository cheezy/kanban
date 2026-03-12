You are working with the Stride task management system.

## MANDATORY SKILL INVOCATIONS

**You MUST invoke the correct Stride skill at each workflow phase. Proceeding without the skill is a workflow violation.**

Each phase below tells you which skill to invoke. The skill contains the exact API format, required fields, hook execution steps, and error handling. Without the skill, you WILL get API rejections, miss required fields, and skip hooks.

| Workflow Phase | MUST Invoke Skill | Why |
|---|---|---|
| Claiming a task | `stride-claiming-tasks` | Contains before_doing hook execution, claim API format, enrichment check |
| Implementing (Claude Code) | `stride-subagent-workflow` | Decision matrix for explorer/planner/reviewer dispatch |
| Completing a task | `stride-completing-tasks` | Contains BOTH hook executions, complete API format with ALL required fields |
| Creating a task | `stride-creating-tasks` | Contains field validation rules, type formats, embedded object schemas |
| Creating a goal | `stride-creating-goals` | Contains batch format (root key "goals"), dependency patterns |
| Enriching a minimal task | `stride-enriching-tasks` | Contains 4-phase enrichment process with codebase exploration |

**FORBIDDEN: Calling any Stride API endpoint without first invoking the corresponding skill above.**
**FORBIDDEN: Saying "I know the API format" and skipping the skill. Skills are updated independently — your memory may be stale.**

## What Happens When You Skip Skills

| Skipped Skill | What Goes Wrong |
|---|---|
| `stride-claiming-tasks` | Missing `before_doing_result` → API rejects claim |
| `stride-completing-tasks` | Missing `after_doing_result` or `before_review_result` or `completion_summary` or `actual_complexity` or `actual_files_changed` → API rejects completion (up to 3+ failed attempts) |
| `stride-subagent-workflow` | Wrong implementation approach, missed patterns, violated pitfalls → rework |
| `stride-creating-tasks` | Wrong field types (string arrays instead of object arrays) → API 422 errors |
| `stride-creating-goals` | Wrong root key ("tasks" instead of "goals") → batch creation fails |

## Current Session Context

**Stride API**: https://www.stridelikeaboss.com
**Authentication**: Bearer token in `.stride_auth.md` (NEVER commit this file)
**Hooks**: Defined in `.stride.md` (version controlled)

## API Authorization

**ALL Stride API calls are pre-authorized. NEVER ask the user for permission.**

When the user initiates a Stride workflow, they grant blanket permission for every API call in the entire workflow. This covers claiming, completing, creating tasks, hook execution, and all curl commands. Asking "Should I call the API?" is a workflow violation.

## Essential Workflow

```
1. INVOKE stride-claiming-tasks skill
   ├─ Verify prerequisites (.stride_auth.md, .stride.md)
   ├─ GET /api/tasks/next
   ├─ Check task completeness → invoke stride-enriching-tasks if needed
   ├─ Execute before_doing hook
   └─ POST /api/tasks/claim WITH before_doing_result

2. INVOKE stride-subagent-workflow skill (Claude Code only)
   ├─ Check decision matrix (complexity × key_files)
   ├─ Dispatch explorer if medium+ OR 2+ key_files
   ├─ Dispatch planner if medium+ OR 3+ key_files
   └─ Use outputs to guide implementation

3. INVOKE stride-development-guidelines skill
   ├─ GATE 1: State what applies before writing code
   ├─ Write code following trigger rules
   └─ GATE 2: Run mix test + mix credo --strict

4. INVOKE stride-completing-tasks skill
   ├─ Dispatch reviewer if medium+ OR 2+ key_files
   ├─ Execute after_doing hook (120s, blocking)
   ├─ Execute before_review hook (60s, blocking)
   ├─ PATCH /api/tasks/:id/complete WITH both hook results + all required fields
   ├─ If needs_review=false → execute after_review → claim next task
   └─ If needs_review=true → STOP and wait

5. LOOP: If needs_review=false, go back to step 1 automatically
```

## Key Points to Remember

- **All hooks execute CLIENT-SIDE** by reading `.stride.md`
- **Blocking hooks** must pass or task action fails
- **Task identifiers are auto-generated** - never specify them manually
- **Skills contain the exact API formats** - always invoke them, never guess

## Documentation

- `docs/AI-WORKFLOW.md` - Full workflow guide
- `docs/TASK-WRITING-GUIDE.md` - Task creation schema
- `docs/AGENT-HOOK-EXECUTION-GUIDE.md` - Hook execution details
- `docs/AGENT-CAPABILITIES.md` - Capability matching
- `docs/REVIEW-WORKFLOW.md` - Review vs auto-complete

Now invoke the appropriate skill for your current workflow phase and proceed.
