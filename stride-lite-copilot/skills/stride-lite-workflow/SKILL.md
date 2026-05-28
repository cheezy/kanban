---
name: stride-lite-workflow
description: |
  Activate ONLY when the user explicitly states intent to work on a stride-lite-copilot goal (e.g., "work this goal", "drive the X goal to completion", "process all tasks in <path>", "resume the X goal") AND supplies a path to a goal directory (either inline in the same turn, or as a follow-up answer to a clarifying question from the agent). Without BOTH the intent statement AND the path, do not activate — the user might want one-off work on a single task, manual inspection, or some other unrelated operation. Once activated, the skill drives the goal through its full eight-step lifecycle for every taskN.md in numeric order: select the next incomplete task → `## before_task` hook (auto-fired by hooks/hooks.json pre-explorer-dispatch) → dispatch `stride-lite-copilot:task-explorer` to enrich the task with codebase context → implement the code changes per the task's acceptance criteria → `## after_task` hook (auto-fired pre-reviewer-dispatch) → dispatch `stride-lite-copilot:task-reviewer` to validate the diff → if review approved proceed, else loop back to coding (cap: 3 iterations) → write a `## Completion Summary` to the task file → advance to the next taskN.md. The skill exits cleanly ONLY after the final task's Completion Summary is written, `goal.md` has its Completion Summary appended, and the `## after_goal` hook has auto-fired (PostToolUse on the goal.md Edit/Write). Do not re-enter the loop after exit; subsequent goals require a fresh activation with a new path. The skill is the file-based equivalent of the full Stride plugin's `stride-workflow` orchestrator: no API calls, no claim/complete server endpoints, no kanban authentication — only goal/task markdown files, the project-local `.stride_lite.md` hook file, and the two existing stride-lite subagents. Examples: <example>Context: User has run the stride-lite-create-goal skill and now wants to drive the resulting goal through implementation. user: "Work the docs/implementation/PENDING/add-real-time-notifications-for-board-comments goal." assistant: "Activating stride-lite-workflow with that path as goal_directory_path; the skill will iterate task1.md, task2.md, task3.md in order until every task and goal.md has a Completion Summary, then exit." <commentary>Both conditions are met in a single turn: explicit intent ("Work the X goal") + path supplied inline. The skill iterates every taskN.md and exits only after Step 8's final-task branch runs.</commentary></example> <example>Context: User states intent without a path. user: "Let's work on a stride-lite-copilot goal." assistant: "Which goal directory? Please give me the path (e.g., docs/implementation/PENDING/add-notifications/)." <commentary>Intent without a path — do NOT activate yet. Ask for the path; activate only when the user supplies it.</commentary></example> <example>Context: User wants to resume a partially-completed goal where task1.md is already done. user: "Resume the add-notifications goal at docs/implementation/PENDING/add-notifications/" assistant: "Activating stride-lite-workflow. The first task already has a ## Completion Summary section, so the skill will pick up at task2.md and continue until every remaining task and goal.md is wrapped up, then exit." <commentary>The 'next task' rule is 'first taskN.md without ## Completion Summary' — partial-run resumption works automatically. Exit still happens only after the final-task branch fires.</commentary></example> <example>Context: User asks for a single task. user: "Implement task3.md in the add-notifications goal." assistant: "That's a single-task request — I'll do it manually rather than activating stride-lite-workflow, which is for full-goal drives. Want me to use the workflow on the full goal instead?" <commentary>Single-task requests do NOT match the activation contract (the workflow always iterates the full remaining set and runs the goal close-out). Do the work manually or confirm a full-goal drive.</commentary></example>
skills_version: "1.0"
---

# stride-lite-workflow

The file-based equivalent of `stride:stride-workflow`. Walks a stride-lite goal directory through the eight-step task lifecycle: select next task → before_task hook → explorer → implementation → after_task hook → reviewer → review-loop → completion summary → (on final task) goal completion summary + after_goal hook. No API calls, no kanban server interaction, no auth — the goal/task markdown files plus the project-local `.stride_lite.md` hook file are the entire surface.

