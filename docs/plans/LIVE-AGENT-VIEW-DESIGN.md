# Live Agent View — Implementation Design

**Roadmap item:** *Live agent view* — "See what each agent is doing right now: its task, its current workflow step and its hook output." ([ROADMAP](../../ROADMAP.md), under *Agent controls and approvals*).

**Status:** proposal. Nothing in this document is built yet. Every statement about today's code was checked against the source on 2026-10-28; references are given as `path:line` so they can be re-checked.

The live agent view turns the `/agents` page from a record of what agents **have done** into a window on what they **are doing**: which task each agent holds, which step of the Stride workflow it is in, how long it has been there, and the output of the hook it is running, as that output is produced.

It cannot be built on today's data alone. The server does not record which agent claimed a task, never hears about workflow steps until a task is completed, and throws away almost all hook output ([§3](#3-what-the-server-knows-today)). The first half of this design is therefore a **small, mechanical reporting channel** from the Stride plugins to the server; the second half is the screen.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Terms used in this document](#2-terms-used-in-this-document)
3. [What the server knows today](#3-what-the-server-knows-today)
4. [The view at a glance](#4-the-view-at-a-glance)
5. [Where it lives](#5-where-it-lives)
6. [Live roster cards](#6-live-roster-cards)
7. [The live agent panel](#7-the-live-agent-panel)
8. [The wall view](#8-the-wall-view)
9. [What a user can do](#9-what-a-user-can-do)
10. [Signals and liveness](#10-signals-and-liveness)
11. [The reporting channel](#11-the-reporting-channel)
12. [Plugin changes](#12-plugin-changes)
13. [Server architecture](#13-server-architecture)
14. [Database changes](#14-database-changes)
15. [Live delivery to the browser](#15-live-delivery-to-the-browser)
16. [Security and privacy](#16-security-and-privacy)
17. [Permissions and plans](#17-permissions-and-plans)
18. [Relationship to the Stop switch](#18-relationship-to-the-stop-switch)
19. [Agents on older plugins](#19-agents-on-older-plugins)
20. [Telemetry](#20-telemetry)
21. [Translations, dark mode and docs](#21-translations-dark-mode-and-docs)
22. [Testing strategy](#22-testing-strategy)
23. [Phased delivery](#23-phased-delivery)
24. [Decisions needed](#24-decisions-needed)

---

## 1. Goals and non-goals

### Goals

- Show, for every agent that holds a task: the task, its goal and target, the current workflow step, time in that step, and whether the agent is still sending signals.
- Show each hook's output **while it runs**, command by command, with exit codes and durations, and keep it for a limited time afterwards.
- Replace the current "stuck" rule (no timestamp for 60 minutes) with a rule based on real signals, so long-running healthy work is no longer flagged.
- Record which agent claimed each task, so the roster and feed stop guessing.
- Give board owners the existing levers (release a task, reassign or reprioritize a goal) from where they watch, and host the Stop switch's controls when that item ships.
- Collect all of this **without relying on the agent remembering to report**: the plugins report from code they already run.

### Non-goals

- **A remote terminal.** The view never sends keystrokes or commands to an agent's machine.
- **Agent transcripts.** The view shows workflow steps and hook output, not the agent's reasoning, prompts or tool calls. The existing detail panel's "no transcript or token-level detail" rule (`lib/kanban_web/components/agent_detail_panel.ex:6-9`) stays.
- **Chat with agents.** Comments remain task comments that agents read when their workflow tells them to.
- **The Stop switch itself.** Pausing and stopping agents is its own roadmap item; this design provides the channel it can use and the place its buttons live ([§18](#18-relationship-to-the-stop-switch)).
- **Cost and token accounting.**

---

## 2. Terms used in this document

| Term | Meaning |
|---|---|
| Agent | As today: a `{name, owner_key}` pair, where the name is the agent name the token sends and `owner_key` is the owning user's id or `"none"` (`lib/kanban/agents/agent.ex:9-13`). |
| Step | One stage of the Stride workflow: `claim`, `before_doing`, `explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `complete`, `before_review`, `review_gate`, `after_review`. The middle six match the canonical `workflow_steps` names (`lib/kanban/tasks/workflow_steps.ex:86`). |
| Activity event | A short record that a step started, finished, failed or was skipped. |
| Hook run | One execution of one hook (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`) for one task, with its commands, output, exit code and duration. A retried hook is a new run. |
| Signal | Any activity event, hook-run update, claim, complete or other agent API call for the task. |
| Live-capable agent | An agent whose plugin sends activity events. Others are "legacy" ([§19](#19-agents-on-older-plugins)). |

---

## 3. What the server knows today

### 3.1 The `/agents` page

`/agents` (`lib/kanban_web/live/agents_live.ex`, route at `lib/kanban_web/router.ex:384`) shows, top to bottom (`agents_live.ex:332-409`):

- A header with today's counts, cycle time and a fleet-health row (Working, Waiting, Idle, plus Stuck as an "of which" count), with board and time-range selectors.
- The delivery-health band and the target risk explainer, with Reassign and Reprioritize interventions.
- A "live · N connected" indicator, which counts **page viewers**, not agents (`lib/kanban_web/channels/agents_presence.ex:26-35`).
- The roster of agent cards (`lib/kanban_web/components/agent_roster_card.ex:51-123`): name, owner, status dot, current-task pill when working, stats.
- An inline detail panel (`agent_detail_panel.ex`): current work, claims, rejected reviews, recent activity.
- The activity feed, capped at 200 events (`agents_live/data_loader.ex:32`).

Nothing about agents is stored: the context derives everything from task rows (`lib/kanban/agents.ex:1-9`, `agents/event.ex:5-7`). The page subscribes to `"agents:#{board_id}"` and, on any message, re-runs every query after a 250 ms debounce (`agents_live.ex:94-98, 304-306, 438-443`).

### 3.2 Gaps

| Gap | Evidence | Consequence |
|---|---|---|
| **The claiming agent is not recorded.** A claim sets status, `claimed_at`, `claim_expires_at`, `assigned_to_id`, column and position only. | `lib/kanban/tasks/agent_workflow.ex:425-472`; the name goes only to `api_token.last_agent_name` (`controllers/api/task_actions.ex:435-437`) | The roster credits work in progress to `completed_by_agent \|\| created_by_agent` (`agents/events.ex:76`), which is wrong for a task a human or another agent created. |
| **No step reporting.** `workflow_steps` arrives only in the completion payload. Agents cannot write it through `PATCH /api/tasks/:id`. | `agent_workflow.ex:650-661`, `controllers/api/task_param_filter.ex:90-153` | The server cannot say what an agent is doing between claim and complete. |
| **Hook output is dropped.** `before_doing_result`, `after_doing_result`, `before_review_result` and `after_review_result` are validated (keys present, exit code 0) and discarded. | `lib/kanban/hooks/validator.ex:40-74`; not in the cast list at `agent_workflow.ex:650-661` | The only copy of the output is `.stride/.hook-result-<hook>.json` on the agent's machine. |
| **`after_goal` output is stored but never shown.** | `task.ex:376-387`, `tasks/goals.ex:250-290`; no LiveView renders it | Owners cannot see why a goal's final hook failed without the API. |
| **No liveness signal.** No heartbeat, progress or claim-renew endpoint. | Claim expiry fixed at 60 minutes (`agent_workflow.ex:429`) | "Stuck" means "Doing or Review task whose newest timestamp is over 60 minutes old" (`agents/roster.ex:38, 192-208`), so any task longer than an hour is flagged regardless of health. |
| **No streaming transport for agents.** MCP is POST-only; the event-stream route exists only to answer 405. | `lib/kanban_web/mcp/server.ex`, `controllers/mcp_controller.ex:42-50` | Reporting must be plain HTTP posts. |
| **No pause or stop mechanism.** | `lib/kanban/boards/board.ex:8-13` | See [§18](#18-relationship-to-the-stop-switch). |

### 3.3 What the plugins already have

The Claude Code plugin's hook script (`stride/hooks/stride-hook.sh`) runs every `.stride.md` hook itself, as `PreToolUse` and `PostToolUse` handlers on the agent's Bash calls. It already:

- Knows which hook it is running, each command, its output, exit code and duration, and writes them to `.stride/.hook-result-<hook>.json`.
- Calls the server on its own (`PUT /api/tasks/:id/changed_files`, `GET /api/tasks/:id/after_goal_status`), with the agent's token and a curl User-Agent.
- Sees every claim and complete call the agent makes.

That makes hook reporting a change to code that already holds the data, rather than a new instruction the agent must follow.

---

## 4. The view at a glance

```
 Agents                                     Board: Stride ▾   Today ▾    [ Roster | Wall ]
 Working 4 · Waiting 1 · Idle 3 · Silent 1 · Failed hook 1                 live · 2 viewers

 ┌───────────────────────────────┐ ┌───────────────────────────────┐ ┌───────────────────
 │ ● claude-opus-5-5   Jeff       │ │ ◐ codex-gpt   Priya            │ │ ✕ gemini-pro   Sam
 │ W2516 Add attachment metadata │ │ W2522 Download attachments…    │ │ W2509 Oban cleanup…
 │ Implementing · 14m            │ │ after_doing · 1m 12s           │ │ after_doing failed
 │ ■■■■■□□□                      │ │ ■■■■■■■□                       │ │ ■■■■■■✕□
 │ › mix test test/kanban/…      │ │ › 214 tests, 0 failures        │ │ › ** (CompileError)…
 └───────────────────────────────┘ └───────────────────────────────┘ └───────────────────
```

Selecting a card opens the live agent panel ([§7](#7-the-live-agent-panel)).

---

## 5. Where it lives

The live view **extends `/agents`**; it does not replace it.

| Route | What | Router placement |
|---|---|---|
| `/agents` | Today's page with live roster cards ([§6](#6-live-roster-cards)) and a Roster / Wall toggle. | Existing route in `live_session :require_authenticated_user` (`router.ex:384`). |
| `/agents?view=wall` | The wall view ([§8](#8-the-wall-view)). | Same route; `handle_params/3` switches the layout. |
| `/agents/live/:agent_key` | The live agent panel as a shareable full page. `agent_key` encodes `{name, owner_key}` (URL-safe, not a database id). | New route in the same `live_session :require_authenticated_user` block, because it shows board data and must require a signed-in user and the Organization two-factor rule exactly like `/agents`. |
| `/agents/live/:agent_key/tasks/:task_id` | Replay of one past task's steps and hook output. | Same block. |

The existing inline detail panel gains an **Open live view** link to `/agents/live/:agent_key`.

---

## 6. Live roster cards

Each card for an agent holding a task gains four things:

| Element | Content | Source |
|---|---|---|
| Step chip | Current step and time in it: "Implementing · 14m", "after_doing · 1m 12s", "Waiting for review · 2h" | Latest activity event ([§11.2](#112-activity-events)) |
| Step strip | Eight small segments (claim, before_doing, explore, plan, implement, review, after_doing, complete) filled as done, current, skipped or failed | Activity events for the task |
| Last output line | The newest line of the running hook, truncated to one line, in monospace | Hook run tail ([§11.3](#113-hook-runs)) |
| Signal light | Active, Quiet, Silent or Failed ([§10](#10-signals-and-liveness)) | Latest signal time |

The card's existing current-task pill now uses `claimed_by_agent` ([§14.1](#141-claimed_by_agent-on-tasks)), so it is correct for every task.

Ordering: Failed first, then Silent, then Active and Quiet by time in current step (longest first), then Waiting, then Idle, then the dormant group as today.

The header's fleet-health row adds **Silent** and **Failed hook** counts, and "Stuck" is retired for live-capable agents ([§10.2](#102-replacing-stuck)).

---

## 7. The live agent panel

```
 claude-opus-5-5 · owner: Jeff · plugin stride 1.87.0       ● Active · last signal 8s ago
 ┌ W2516  Add attachment metadata to task JSON       Goal G490 · Target Q4 Launch (at risk)
 │ claimed 10:42 (38m ago) · claim expires in 22m · medium · 6 key files
 └ [Open task] [Open goal] [Release task] [Comment]                     [Follow ☆]

 Claim ✓ ─ before_doing ✓ ─ Explore ✓ ─ Plan ✓ ─ Implement ● ─ Review ○ ─ after_doing ○ ─ Complete ○
   0:04        0:41          3:12       2:05       14:20…

 Hook output  [before_doing ✓ 41s]  [after_doing #1 ✕ 2m 3s]  [after_doing #2 ● running]
 ┌───────────────────────────────────────────────────────────────────────────── ⤓  ⧉ ┐
 │ $ mix format --check-formatted                                         ✓ 3.1s     │
 │ $ mix test                                                             ● 1m 02s   │
 │ ..........................................................................        │
 │ Finished in 58.3 seconds (12.1s async, 46.2s sync)                                │
 │ 2140 tests, 0 failures                                                            │
 └───────────────────────────────────────────────────────── following ▾ ─────────────┘

 Activity
 10:42:11 claimed W2516                    10:46:01 planner started
 10:42:15 before_doing started             10:48:06 planner finished (2m 5s)
 10:42:56 before_doing passed (41s)        10:48:07 implementation started
 10:43:01 explorer started                 11:02:27 after_doing #1 failed: mix credo --strict
 10:46:13 explorer finished (3m 12s)       11:04:30 after_doing #2 started

 Earlier today: W2514 (done 09:58, 47m) · W2511 (done 08:40, 1h 12m)
```

### 7.1 Header

Agent name, owner, plugin name and version (from the activity events' `client` field, [§11.2](#112-activity-events)), signal light with "last signal N ago", and a **Follow** toggle ([§9](#9-what-a-user-can-do)).

### 7.2 Current task card

Identifier and title (link), goal and target (with the target's status badge), claim time and age, time until the claim expires, complexity, number of key files, and the action buttons. When the agent holds no task, the card reads "Not working on a task" with the agent's last completed task and when.

### 7.3 Step tracker

| Step | Starts when | Ends when |
|---|---|---|
| Claim | Claim request accepted | Immediately |
| before_doing | Hook run started | Hook run finished |
| Explore | `explorer` started | `explorer` finished or skipped |
| Plan | `planner` started | `planner` finished or skipped |
| Implement | `implementation` started (or Plan / Explore finished) | `reviewer` or `after_doing` started |
| Review | `reviewer` started | `reviewer` finished or skipped |
| after_doing | Hook run started | Hook run finished (retries shown as #2, #3) |
| Complete | Complete accepted | Immediately |
| before_review | Hook run started | Hook run finished |
| Review gate | Task moved to Review (`needs_review` true) | Human review recorded |
| after_review | Hook run started | Hook run finished |

Each step shows done (✓), running (●, pulsing), skipped (–, with the reason the agent gave, e.g. "small task, 0 key files"), failed (✕) or not reached (○), with its duration. Steps the workflow does not use for this task (no review gate when `needs_review` is false) are omitted.

### 7.4 Hook console

- One tab per hook run, newest last, labelled with the hook name, attempt number, status and duration.
- Inside a run, each command is a header line (`$ mix test`) with its own status and duration, followed by its output.
- **Follow mode** keeps the newest line in view; scrolling up pauses it and shows a "Jump to latest" button.
- Standard error lines are marked; on failure, the failing command is highlighted and the console scrolls to it.
- **Copy** copies the visible run; **Download** downloads the stored run as a `.txt` file.
- When a run exceeded the stored size, a banner reads "Showing the last 256 KB of 1.4 MB".
- Output is plain text: terminal colour codes are stripped, nothing is rendered as HTML or Markdown, and links are not made clickable ([§16](#16-security-and-privacy)).
- Likely secrets are replaced with `[redacted: looks like a token]` before storage, so they are never shown.

### 7.5 Activity log and earlier tasks

A timestamped list of every activity event and hook-run start or finish for the current task, newest at the bottom. Below it, the agent's other tasks today, each linking to a replay page that shows the same step tracker, console and log in read-only form, for as long as retention keeps them ([§16.4](#164-retention)).

---

## 8. The wall view

`/agents?view=wall` is a grid for leaving open on a second screen:

- One tile per agent that holds a task on the selected boards: agent, task identifier and title, step chip, step strip, last output line, signal light.
- Sort order: Failed, Silent, then Active and Quiet by time in step.
- No header cards, no feed, no detail panel; selecting a tile opens the live agent panel in the same tab.
- Tiles reflow to one column on phones.

---

## 9. What a user can do

| Action | Who | How it works |
|---|---|---|
| Watch steps and signal state | Any board member | Read only |
| Watch hook output, copy, download | Board members with modify access ([§17](#17-permissions-and-plans)) | Read only |
| Open the task, goal or target | Any board member | Links |
| **Release task** | Board owner | The existing unclaim (`agent_workflow.ex:117`). The agent finds out on its next signal: the activity endpoint answers `409 claim_released` ([§11.2](#112-activity-events)), and the plugin tells the agent to stop work on that task. |
| **Comment** | Members who can comment | Existing task comments. Agents read them only when their workflow does, so the button is labelled "Comment on task", not "Message agent". |
| Reassign or reprioritize the goal | As today | The existing `/agents` interventions (`agents_live/interventions.ex`), also offered on the panel. |
| **Follow** an agent | Any member | Creates a notification subscription: notify when the agent fails a hook, goes Silent, or completes a task. Uses the existing notifications system and its delivery preferences. |
| Filter | Any member | Board, time range (existing), plus status: Active, Quiet, Silent, Failed hook, Waiting, Idle. |
| **Pause after this step**, **Stop now** | Board owner | Only when the Stop switch ships ([§18](#18-relationship-to-the-stop-switch)). |

Every action goes through the existing task lifecycle or the Stop switch's instruction channel. Nothing reaches into an agent's machine directly.

---

## 10. Signals and liveness

### 10.1 Signal states

| State | Rule | Shown as |
|---|---|---|
| Active | A signal in the last 2 minutes | ● green |
| Quiet | Last signal 2–10 minutes ago | ◐ amber |
| Silent | Last signal over 10 minutes ago while the agent holds a task | ○ grey, sorted to the top |
| Failed | The latest hook run for the current task failed and no newer run has started | ✕ red |

Thresholds are configuration, not constants in templates.

A long `implementation` step sends no hook output, so the plugins send a **heartbeat** activity event every 60 seconds while a task is claimed ([§12](#12-plugin-changes)). That is what keeps a healthy agent Active during long work.

### 10.2 Replacing "stuck"

For live-capable agents, **Silent replaces Stuck**: an agent with steady signals is never flagged, however long the task takes. For legacy agents, the existing 60-minute rule stays, with a "No live reporting" label on the card.

The target risk explainer (`target_risk_explainer.ex`) and `DeliveryRollup` read the same per-agent flag, so they switch automatically.

---

## 11. The reporting channel

Two new API endpoints. Both use the existing Bearer token pipeline (`router.ex:193`, `[:api_json, :api]`), the existing per-token rate limiting (`Kanban.RateLimit`, with a new surface), and the board access checks every task endpoint already uses.

### 11.1 Common rules

- **Only the claim holder may report.** The task must be in Doing or Review, claimed through a token of the same user, and — once `claimed_by_agent` exists — the reporting agent name must match it. Anything else is `409 not_claim_holder`.
- **Released and expired claims are refused** with `409 claim_released` or `409 claim_expired`, which the plugins use as a stop signal.
- **Write-only for agents.** Agents never read other agents' activity through the API.
- **No `read_only` tokens or boards.**
- Times sent by clients are accepted only within ±5 minutes of server time; outside that, the server's receive time is used and the event is flagged `clock_skew: true`.

### 11.2 Activity events

`POST /api/tasks/:id/activity`

```json
{
  "agent_name": "Claude Opus 5.5",
  "events": [
    {"step": "explorer", "state": "started", "at": "2026-10-28T10:43:01Z"},
    {"step": "explorer", "state": "finished", "at": "2026-10-28T10:46:13Z", "duration_ms": 192000},
    {"step": "planner", "state": "skipped", "reason": "small task with one key file", "reason_code": "small_task"}
  ],
  "client": {"plugin": "stride", "version": "1.87.0"}
}
```

| Field | Rule |
|---|---|
| `events` | 1–20 per request |
| `step` | One of the steps in [§2](#2-terms-used-in-this-document), or `heartbeat` |
| `state` | `started`, `finished`, `failed`, `skipped` (`heartbeat` takes none) |
| `reason`, `reason_code` | Optional; `reason` at most 200 characters, scanned for credential shapes; `reason_code` from the existing `workflow_steps` vocabulary |
| `duration_ms` | Optional, non-negative |
| `client` | Optional; plugin name and version, each at most 40 characters |

Response `202` with `{"accepted": n}`. The body is where Stop switch instructions will be returned ([§18](#18-relationship-to-the-stop-switch)): `{"accepted": 3, "directive": null}`.

Heartbeats update the task's last-signal time and are **not stored as rows** beyond the latest one, so a long task does not produce thousands of rows.

**Claim extension** is a decision ([§24](#24-decisions-needed)). If adopted: any accepted activity event moves `claim_expires_at` to now + 60 minutes, so a task is never handed to a second agent while its holder is clearly working, and the 60-minute expiry becomes "60 minutes of silence".

### 11.3 Hook runs

`POST /api/tasks/:id/hook_runs` starts a run:

```json
{"hook": "after_doing", "attempt": 2, "commands": ["mix format --check-formatted", "mix test"], "started_at": "…"}
```

Response `201` with `{"id": "<run id>", "append_url": "/api/tasks/:id/hook_runs/<run id>"}`.

`PATCH /api/tasks/:id/hook_runs/:run_id` appends output and, at the end, finishes the run:

```json
{
  "chunks": [
    {"command_index": 1, "stream": "stdout", "text": "2140 tests, 0 failures\n"}
  ],
  "commands": [
    {"index": 0, "exit_code": 0, "duration_ms": 3100},
    {"index": 1, "exit_code": null}
  ],
  "finished": false
}
```

The final call sets `"finished": true` with `exit_code`, `duration_ms` and `timed_out`.

| Rule | Value |
|---|---|
| Append frequency | The plugin batches output and sends at most one append every 2 seconds per run |
| Chunk size | At most 64 KB per request |
| Stored size | The **last 256 KB** of output per run; earlier output is dropped and the run records the total size and `truncated: true` |
| Text | Must be valid UTF-8 (invalid bytes replaced by the plugin); NUL bytes rejected by the existing `ChangesetText.validate_storable` |
| Redaction | Every chunk passes through credential-shape redaction **before** it is stored or broadcast ([§16.2](#162-redaction)) |
| Runs per task | At most 50; further starts are `429` |

The existing `*_result` fields on claim, complete and mark_reviewed are also stored as a finished hook run when no live run exists for that hook and attempt, so agents on older plugins still leave their final output ([§19](#19-agents-on-older-plugins)). `after_goal` results already stored on the goal (`task.ex:376-387`) are shown as hook runs of the goal.

### 11.4 Errors

| Status | Code | Meaning |
|---|---|---|
| 401 | `unauthorized` | Bad or revoked token |
| 403 | `forbidden` / `plan_required` | No board access, read-only, or plan not enabled ([§17](#17-permissions-and-plans)) |
| 404 | `not_found` | Task or run not visible to this token |
| 409 | `not_claim_holder`, `claim_released`, `claim_expired`, `run_finished` | See above |
| 413 | `chunk_too_large` | Over 64 KB |
| 422 | `invalid_event` | Field validation, with per-field errors |
| 429 | `rate_limited`, `too_many_runs` | With `Retry-After` |

Every endpoint is documented in `docs/api/`, the API README's endpoint table, the OpenAPI file and `EndpointDocs`, which the docs-coverage tests require.

---

## 12. Plugin changes

The reporting is done by **plugin code**, not by instructions the agent might skip.

| Signal | How the plugin produces it |
|---|---|
| Claim, complete | The hook script already intercepts these calls; it posts `claim` and `complete` activity events after a successful response. |
| Hook runs | The hook script already runs every hook command. It starts a run, streams each command's output in batched appends, and finishes the run with the exit code. On failure it still finishes the run before returning the failure to the agent. |
| Explorer, planner, reviewer | In Claude Code, a `PreToolUse` / `PostToolUse` handler on the `Agent` tool recognises `stride:task-explorer`, the planner and `stride:task-reviewer` dispatches and posts `started` / `finished`. Ports without subagents post these from their workflow skill at the matching step, as the workflow already requires recording them in `workflow_steps`. |
| Implementation | Inferred: starts when Plan or Explore finishes, ends when Review or `after_doing` starts. No report needed. |
| Skipped steps | Posted with the same reason and reason code the agent already records for `workflow_steps`. |
| Heartbeat | While a task is claimed, any hook handler that fires posts a heartbeat if the last one is over 60 seconds old. This piggybacks on the agent's own tool calls, so no background process is needed. |

**Rules for all ports:**

- Reporting is **never fatal**. A failed post is logged to `.stride/` and the workflow continues. Reports never block a hook.
- Reports go out in the background of the hook handler with a short timeout (2 s), so they never add noticeable time.
- A `409 claim_released` or `claim_expired` response is surfaced to the agent as "this task is no longer yours — stop and run the next-task step".
- Output is batched; the plugin never posts per line.
- Reporting can be turned off per project with `STRIDE_LIVE_REPORTING=0` in the environment or a setting in `.stride.md`; the view then treats the agent as legacy for that project.
- The `.sh` and `.ps1` hooks change in lockstep, with hermetic tests, as for every hook change.

Ports: stride, stride-copilot, stride-gemini, stride-codex, stride-opencode and stride-pi. Each needs the same reporting, adapted to how that runtime exposes hooks and subagents. A shared contract document in the stride repo (`stride/docs/porting-live-reporting.md`) defines payloads, batching, timeouts and the 409 handling, like the existing porting docs.

---

## 13. Server architecture

### 13.1 Modules

| Module | Responsibility |
|---|---|
| `Kanban.AgentActivity` | Context. `record_events/3`, `start_hook_run/3`, `append_hook_run/4`, `finish_hook_run/3`, `current_state/2` (per task: current step, last signal, latest run), `list_for_task/2`, `list_hook_runs/2`, `get_hook_run/3`. Takes `%Scope{}` or the API token's scope first. |
| `Kanban.AgentActivity.ActivityEvent` | Schema and changeset for activity events. |
| `Kanban.AgentActivity.HookRun` | Schema and changeset for hook runs; `append/2` keeps the last 256 KB. |
| `Kanban.AgentActivity.Redactor` | Credential-shape redaction for chunks and reasons, built on `Kanban.Tasks.CredentialShapes`. |
| `Kanban.AgentActivity.Liveness` | Pure: signal state from last-signal time and latest run; thresholds from config. |
| `Kanban.AgentActivity.Steps` | Pure: builds the step tracker from events and runs, including inferred Implementation and omitted steps. |
| `Kanban.AgentActivity.Retention` | Oban cron worker deleting expired events and runs. |
| `KanbanWeb.API.AgentActivityController` | The activity and hook-run endpoints, using the existing JSON error helpers. |
| `KanbanWeb.AgentsLive` | Gains live cards, the wall layout and stream handling. |
| `KanbanWeb.AgentsLive.Live` | New LiveView for `/agents/live/:agent_key` and the replay route. |
| Components | `LiveRosterCard` additions, `StepTracker`, `HookConsole`, `ActivityLog`, `SignalLight`, `WallTile`. |

`Kanban.Agents.Roster` reads `claimed_by_agent` and `Liveness` for status; no queries move into LiveViews.

### 13.2 Where data comes from

```
plugin ──POST activity / hook_runs──▶ AgentActivityController
                                         │ scope + claim-holder check, rate limit
                                         ▼
                                   Kanban.AgentActivity ──▶ Redactor ──▶ Repo
                                         │
                                         └── PubSub "agents:<board_id>"  {:agent_activity, payload}
                                                       │
                                     AgentsLive / AgentsLive.Live (stream inserts)
```

---

## 14. Database changes

### 14.1 `claimed_by_agent` on tasks

| Column | Type | Rule |
|---|---|---|
| `tasks.claimed_by_agent` | `string`, null | Set on claim from the same attribution the completion uses (`ai_agent:<model>` for agent tokens, otherwise `agent_name`); cleared on unclaim and claim release; kept on completion |
| `tasks.last_signal_at` | `utc_datetime_usec`, null | Updated by every accepted signal; drives liveness without scanning events |

Index on `(column_id, last_signal_at)` is not needed; liveness is read for the handful of tasks in Doing and Review on the selected boards.

This change is useful on its own and ships first ([§23](#23-phased-delivery)).

### 14.2 `agent_activity_events`

| Column | Type |
|---|---|
| `id` | bigint |
| `task_id` | references tasks, on delete cascade |
| `board_id` | references boards, on delete cascade (for scoping and broadcast) |
| `agent_name` | string |
| `owner_id` | references users, nilify |
| `step` | string (validated vocabulary) |
| `state` | string |
| `reason`, `reason_code` | string, null |
| `duration_ms` | integer, null |
| `client_plugin`, `client_version` | string, null |
| `clock_skew` | boolean |
| `occurred_at`, `inserted_at` | utc_datetime_usec |

Indexes: `(task_id, occurred_at)`, `(board_id, inserted_at)` for retention.

### 14.3 `hook_runs`

| Column | Type |
|---|---|
| `id` | bigint |
| `task_id`, `board_id`, `owner_id`, `agent_name` | as above |
| `hook` | string (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`) |
| `attempt` | integer |
| `status` | string (`running`, `passed`, `failed`, `timed_out`, `abandoned`) |
| `commands` | jsonb: list of `{index, command, exit_code, duration_ms}` |
| `output` | text: the last 256 KB, chunks prefixed with command index and stream |
| `total_bytes` | bigint |
| `truncated` | boolean |
| `exit_code`, `duration_ms` | integer, null |
| `source` | string (`live`, `result_payload`, `after_goal`) |
| `started_at`, `finished_at`, timestamps | utc_datetime_usec |

A run still `running` with no append for 15 minutes is marked `abandoned` by the retention worker.

Indexes: `(task_id, hook, attempt)` unique, `(board_id, inserted_at)`.

Both tables are excluded from workspace export ([§16.4](#164-retention)).

---

## 15. Live delivery to the browser

- New broadcast `{:agent_activity, payload}` on the existing `"agents:#{board_id}"` topic. The payload carries ids, step, state, times and — for output — the redacted chunk, so the page can update **without re-querying**.
- `AgentsLive` handles `{:agent_activity, _}` by updating the affected card through a stream insert, not the existing full re-query. The 250 ms debounced re-query stays for the existing `{:agent_event, _}` messages.
- The live panel holds hook output in a LiveView stream of lines with a client-side limit (the last 2,000 lines in the DOM); older lines are fetched on demand from the stored run.
- Output appends are coalesced per run to at most one push per 500 ms per viewer.
- Signal-light changes that happen without any message (Active turning Quiet with time) are driven by a 15-second `:tick` on the page, computing state from `last_signal_at`.
- Hook output is only broadcast to a separate per-task topic, `"agent_output:#{task_id}"`, which a LiveView subscribes to **only after** checking the viewer may see output ([§17](#17-permissions-and-plans)). The board-wide topic carries the last line only when the viewer is allowed; otherwise cards show "output hidden".

---

## 16. Security and privacy

### 16.1 Untrusted content

Hook output and step reasons come from agent machines and can contain anything, including text written to look like instructions or markup.

- Always rendered as escaped plain text through HEEx; never `raw/1`, Markdown or auto-linking.
- ANSI escape sequences and other control characters (except newline and tab) are stripped server-side before storage.
- Downloads are served with `Content-Type: text/plain; charset=utf-8`, `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`.
- Output is never fed back to agents through the API or MCP.

### 16.2 Redaction

Every chunk and reason passes through `Kanban.AgentActivity.Redactor` **before** it is stored or broadcast:

- The patterns in `Kanban.Tasks.CredentialShapes` (Stride tokens, cloud keys, private-key headers and the rest) are replaced with `[redacted: <kind>]`.
- Lines matching `KEY=value` where the key looks secret (`TOKEN`, `SECRET`, `PASSWORD`, `API_KEY`, …) have the value replaced.
- A redaction raises the existing credential-suspected audit event with the task id and kind only, never the matched text.
- A chunk split across two appends could split a secret; the redactor keeps a 256-byte overlap from the previous chunk of the same run and re-scans across the boundary.

Redaction reduces risk; it does not make output safe to publish. That is why output visibility is restricted ([§17](#17-permissions-and-plans)) and retention is short.

### 16.3 Abuse limits

Per-token rate limits on both endpoints, the size and count caps in [§11](#11-the-reporting-channel), and the claim-holder rule, so a token can only write to tasks it is actively working.

### 16.4 Retention

| Data | Kept |
|---|---|
| Activity events | 30 days |
| Hook runs | 14 days |
| `claimed_by_agent`, `last_signal_at` | With the task |

Retention is configuration. Neither table is included in workspace export or account data export; deleting a task or board deletes its rows by cascade.

---

## 17. Permissions and plans

| What | Who |
|---|---|
| Live cards, step tracker, signal state, activity log | Anyone who can see the board on `/agents` today |
| Hook output (console, last-line preview, download) | Board owner and members with modify access; read-only members see "output hidden" |
| Release task, Pause, Stop | Board owner |
| Follow an agent | Any board member |
| Reporting endpoints | The claiming agent's token, on a board it can modify |

**Plan.** Every other item in *Agent controls and approvals* is aimed at teams that need firm control. The recommendation is to make the live view an **Organization** feature: add `:live_agent_view` to `Kanban.Plans`, check it with `Plans.check_board/3` on the reporting endpoints (surface `:rest`) and per board on the page (surface `:live_view`), and show `LockedFeature` in place of the live elements on free boards. Free boards keep today's `/agents`, plus `claimed_by_agent` attribution, which is a correctness fix rather than a feature. See [§24](#24-decisions-needed).

---

## 18. Relationship to the Stop switch

The Stop switch ("pause every agent on a board at once") needs a way to tell agents to stop. The live view provides it:

- The activity endpoint's response carries an optional `directive`: `null`, `"pause"` or `"stop"`.
- Plugins check it on every report (at least every 60 seconds through heartbeats) and, on `pause`, finish the current step, record a `paused` event and wait; on `stop`, unclaim and end the loop.
- The live panel and wall view host **Pause after this step**, **Stop now** and **Resume** for one agent; the board header hosts the board-wide switch.

If the Stop switch is built before or with this item, these controls appear from the start. If not, the `directive` field ships as always-`null` so plugins already handle it.

---

## 19. Agents on older plugins

Agents that send no activity events still appear:

- Their card shows the existing status and the existing 60-minute stuck rule, labelled "No live reporting — update the Stride plugin".
- `claimed_by_agent` still works, because it is set by the claim endpoint.
- Final hook output from the `*_result` fields is stored as a `result_payload` hook run, so the console shows output once a claim or completion arrives, just not live.
- The panel shows the step tracker from `workflow_steps` after completion, the same data the task view's workflow-steps section shows today (`workflow_steps_section.ex`).

---

## 20. Telemetry

Declared in `Kanban.Telemetry.Catalog` with `metrics` and `persist`, emitted through `Kanban.Telemetry.emit/3`, tested with `attach_telemetry/2`, and added to the event reference in [Telemetry](../telemetry.md):

| Event | Measurements | Metadata |
|---|---|---|
| `[:kanban, :api, :agent_activity_recorded]` | `count` (events accepted) | `step`, `state` |
| `[:kanban, :api, :hook_run_started]` | `count` | `hook` |
| `[:kanban, :api, :hook_run_finished]` | `count`, `duration_ms`, `total_bytes` | `hook`, `status`, `truncated` |
| `[:kanban, :agent_activity, :redacted]` | `count` | `kind` |
| `[:kanban, :agent_activity, :retention_swept]` | `events`, `runs` | — |

No agent names, task titles, commands or output in metadata.

---

## 21. Translations, dark mode and docs

- Every visible string through `gettext`, including step names, signal states, console banners and aria labels; run `mix gettext.extract --merge` for all locales.
- The console uses the existing monospace and surface tokens; signal colours use the existing status tokens, with icons and text so colour is never the only signal; verified with `mix dark_mode.scan` and in both themes per [the dark-mode contract](../dark-mode-contract.md).
- The step tracker and console have accessible names; the console is a `role="log"` region with `aria-live="polite"` that announces only hook start, finish and failure, not every line.
- Docs:
  - API pages for the four new endpoints, the API README table, OpenAPI and `EndpointDocs`.
  - A user page, `docs/live-agent-view.md`: what each element means, who sees output, retention.
  - Agent-facing: `docs/AI-WORKFLOW.md` and `docs/AGENT-HOOK-EXECUTION-GUIDE.md` describe live reporting and the 409 handling.
  - A Resources how-to, "Watch your agents work".
  - `CHANGELOG.md` under `[Unreleased]`, mirrored in `priv/changelog/body.html`; ROADMAP status.

---

## 22. Testing strategy

### 22.1 Unit tests

| Module | Cases |
|---|---|
| `Liveness` | Each state at and around its thresholds; Failed overriding Active; no task held; clock skew. |
| `Steps` | Full workflow; skipped explorer and planner; inferred Implementation; review gate present and absent; `after_doing` retries; legacy task built from `workflow_steps`. |
| `HookRun.append/2` | Under and over 256 KB; truncation bookkeeping; command index ordering; finishing twice. |
| `Redactor` | Each credential shape; `KEY=value` lines; a secret split across two chunks; no false positives on ordinary test output; audit event without the matched text. |
| `ActivityEvent` changeset | Vocabulary, lengths, durations, batch size. |

### 22.2 API tests

- Claim holder can report; another token on the same board gets `409 not_claim_holder`; after unclaim `409 claim_released`; after expiry `409 claim_expired`.
- Read-only token and read-only board refused; plan refusal returns `403 plan_required` when enforced.
- Size, count and rate limits with `Retry-After`.
- Result payloads on claim and complete create `result_payload` runs when no live run exists, and do not duplicate a live run.
- Claim extension behaviour, if adopted.
- `claimed_by_agent` set on claim, cleared on unclaim and on `ClaimRelease`.
- Docs coverage for every new route.

### 22.3 LiveView tests

- Cards show step, strip, last line and signal; ordering by state.
- A broadcast updates one card without re-running the roster query.
- Output streams into the console for an owner; a read-only member sees "output hidden" and receives no output messages.
- Follow mode, Jump to latest, truncation banner, download headers.
- Release task by owner; refused for others.
- Wall view layout and ordering; phone width shows one column.
- Legacy agent shows the "No live reporting" label and the old stuck rule.
- Locale rendering and telemetry events.

### 22.4 Plugin tests

Hermetic tests in each port: a stub server receives activity and hook-run posts in the right order; output is batched; a failing or slow server never fails or slows the hook beyond the timeout; `409` responses reach the agent as a stop message; `STRIDE_LIVE_REPORTING=0` sends nothing; `.sh` and `.ps1` produce identical requests.

### 22.5 Exploratory checks

- Explore a long `mix test` run streaming to two viewers, to find dropped, duplicated or out-of-order lines.
- Explore output containing tokens, ANSI codes, very long lines and non-UTF-8 bytes, to find leaks or broken rendering.
- Explore an agent losing network mid-hook, to find runs stuck in "running" and how Silent and Abandoned appear.
- Explore releasing a task while its agent is in `after_doing`, to find how quickly and clearly the agent stops.

---

## 23. Phased delivery

### Phase 0 — Attribution (small, ships first)

1. Add `claimed_by_agent` and `last_signal_at`; set them on claim, clear on unclaim and claim release.
2. Use `claimed_by_agent` in the roster, feed and detail panel.

### Phase 1 — Server

3. `agent_activity_events` and `hook_runs` tables and schemas.
4. `Kanban.AgentActivity` context, `Redactor`, `Liveness`, `Steps`.
5. Activity endpoint with claim-holder rules, limits and docs.
6. Hook-run endpoints with streaming append, truncation, redaction and docs.
7. Store `*_result` payloads and show `after_goal` output as hook runs.
8. Retention worker and telemetry.
9. The `:live_agent_view` plan feature (if decided).

### Phase 2 — Screens

10. Live roster cards, header counts, Silent replacing Stuck for live-capable agents.
11. Live agent panel: header, task card, step tracker, activity log.
12. Hook console with per-task output topic and permission checks.
13. Wall view.
14. Actions: Release task, Comment, Follow notifications.
15. Docs, Resources how-to, CHANGELOG.

### Phase 3 — Plugins

16. Shared contract `stride/docs/porting-live-reporting.md`.
17. stride: hook-run streaming and step events (`.sh` and `.ps1`), heartbeat, 409 handling, tests.
18. Then the same for stride-gemini, stride-copilot, stride-codex, stride-opencode and stride-pi, two tasks each (reporting, then workflow and 409 handling).

Phase 2 can be built against stored test data while Phase 3 is in progress; the view is useful as soon as the first port reports.

---

## 24. Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| 1 | Plan: Organization only, or free? | Organization only, matching the rest of *Agent controls and approvals*; `claimed_by_agent` stays free. |
| 2 | Who sees hook output? | Board owner and members with modify access; read-only members see steps only. |
| 3 | Retention | Hook runs 14 days, activity events 30 days; excluded from exports. |
| 4 | Should activity extend the 60-minute claim? | Yes: expiry becomes "60 minutes without a signal". |
| 5 | Build the Stop switch's `directive` channel now? | Ship the field as always-`null` now so plugins handle it; build the switch as its own item. |
| 6 | Signal thresholds | Active under 2 minutes, Quiet 2–10, Silent over 10; configurable. |
| 7 | Stored output size per run | Last 256 KB. |
| 8 | Per-project opt-out for reporting | Yes, `STRIDE_LIVE_REPORTING=0`. |
| 9 | Live panel as a full page or inline only | Both: inline from the roster, full page at `/agents/live/:agent_key` for sharing. |
