You are working with the Stride task management system. Here's what you need to know:

## Current Session Context

**Stride API**: https://www.stridelikeaboss.com
**Authentication**: Bearer token in `.stride_auth.md` (NEVER commit this file)
**Hooks**: Defined in `.stride.md` (version controlled)

## Essential Workflow

1. **Claim**: `POST /api/tasks/claim` with `Authorization: Bearer <token>`
2. **Execute before_doing hook**: Run the bash script from `.stride.md` (blocking, must succeed)
3. **Do the work**: Follow key_files, acceptance_criteria, verification_steps from task
4. **Execute after_doing hook**: Run tests/checks from `.stride.md` (blocking, must pass)
5. **Complete**: `PATCH /api/tasks/:id/complete`
6. **Execute before_review and after_review hooks** as returned
7. **Continue or stop**:
   - If `needs_review=false`: IMMEDIATELY claim next task
   - If `needs_review=true`: STOP and wait for human review

## Key Points to Remember

- **All hooks execute CLIENT-SIDE** by reading `.stride.md`
- **Blocking hooks** (before_doing, after_doing) must pass or task action fails
- **Non-blocking hooks** (before_review, after_review) run but don't block progression
- **Task identifiers are auto-generated** - never specify G1, W42, D5 manually
- **Create detailed tasks** with key_files, verification_steps, testing_strategy, acceptance_criteria

## Documentation

Read these files for complete details:
- `docs/AI-WORKFLOW.md` - Full workflow guide
- `docs/TASK-WRITING-GUIDE.md` - Task creation schema
- `docs/AGENT-HOOK-EXECUTION-GUIDE.md` - Hook execution details
- `docs/AGENT-CAPABILITIES.md` - Capability matching
- `docs/REVIEW-WORKFLOW.md` - Review vs auto-complete

## Quick API Reference

```bash
# Claim next task
curl -H "Authorization: Bearer $TOKEN" \
  https://www.stridelikeaboss.com/api/tasks/claim

# Complete task (after running hooks)
curl -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  https://www.stridelikeaboss.com/api/tasks/123/complete

# Mark reviewed (if needs_review=true)
curl -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  https://www.stridelikeaboss.com/api/tasks/123/mark_reviewed
```

Now continue with your Stride workflow. If you need to claim a task, do it now.