## When to invoke

### Activation contract

Activate the skill if and ONLY if **both** conditions are met:

1. **Explicit intent.** The user states they want to work on a goal — e.g., "work this goal", "drive the X goal to completion", "process all tasks in <path>", "resume the X goal", "implement the add-notifications goal". Hedged or ambiguous phrasing ("could you look at...", "what's in this directory?", "show me task3") does **not** satisfy the intent condition.
2. **Path supplied.** The user provides a path to a goal directory — either inline in the same turn, or as a follow-up answer to a clarifying question from the agent. The path must point at a directory that contains `goal.md` plus at least one `task1.md`.

If intent is present but the path is missing, ask for the path; do NOT activate yet. If a path is present but intent is missing (e.g., the user just pastes a path with no instruction), ask what they want done with it; do NOT activate yet. Activate the moment both conditions are jointly satisfied.

### Termination contract

The skill exits **exactly once**, after all of these have happened:

1. Every `taskN.md` in the goal directory has a `## Completion Summary` section appended.
2. `goal.md` has its `## Completion Summary` appended.
3. The `## after_goal` hook has auto-fired (via PostToolUse on the goal.md Edit/Write) and the agent has either observed the structured success JSON or surfaced any failure JSON to the user.

After exit, do **not** re-enter the loop, do **not** start another goal, do **not** ask "should I work on another goal?". If the user wants another goal worked, they invoke the skill again with a different path. If the user wants the same goal re-run, that's an error — the skill detects "every taskN.md already has a Completion Summary" at Step 1 and stops cleanly with a "goal already complete" log line.

### What does NOT activate this skill

- Single-task requests (e.g., "implement task3.md") — do the work manually; the workflow always iterates the full remaining set.
- Goal-directory inspection requests (e.g., "what's in this goal?", "show me task1") — read the files directly; do not activate.
- Scaffolding requests (e.g., "create a goal for X") — those use `the stride-lite-create-goal skill` and `the stride-lite-create-task skill`.
- File-tree exploration with no stated intent — ask what the user wants before activating.

## Inputs

| Input | Type | Required | Default | Notes |
|---|---|---|---|---|
| `goal_directory_path` | string | yes | — | Path to a stride-lite goal directory (e.g., `docs/implementation/PENDING/<slug>/`). The directory must contain `goal.md` plus `task1.md`, `task2.md`, ... in sequential numeric order. |
| `max_review_iterations` | integer | no | `3` | Cap on the Step 7 review-loop. After this many consecutive `changes_requested` reviews, the skill surfaces the failing review and stops without writing the Completion Summary. |

## What this skill does NOT do

- **Never POSTs to any API.** stride-lite remains a "no network" plugin; the workflow surface adds hook execution and subagent dispatch but no network calls.
- **Never creates new task files.** Use `the stride-lite-create-goal skill` or `the stride-lite-create-task skill` to scaffold; the workflow consumes existing files only.
- **Never modifies the goal.md or taskN.md files** beyond the documented append-only mutations: appending `## Completion Summary` to the task file in Step 8, and appending `## Completion Summary` to goal.md on the final task. Everything above those appended sections stays byte-equivalent across runs.
- **Never executes non-hook Bash commands** outside the documented scope (see `## Bash scope` below).
- **Never amends the v0.6.0 task-explorer.md or v0.7.0 task-reviewer.md contracts.** The workflow activates them as subagents via the Copilot harness — it does not retrofit their contracts.

## The Eight-Step Loop

For each incomplete task in the goal directory (in numeric `taskN.md` order), walk these eight steps. On the final task, the workflow exits cleanly after Step 8 instead of looping.

### Step 1 — Select the next task

Read the goal directory. Iterate `task1.md`, `task2.md`, `task3.md`, ... in strict numeric order. For each task file, check whether it contains a `## Completion Summary` section at the bottom of the file:

- If yes → this task is complete; skip to the next numeric task.
- If no → this is the **next task**. Proceed to Step 2 with this file as the active task.

If every `taskN.md` in the goal directory already has a `## Completion Summary` section, the goal is already complete — log this and stop (without running `after_goal` again).

**Gap handling.** If the iteration finds `task1.md` and `task3.md` but no `task2.md`, treat this as a hard error: the goal directory is malformed. Surface the gap to the user and stop without mutation. (The contract is "consecutive numeric files starting at 1"; do NOT silently skip gaps.)

### Step 2 — Execute the `## before_task` hook

The `hooks/hooks.json` registered with the Copilot harness auto-fires the `## before_task` section from `.stride_lite.md` as a **PreToolUse** hook on the Step 3 subagent dispatch of `stride-lite-copilot:task-explorer`. The harness runs the hook before the agent dispatch completes; a non-zero exit returns `exit 2` and blocks the dispatch, which surfaces to you as a Step 3 failure.

You do **NOT** read `.stride_lite.md` or execute its hook sections directly in this step — the harness does that. Missing `.stride_lite.md`, a missing `## before_task` section, or an empty fenced block all degrade to a clean no-op (exit 0) so the dispatch proceeds. A failing command emits a structured failure JSON on stdout for your Step 8 Completion Summary to reference.

If Step 3's dispatch is blocked by a `before_task` failure, surface the failing command and its stderr to the user and stop the workflow.

### Step 3 — Dispatch `stride-lite-copilot:task-explorer`

Dispatch `stride-lite-copilot:task-explorer` as a subagent with the active task file's path as the prompt input. The explorer parses the task file's metadata (`## Key files`, `## Patterns to follow`, `## Where`, `## Testing strategy`), runs read-only codebase exploration, and appends/replaces a `## Exploration Report` section at the bottom of the task file (per the v0.6.0 contract).

If the explorer dispatch fails (e.g., the agent surfaces a clear error and exits without mutation), stop the workflow and surface the error. The explorer is a hard prerequisite for high-quality implementation in Step 4.

### Step 4 — Implementation

Now write code. Use the active task file as your spec — `## Description`, `## Why`, `## What`, `## Where`, `## Acceptance criteria`, `## Patterns to follow`, `## Pitfalls`, `## Security considerations`, `## Integration points`, `## Technology requirements`, `## Logging requirements`, `## Key files`, `## Verification steps`, `## Testing strategy` — plus the `## Exploration Report` the explorer just appended.

Follow the acceptance criteria as your definition of done. Replicate the patterns. Avoid the pitfalls. Modify the files listed in `## Key files`. Write the tests specified in `## Testing strategy`.

**This is the only step where the orchestrator agent writes code.** Steps 1, 2, 5, 7, 8 are file-mutation-or-hook-execution; Steps 3 and 6 are agent dispatches.

### Step 5 — Execute the `## after_task` hook

Same auto-fire pattern as Step 2, but the harness runs the `## after_task` section as a **PreToolUse** hook on the Step 6 subagent dispatch of `stride-lite-copilot:task-reviewer`. Same blocking semantics — a non-zero exit blocks the reviewer dispatch, which surfaces to you as a Step 6 failure.

You do **NOT** execute `.stride_lite.md` hook sections directly in this step. The harness handles it; a failing command emits structured failure JSON for your Step 8 Completion Summary.

### Step 6 — Dispatch `stride-lite-copilot:task-reviewer`

Dispatch `stride-lite-copilot:task-reviewer` as a subagent with the active task file's path as the prompt input. The reviewer captures `git diff HEAD` (working tree vs HEAD), evaluates the diff against the task file's acceptance criteria / pitfalls / patterns / testing strategy, and appends/replaces a `## Review Report` section at the bottom of the task file (per the v0.7.0 contract).

