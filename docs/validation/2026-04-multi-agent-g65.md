# Validation: G65 Port to Cursor / Windsurf / Continue.dev / Kimi Code

**Goal:** G67 — Bring Cursor/Windsurf/Continue.dev/Kimi Code support current with G65 completion-validation gate
**Date:** 2026-04-17
**Validator:** Claude Opus 4.7 (the agent that performed W261–W267)
**Status:** End-to-end validated in grace mode; strict-mode rejection path **pending W242** flip

---

## What was ported

G65 shipped hard enforcement of `explorer_result` and `reviewer_result` on `/api/tasks/:id/complete` plus the `workflow_steps` telemetry array. The 5 dedicated plugin repos (stride, stride-copilot, stride-gemini, stride-codex, stride-opencode) were updated on 2026-04-17. The shared multi-agent skills served to Cursor, Windsurf, Continue.dev, and Kimi Code were pre-G65 until G67.

G67 tasks completed in this session:

| Task | Artifact | Status |
|---|---|---|
| W261 | `docs/multi-agent-instructions/skills/stride-completing-tasks/SKILL.md` — 5 G65 touch points ported | ✅ |
| W262 | `docs/multi-agent-instructions/skills/stride-workflow/SKILL.md` — Step 8 payload, Workflow Telemetry section, Rollout section | ✅ |
| W263 | `docs/multi-agent-instructions/skills/stride-claiming-tasks/SKILL.md` — exploration-capture guidance | ✅ |
| W264 | `docs/multi-agent-instructions/AGENTS.md` — Completion Validation Requirements (G65) subsection for Kimi | ✅ |
| W265 | `docs/MULTI-AGENT-INSTRUCTIONS.md` — Core Content item 6 | ✅ |
| W266 | `lib/kanban_web/controllers/api/agent_json.ex` — description strings for all 4 platforms | ✅ |
| W267 | `test/kanban_web/controllers/api/agent_controller_test.exs` — 6 new G65 content-validation tests | ✅ |

## Validation results

### 1. Skill file content — G65 tokens present

Local file audit on 2026-04-17 after W261–W265 landed:

```
docs/multi-agent-instructions/skills/stride-completing-tasks/SKILL.md: 23 G65 matches
docs/multi-agent-instructions/skills/stride-workflow/SKILL.md:         16 G65 matches
docs/multi-agent-instructions/skills/stride-claiming-tasks/SKILL.md:    2 G65 matches
docs/multi-agent-instructions/AGENTS.md:                               10 G65 matches
```

Each of the 5 skip-reason enum values (`no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`) is present in `stride-completing-tasks/SKILL.md`, along with the 40-char rule and the `:strict_completion_validation` grace-period rollout wording.

### 2. Onboarding endpoint — platform descriptions (local build)

After W266, each of the 4 platform entries in `agent_json.ex` has G65 tokens in its description. Local test suite confirms:

```
$ mix test test/kanban_web/controllers/api/agent_controller_test.exs
Running ExUnit with seed: ..., max_cases: 16
..................................................
Finished in 0.3 seconds
50 tests, 0 failures
```

Of the 50 tests, 6 are the new W267 G65 content-validation tests:

1. `Cursor description mentions G65 completion-validation requirement`
2. `Windsurf description mentions G65 completion-validation requirement`
3. `Continue.dev description mentions G65 completion-validation requirement`
4. `Kimi description mentions G65 completion-validation requirement`
5. `stride-completing-tasks SKILL.md contains G65 completion-validation content` (asserts 9 tokens including all 5 skip-reason enum values)
6. `stride-workflow SKILL.md and AGENTS.md contain G65 core tokens` (asserts 4 core tokens in both files)

Each test will **fail** if the corresponding G65 content is removed, providing ongoing regression protection.

### 3. Onboarding endpoint — production state

At time of this validation, the production endpoint at `https://www.stridelikeaboss.com/api/agent/onboarding` **still returns the pre-W266 descriptions** for all 4 platforms:

```json
"cursor": {
  "description": "Stride skills for Cursor — 7 skills including the stride-workflow orchestrator, downloaded into .cursor/skills/ for auto-discovery"
  // no G65 mention yet
}
```

This is expected — the W266 commit is local and the next production deploy will ship it. The served skill URLs (`#{docs_base_url}/docs/multi-agent-instructions/skills/...`) resolve to `raw.githubusercontent.com/cheezy/kanban/refs/heads/main/...`, so once commits are pushed, fresh agents fetching the skills will get the G65-updated content immediately — no code deploy required for the skill content itself.

### 4. Happy-path completion — live validation across all 4 platforms

**Every task completed in this session (W261 through W267) used the exact `/complete` payload shape that Cursor/Windsurf/Continue/Kimi agents are now instructed to use.** Each completion included:

- `explorer_result` — dispatched shape for medium tasks (W261, W262, W267), skip-form with enum `reason` for small tasks (W263–W266)
- `reviewer_result` — same pattern
- `workflow_steps` — full six-entry array with appropriate `dispatched`/`reason` combinations per phase

All 7 completions returned HTTP 200 with `status: completed`. The server's `Kanban.Tasks.CompletionValidation` module accepted every payload. This is live evidence that the skill-prescribed payload format is server-valid. Example of the skip-form used for a small task:

```json
"explorer_result": {
  "dispatched": false,
  "reason": "small_task_0_1_key_files",
  "summary": "Decision matrix: small task with 1 key_file. Grepped for ..."
}
```

### 5. Missing-field rejection path — deferred

The rollout-specific 422 rejection path (strict mode) could not be validated in this session because `:strict_completion_validation` remains `false` in production runtime config. That flip is tracked by **W242** (still open) and requires:

- 7-day minimum grace period from the plugin releases
- Soft-warn log review
- 24 hours of post-flip metric monitoring

Once W242 flips the flag, the 422-with-failures-list behavior will be observable. The server-side gate logic (`Kanban.KanbanWeb.Api.CompletionResultGate`) and validation module (`Kanban.Tasks.CompletionValidation`) already carry unit-test coverage for the rejection path (see `test/kanban/tasks/completion_validation_test.exs` and controller tests).

**Recommendation:** Do not flip strict mode until G72 (onboarding + canonical docs G65 updates) also lands, or agents fetching from the canonical `docs/api/patch_tasks_id_complete.md` will still get the pre-G65 contract and hit 422 with no guidance.

### 6. Grace-mode soft-warn — pending log inspection

Every in-session completion was grace-mode. If any soft-warn logs were emitted for malformed `explorer_result`/`reviewer_result` fields, they would appear in the server-side Logger output. This validation does not have direct access to production logs. Recommended follow-up: during W242, tail the production logs for the `completion_result_gate:warn` events and confirm volume drops to near-zero (or to a small list of agents still on pre-G65 plugins) before flipping strict.

## Findings / action items

1. **Commits need to reach `main` before fresh agents see the new skills.** Skills are served from `raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/...` — the push to `main` is the deploy action for skill content.
2. **W266 `agent_json.ex` change needs a production deploy** before the onboarding endpoint returns updated descriptions.
3. **Do not let W242 (strict flip) precede G72 (canonical docs + api_schema updates).** G72 is already open and prioritized high.
4. **Minor cosmetic issue noted in W261 review — deferred.** The Quick Reference Card in `stride-completing-tasks/SKILL.md` uses `"<enum>"` placeholder; enum is listed immediately below. Tracked as non-blocking.

## Conclusion

All of G67's port objectives are met. Shared skills and AGENTS.md now instruct agents on Cursor, Windsurf, Continue.dev, and Kimi Code how to emit the G65-required fields, using skip-form payloads appropriate for no-subagent platforms. Local tests assert the content is present and will fail if it's removed. The happy-path `/complete` flow was validated 7 times against production during this very session. The rejection path is deferred to W242. The only gap between code and production behavior is the pending deploy of `agent_json.ex` and the pending push of the skill-file commits to `main`.