The reviewer emits a prose summary line AND a fenced ```json block. Step 7 parses the JSON to decide the next step.

### Step 7 — Review-loop decision

Read the active task file's `## Review Report` section. Extract the first fenced ```json block from that section and parse it. Read the `status` field:

- If `status == "approved"` → proceed to Step 8.
- If `status == "changes_requested"` → increment the `review_iteration` counter (initialized to 0 at Step 2) and:
  - If `review_iteration < max_review_iterations` (default 3) → loop back to **Step 4** (Implementation). Make further code changes addressing the reviewer's issues. Then re-run Steps 5, 6, 7 in sequence.
  - If `review_iteration >= max_review_iterations` → stop the workflow. Surface the failing review's prose summary line + the list of unresolved issues to the user. Do NOT write a Completion Summary; the task remains incomplete.

**JSON parse fallback.** If the `## Review Report` section has no fenced ```json block (e.g., the agent fell back to prose-only), parse the prose summary line instead: substring-match `"Approved"` → treat as `approved`; substring-match `"N issues found"` → treat as `changes_requested`. If neither pattern matches, treat as `changes_requested` (conservative default — better to retry than to falsely approve).

### Step 8 — Completion summary + final-task detection + after_goal hook

Append a `## Completion Summary` section to the active task file at EOF. The section contains:

- A one-paragraph synthesis: what was implemented, which acceptance criteria were met, key decisions made.
- A bullet list summarizing the hook results from Steps 2 and 5 (exit_code, brief output).
- A reference to the embedded review JSON's `status` ("approved" — by contract, since we only reach Step 8 if Step 7 returned approved).

**Final-task detection.** After appending the Completion Summary to `taskK.md`, check the goal directory for `task(K+1).md`:

- If `task(K+1).md` **exists** → return to Step 1 to process the next task in the loop.
- If `task(K+1).md` **does NOT exist** → this was the final task in the goal. Continue with the goal-level wrap-up:
  1. Append a `## Completion Summary` section to `goal.md` (the goal-level summary). Content: one-paragraph synthesis of the work across all child tasks, bullet list of completed tasks with one-line each, total elapsed time if trackable.
  2. The append to `goal.md` is performed via `Edit` or `Write`; the harness auto-fires the `## after_goal` section from `.stride_lite.md` as a **PostToolUse** hook when (a) the file path ends in `goal.md` and (b) the written content contains the literal string `## Completion Summary`. PostToolUse cannot roll back the write, so `after_goal` is **advisory** — a failure emits structured failure JSON on stdout for the user to inspect but does not stop or roll back. You do NOT execute `.stride_lite.md` hook sections directly in this step.
  3. **Move the goal directory from `PENDING/` to `IMPLEMENTED/`.** After the `after_goal` hook has fired, archive the completed goal by moving the goal directory from `docs/implementation/PENDING/<slug>/` to `docs/implementation/IMPLEMENTED/<slug>/`. Four behavioral details:

     - **Timing.** This move happens AFTER `after_goal` fires — the user's hook sees the still-PENDING path, matching what the hook was scoped to handle. Never move before the hook.
     - **After-goal-failure guard.** If the harness emitted a structured failure JSON for the `after_goal` hook (`"status": "failed"`), do NOT move the directory. Leave it in `PENDING/` so the user can inspect the failure and re-trigger. A clean no-op (no `after_goal` section, missing `.stride_lite.md`, empty fenced block) is NOT a failure — proceed with the move.
     - **Non-`/PENDING/` path.** If `goal_directory_path` (after stripping the trailing slash) does not contain `/PENDING/` as a directory segment — for example, the user passed a custom `--output-dir` to `the stride-lite-create-goal skill` and the goal lives at `docs/custom-archive/<slug>/` — log a warning to stderr (`stride-lite-workflow: goal directory not under PENDING — skipping move; you can move it manually to your archive location`) and skip the move. Do NOT fail the workflow.
     - **Move tool selection.** Try `git mv` first when (a) `git rev-parse --is-inside-work-tree` succeeds and (b) `git ls-files "$goal_path"` returns a non-empty list (the goal directory's files are tracked). This preserves rename history. Otherwise fall back to plain `mv`.
     - **Collision suffixing.** If the target `IMPLEMENTED/<slug>/` already exists, suffix the destination with `-2`, `-3`, ... up to a 1000-iteration cap, mirroring `lib/resolve_output_path.md`'s semantics exactly (start at `n=2`, probe with `[ ! -e "$candidate" ]`, never overwrite, cap exhaustion emits a stderr warning and skips the move). Never overwrite an existing IMPLEMENTED entry.
     - **Filesystem-mv failure.** If `mv` / `git mv` returns non-zero (permissions, disk full, cross-device, etc.), log the error to stderr and skip the move — the goal work is complete, a failed archive is a recovery operation. Do NOT fail the workflow.

     **Reference bash idiom** (use as a template; adapt variable names freely):

     ```bash
     goal_path="${goal_directory_path%/}"          # strip trailing slash
     slug="${goal_path##*/}"                       # basename = slug

     case "$goal_path" in
       */PENDING/*)
         pending_parent="${goal_path%/PENDING/*}"  # path up to /PENDING parent
         impl_base="${pending_parent%/}/IMPLEMENTED"
         candidate="${impl_base}/${slug}"
         n=2
         while [ -e "$candidate" ]; do
           candidate="${impl_base}/${slug}-${n}"
           n=$(( n + 1 ))
           if [ "$n" -gt 1000 ]; then
             echo "stride-lite-workflow: refusing to scan past -1000 collisions for IMPLEMENTED destination" >&2
             candidate=""; break
           fi
         done
         if [ -n "$candidate" ]; then
           mkdir -p "$impl_base"
           if git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
              && [ -n "$(git ls-files "$goal_path")" ]; then
             git mv "$goal_path" "$candidate" \
               || { echo "stride-lite-workflow: git mv failed; leaving in PENDING" >&2; }
           else
             mv "$goal_path" "$candidate" \
               || { echo "stride-lite-workflow: mv failed; leaving in PENDING" >&2; }
           fi
         fi
         ;;
       *)
         echo "stride-lite-workflow: goal directory not under PENDING — skipping move; you can move it manually to your archive location" >&2
         ;;
     esac
     ```

  4. Workflow complete. Stop.

## Hook execution contract

As of v0.9.0 the three hooks (`## before_task`, `## after_task`, `## after_goal`) are **auto-fired by the Copilot harness via `hooks/hooks.json`** — the workflow skill body does NOT execute `.stride_lite.md` hook sections directly. The harness invokes `hooks/stride-lite-hook.sh` on macOS/Linux (which delegates to `hooks/stride-lite-hook.ps1` on native Windows) at three intercept points:

| Section | Phase | Matcher | Trigger condition | Blocking? |
|---|---|---|---|---|
| `## before_task` | PreToolUse | subagent dispatch | subagent identity == `"stride-lite-copilot:task-explorer"` (Step 3 dispatch) | yes (exit 2 blocks the dispatch) |
| `## after_task` | PreToolUse | subagent dispatch | subagent identity == `"stride-lite-copilot:task-reviewer"` (Step 6 dispatch) | yes (exit 2 blocks the dispatch) |
| `## after_goal` | PostToolUse | `Edit` or `Write` | file path ends in `goal.md` AND body contains `## Completion Summary` (Step 8 final-task wrap-up) | no (advisory; failure cannot roll back the write) |

For each trigger, the hook executor:

1. Locates `.stride_lite.md` via `$CLAUDE_PROJECT_DIR` (falls back to the current directory).
2. Parses the named `## <section>` heading and the first fenced ` ```bash ... ``` ` block under it.
3. Executes each non-empty, non-comment line one at a time. On the first non-zero exit it stops and emits a structured failure JSON on stdout (`hook`, `status: "failed"`, `failed_command`, `command_index`, `exit_code`, `stdout`, `stderr`, `commands_completed`, `commands_remaining`); on all-success it emits a structured success JSON (`hook`, `status: "success"`, `commands_completed`, `duration_seconds`).
4. Missing `.stride_lite.md`, missing section, or empty fenced block all degrade to a clean no-op (exit 0, no JSON).

The hook environment is the same shell environment the Copilot harness runs in — no special env-var injection beyond what the user's command lines reference. (This differs from the full Stride plugin which injects `TASK_*` / `GOAL_*` env vars; stride-lite-copilot hooks rely on the user writing self-contained commands.)

## Bash scope

The workflow skill's Bash usage is scoped to a specific set of operations. Explicit ✅ examples:

- ✅ `.stride_lite.md` hook execution is performed by the harness via `hooks/stride-lite-hook.sh` (or `.ps1` on native Windows) — this skill body does NOT run `## before_task` / `## after_task` / `## after_goal` directly.
- ✅ `git diff HEAD` — captured by the task-reviewer agent in Step 6 (not directly by this skill; the agent has its own Bash grant).
- ✅ `ls`, `test -f`, `find` — for filesystem navigation inside the goal directory (listing taskN.md files, checking for task(K+1).md existence).
- ✅ `git rev-parse --show-toplevel` — for locating the project root (e.g., to inspect `.stride_lite.md` for the user, not to execute it).
- ✅ `mv` and `git mv` — for the terminal-move step in Step 8's final-task branch only (PENDING → IMPLEMENTED archive move). Forbidden elsewhere in the skill body.
- ✅ `git rev-parse --is-inside-work-tree` — for the terminal-move step in Step 8's final-task branch only (detecting whether to prefer `git mv` over plain `mv`). Forbidden elsewhere in the skill body.
- ✅ `git ls-files <path>` — for the terminal-move step in Step 8's final-task branch only (detecting whether the goal directory's files are git-tracked before invoking `git mv`). Forbidden elsewhere in the skill body.
- ✅ `mkdir -p <impl_base>` — for the terminal-move step only (ensuring the IMPLEMENTED parent directory exists before `mv` / `git mv` lands the goal into it). Forbidden elsewhere in the skill body.

Explicit ❌ anti-examples — the workflow skill MUST NEVER directly invoke:

- ❌ `mix test`, `mix compile`, `npm test`, `npm run`, `cargo test`, `cargo build` — these belong in the user's `## after_task` hook, not in the skill body.
- ❌ `curl`, `wget`, `nc` — no network calls (matches the v0.7.0 task-reviewer's discipline).
- ❌ `git commit`, `git push`, `git checkout`, `git reset`, `git merge`, `git rebase` — no mutating git operations.
- ❌ `rm`, `cp` and `mv` outside the documented narrow uses (user-supplied hook bash blocks; the terminal-move step in Step 8's final-task branch carving out `mv` / `git mv` / `mkdir -p` as listed in the ✅ block above) — no filesystem mutation outside the documented append-only task/goal file mutations plus the terminal archive move.

If the user wants build/test/lint runs as part of the workflow, they put them in `## after_task` in `.stride_lite.md`. The harness's PreToolUse hook on the Step 6 reviewer dispatch executes them verbatim — that's how the scope expands by configuration, not by skill-body code.

## Edge cases

- **No `.stride_lite.md` in project root** — log a warning, treat all three hooks as no-ops, proceed with the workflow. The user may not have initialized stride-lite; that's a valid (if reduced-functionality) configuration.
- **`.stride_lite.md` exists but a hook section is missing** — treat that specific hook as a no-op (exit_code 0, empty output). Don't fail; the user may have deliberately omitted unneeded hooks.
- **`.stride_lite.md` hook section exists but the fenced bash block is empty** — same as missing: no-op, proceed.
- **Goal directory missing `goal.md`** — hard error: surface a clear message ("goal_directory_path is not a valid stride-lite goal — no goal.md found") and stop.
- **Goal directory has no taskN.md files** — hard error: surface a clear message and stop. The workflow needs at least task1.md to do anything.
- **Goal directory has task1.md and task3.md but no task2.md** — hard error per Step 1's gap-handling rule. Surface the gap and stop.
- **Every taskN.md already has `## Completion Summary`** — log "goal already complete" and stop. Do NOT re-run after_goal (the goal has already been wrapped up in a prior session).
- **task-explorer agent dispatch fails or returns an error** — surface the explorer's error and stop. The explorer's findings are a prerequisite for high-quality implementation.
- **task-reviewer agent dispatch fails or returns an error** — surface the reviewer's error and stop. Without a review verdict, the workflow can't decide Step 7.
- **task-reviewer's `## Review Report` has no fenced JSON block** — fall back to prose-substring matching per Step 7's JSON parse fallback. Conservative default on ambiguity: treat as `changes_requested`.
- **Review-loop exhausts max_review_iterations** — stop without writing the Completion Summary. The task file retains its latest `## Review Report` section as the audit trail. The user can manually fix the issues and re-run the workflow; on re-run the task is "incomplete" (no Completion Summary) so Step 1 picks it up again.
- **after_goal hook fails after goal.md Completion Summary is written** — surface the failure but do NOT roll back the goal.md mutation. The user can re-run the after_goal hook manually (e.g., by inspecting `.stride_lite.md` and running the commands directly).

## Concrete walkthrough

A two-task goal at `docs/implementation/PENDING/add-notifications/` containing `goal.md`, `task1.md`, `task2.md`, and a `.stride_lite.md` in the project root with all three hook sections populated. The workflow proceeds:

**Iteration 1 — task1.md (Emit PubSub broadcast on comment insert).**

- **Step 1.** Scan goal dir. task1.md has no `## Completion Summary` → next task is task1.md.
- **Step 2.** Read `.stride_lite.md` `## before_task` section. Execute the bash (e.g., `git pull origin main`). Capture exit_code=0, output, duration_ms=2400. Proceed.
- **Step 3.** Dispatch `stride-lite-copilot:task-explorer` with `task1.md` as the prompt. After ~30s the agent appends a `## Exploration Report` section to task1.md covering File state per key_file, Pattern matches (Kanban.Boards.create_board broadcast at boards.ex:42), Related tests (test/kanban/comments_test.exs), Implementation notes (use Kanban.PubSub, follow with-chain placement).
- **Step 4.** Implement the broadcast. Modify `lib/kanban/comments.ex` (add Phoenix.PubSub.broadcast inside the success arm) and `test/kanban/comments_test.exs` (subscriber test).
- **Step 5.** Read `.stride_lite.md` `## after_task` section. Execute the bash (e.g., `mix test` and `mix credo --strict`). Capture exit_code=0, duration_ms=18000. Proceed.
- **Step 6.** Dispatch `stride-lite-copilot:task-reviewer` with `task1.md` as the prompt. After ~25s the agent appends a `## Review Report` section. The embedded JSON's `status` is `approved`.
- **Step 7.** Parse the JSON. `status == approved` → proceed to Step 8.
- **Step 8.** Append a `## Completion Summary` section to task1.md (one-paragraph synthesis + hook results + review status). Check for task2.md: exists. Return to Step 1.

**Iteration 2 — task2.md (Subscribe to comment broadcasts in BoardLive.Show).**

- **Step 1.** Scan again. task1.md now has `## Completion Summary` → skip. task2.md has no `## Completion Summary` → next task is task2.md.
- **Step 2–7.** Same pattern. The reviewer first returns `changes_requested` (the BoardLive subscribe wasn't filtering by board_id). The workflow loops back to Step 4 (iteration 1 of the review-loop), the implementation is fixed, Step 5/6/7 re-run, the reviewer now returns `approved` (iteration 2 — under the cap). Proceed to Step 8.
- **Step 8.** Append `## Completion Summary` to task2.md. Check for task3.md: does NOT exist. This was the final task.
- **Step 8 (continued).** Append `## Completion Summary` to `goal.md` with the goal-level synthesis: "Real-time notifications shipped via 2-task split — broadcast emission in the context module (task1), LiveView subscription in BoardLive.Show (task2). Both tasks reviewed and approved. All hooks completed cleanly."
- **Step 8 (final).** Execute `.stride_lite.md` `## after_goal` section. If it succeeds, workflow complete. If it fails, surface the failure — goal.md's Completion Summary remains; user re-runs the hook manually.

**End state.** Both taskN.md files have full lifecycle sections (Description → ... → Exploration Report → Review Report → Completion Summary). goal.md has a `## Completion Summary` at EOF. The user can navigate the goal directory and see exactly what happened, in order, in each file.

## Red flags — STOP

If you catch yourself thinking any of these, go back to the documented step:

- **"This task is small — I'll skip the explorer dispatch in Step 3."** No. The explorer is part of the documented loop; every task gets it. The explorer's findings inform Step 4's implementation, and skipping it produces lower-quality code reviews in Step 6.
- **"The reviewer's `changes_requested` looks minor — I'll write the Completion Summary anyway."** No. The Step 7 contract is binary: `approved` proceeds, anything else loops back. Bypassing the loop defeats the safeguard.
- **"The after_task hook failed but it's just a flaky test — let me skip and complete the task."** No. Blocking failures must stop the workflow. Fix the root cause (in the user's `.stride_lite.md`) and re-run.
- **"`.stride_lite.md` doesn't exist, I'll skip the hooks but write Completion Summaries anyway."** Yes, this is actually correct — no `.stride_lite.md` is a valid reduced-functionality configuration. But surface a warning so the user knows the hooks were skipped.
- **"The review-loop has hit 3 iterations but the reviewer keeps finding the same issue — I'll force-approve."** No. Stop, surface the unresolved issue, and let the user intervene. Forcing approval defeats the entire review-loop purpose.

## Pitfalls

- **Don't write code in Steps 1, 2, 3, 5, 6, 7, or 8.** Only Step 4 is implementation; the others are orchestration. Mixing concerns produces ambiguous task files.
- **Don't dispatch task-explorer or task-reviewer with parameters other than the task file path.** Both have file-based contracts; they read the file, mutate the file, return nothing structured to you. Treat them as black boxes invoked by path.
- **Don't read or modify `goal.md` in Step 1 — only the taskN.md files determine the next task.** The goal.md is for the human reader; the workflow ignores it until Step 8's final-task wrap-up.
- **Don't execute the after_goal hook except on the final task.** Step 8's final-task detection (task(K+1).md doesn't exist) is the only trigger.
- **Don't mutate goal.md or taskN.md beyond the documented append-only summaries.** Everything above the appended `## Completion Summary` section stays byte-equivalent across workflow runs.
- **Don't fail silently on hook errors.** Blocking failures must surface a clear error and stop the workflow.
- **Don't expand the Bash scope beyond the explicit ✅ list.** If you need a non-allowed command, surface the limitation and stop; let the user add it to `.stride_lite.md` if they want it part of the workflow.
- **Don't loop forever in Step 7.** The `max_review_iterations` cap (default 3) is mandatory. After the cap, stop with the failing review surfaced.
- **Don't conflate "task-explorer error" with "implementation error".** Step 3 has its own failure mode (the agent surfaces an error); Step 4's implementation is on you. Surface explorer errors and stop; don't proceed to a Step 4 without exploration findings.
- **Don't introduce a new slash command in this skill.** Invocation is via natural-language activation matching against this skill's description — the same pattern as stride-lite-copilot's other skills. If a command surface is wanted, it's a follow-up release.
- **Don't read user-supplied hook commands as anything other than verbatim bash.** Do not pre-validate them, do not "sanitize" them. The user owns `.stride_lite.md` content; if they put a destructive command there, the workflow will execute it. That's a user responsibility, not a skill safety net.
