# Native Mobile Apps, Phase 1 — Implementation Design

**Roadmap item:** *Native mobile apps*, under *Planned*: "iPhone, iPad and Android apps for the human side of the loop: hear when work is waiting on you, review with the verdicts first, approve with Face ID or a fingerprint, and keep Ready full." ([ROADMAP](../../ROADMAP.md))

**Status:** proposal. Nothing in this document is built yet. Every statement about today's code was checked against the source on 2026-11-11; references are given as `path:line` so they can be re-checked.

**Date:** 2026-11-11.

Phase 1 is the first release of two native apps, **Stride for iOS and iPadOS** (Swift and SwiftUI) and **Stride for Android** (Kotlin and Jetpack Compose), plus the Phoenix backend they need. Both apps have the same scope, and both live in this repository beside the web app.

Stride's agents do the work; people decide. Today a decision waits until someone opens a laptop and looks. Phase 1 makes the phone the place where a person:

1. **hears** that something is waiting on them, but only when it holds agents up;
2. **understands** it in a minute, with the evidence before the code;
3. **decides**: approve, request changes, unblock a released task or fill an empty Ready column.

Anything that doesn't shorten that wait isn't in Phase 1 ([§21](#21-not-in-phase-1)).

**The apps are an Organization plan feature,** like notifications today ([§10](#10-plans-and-access)).

**Designs.** The screens below are drawn in three Claude artifacts. They're private: others can open them only after they're shared from each page's Share menu.

- [Stride Mobile 1.0](https://claude.ai/artifact/28fhXeqYUYDc9XAqZC3mze) is the Phase 1 design. It has an iPhone row and an Android row with the same 14 screens, plus iPad and Android-tablet review workspaces. Each screen is one design with a Platform setting, so the two rows can't drift apart. Every screen has a light and a dark version.
- [Stride Design System](https://claude.ai/artifact/Ps58y4mD5Y8iURPZnXsiJ2) holds the tokens, fonts and components the screens use. They're taken from the web app's `assets/css/app.css` and its Phoenix components.
- [Stride Mobile](https://claude.ai/artifact/DPsk9WsC9iPX1gKxikTMUn) is the first exploration. It includes features planned for after Phase 1.

The task, agent and metric data in the designs are realistic examples, not real data.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Terms](#2-terms)
3. [What exists today](#3-what-exists-today)
4. [At a glance](#4-at-a-glance)
5. [Navigation and platform conventions](#5-navigation-and-platform-conventions)
6. [Screens](#6-screens)
7. [Backend changes](#7-backend-changes)
8. [Database changes](#8-database-changes)
9. [Security and privacy](#9-security-and-privacy)
10. [Plans and access](#10-plans-and-access)
11. [Offline and caching](#11-offline-and-caching)
12. [The iOS and iPadOS app](#12-the-ios-and-ipados-app)
13. [The Android app](#13-the-android-app)
14. [Repository structure](#14-repository-structure)
15. [CI, signing and releases](#15-ci-signing-and-releases)
16. [Telemetry](#16-telemetry)
17. [Translations, accessibility and dark mode](#17-translations-accessibility-and-dark-mode)
18. [Docs](#18-docs)
19. [Testing strategy](#19-testing-strategy)
20. [Phased delivery](#20-phased-delivery)
21. [Not in Phase 1](#21-not-in-phase-1)
22. [Risks](#22-risks)
23. [How to judge it](#23-how-to-judge-it)
24. [Decisions needed](#24-decisions-needed)

---

## 1. Goals and non-goals

### Goals

- **Shorter waits on people.** That means time in Review, time a released task or an expired claim sits unattended, and time a failed `after_goal` hook goes unnoticed.
- **A phone review that judges the evidence.** The agent's summary, the checks, the reviewer verdicts, the acceptance criteria, the security review and the exploratory findings come first. The code for flagged files comes after.
- **No rubber-stamping.** Approval needs a biometric check. The server refuses a phone approval of a large change. Every approval is recorded in the audit log with the device that sent it.
- **Keep Ready full.** Show when agents are idle because nothing is Ready, and let a person promote Backlog tasks from the phone.
- **One scope on two platforms.** iOS and Android ship the same features, each using its own platform's conventions.
- **A backend that's useful without the apps.** User sign-in for devices, the decisions endpoint, review over the API and push delivery could also serve a web app, a desktop menu-bar app or Slack actions.

### Non-goals for Phase 1

- **Running agents or hooks on the phone.** Hooks run on developers' machines by design.
- **Board configuration.** Columns, hooks, API tokens, integrations, members, the org console, SSO, SCIM and security policies all stay on the web. The app links to the right web page.
- **Writing full tasks.** The phone captures drafts. Agents and ideation write the rich specification.
- **Metrics.** The only number the apps show is the "waiting on you" count, in the widget.
- **Everything in [§21](#21-not-in-phase-1):** Live Activities, screenshot bug capture, offline decisions, pen notes, planning mode, mission control and the watch.
- **An installable web app (PWA) with web push.** The analysis behind this plan proposed one as a cheaper first step. The backend here would serve it too, but this document covers the native apps ([decision 1](#24-decisions-needed)).

---

## 2. Terms

| Term | Meaning |
|---|---|
| **Decision** | One thing waiting on the signed-in person: a review, a released task, an expired claim, a failed goal hook, or an empty Ready column. Each one is a card on Now. |
| **Holds up** | How many unfinished tasks are waiting on a decision, through `dependencies` ([§7.4](#74-decisions-api)). Now is sorted by it. |
| **Device** | One installation of the app, signed in as one person. A device has its own tokens and push token, and the person or an org-admin can revoke it. |
| **Device class** | `phone` or `tablet`. The large-change guard applies to phones only. |
| **Large change** | A task whose changed files are more than 10 files or more than 500 changed lines, or whose diff was cut at the per-diff cap ([§7.6](#76-large-change-guard-and-highlighted-diffs)). |
| **Verdicts** | The sections of `reviewer_result`: acceptance criteria, project checks, testing strategy, patterns, pitfalls and security considerations. |
| **Flagged file** | A changed file that a reviewer issue or the security section points at. Flagged files are listed first. |
| **Draft** | A task captured on the phone and not yet filled in. It's saved in Backlog with the new `draft` flag ([§8](#8-database-changes)). |

---

## 3. What exists today

### 3.1 Notifications

- **The event types.** `Kanban.Notifications.Preference` defines 12 event types (`lib/kanban/notifications/preference.ex:15-28`): `review_requested`, `task_assigned`, `task_reviewed`, `task_unclaimed`, `claim_expired`, `goal_completed`, `after_goal_failed`, `board_access_changed`, `target_status_changed`, `weekly_digest`, `comment_added` and `mentioned`. Nothing emits `comment_added` yet.
- **The emitter.** `Kanban.Notifications.Events` (`lib/kanban/notifications/events.ex:1`) turns lifecycle moments into notifications, for example `review_requested` at `:74` and `after_goal_failed` at `:205`.
- **One entry point.** Every event goes through `Kanban.Notifications.notify/3` (`lib/kanban/notifications.ex:179-188`).
  - It checks the plan (`check_board_plan`, `:444-449`).
  - In one transaction it resolves the recipients (`Recipients.resolve/4`, `recipients.ex:29`), inserts a row for each, and enqueues the email jobs (`enqueue_emails!`, `:402-413`).
  - After the commit it broadcasts on `"user:<id>:notifications"` (`:128-130`, `:415-421`).
- **Two channels today, with no channel abstraction.**
  - **In app:** the bell (`lib/kanban_web/components/notification_bell.ex:19`) and `/notifications`.
  - **Email:** `Kanban.Notifications.EmailWorker` on the Oban `:notifications` queue (`lib/kanban/notifications/email_worker.ex:36-39`). It checks the plan again when it runs (`:127-133`).
  - **The weekly digest** is a separate Oban cron path. It doesn't go through `notify/3`.
- **Privacy is already right for a lock screen.** Titles carry only the task identifier and title, never agent free text (`events.ex:11-16`). The only stored free text is review notes and the unclaim reason, cut to 500 characters (`:63`, `:313-331`). `after_goal_failed` stores the exit code and duration, never the hook output (`:464-474`).
- **Preferences.** `notification_preferences` has `in_app` and `email` for each event type (`preference.ex:32-40`). A row exists only once a setting has been changed; defaults come from `default_preference/1` (`notifications.ex:114-122`). **There are no quiet hours, no snooze and no "only when it blocks" mode.**

### 3.2 Reviews

- **The web review.** `KanbanWeb.ReviewLive` at `/review` (`lib/kanban_web/router.ex:418`).
  - **Approve:** `handle_event("approve")` (`lib/kanban_web/live/review_live.ex:83-102`) calls `Kanban.Reviews.approve_review/3` (`lib/kanban/reviews.ex:234`).
  - **Request changes:** goes through `submit_request_changes` (`review_live.ex:115-144`) to `Reviews.request_changes_review/3` (`reviews.ex:254`). Notes are required (`:273-291`).
- **The shared path.** Both actions run `perform_review` → `commit_review!` (`reviews.ex:293-352`), which:
  - re-reads the pending review;
  - checks board write access (`:361`);
  - stamps `reviewed_at` and `reviewed_by_id` (`:374-383`).
- **What each outcome does.**
  - **Approve** then moves the task to Done (`lib/kanban/tasks/agent_workflow/review.ex:108-153`).
  - **Request changes** leaves it in the Review column (`reviews.ex:264-269`).
- **Pending reviews.** A pending review is a task with `needs_review` true, `review_status` nil or `:pending`, in a column named "Review" (`reviews.ex:167-176`).
- **Reviews write no audit event.** Neither `reviews.ex` nor `agent_workflow/review.ex` calls `Kanban.AuditLog`.
- **The API has no human verdict.** `review_status` and `review_notes` are refused on `PATCH /api/tasks/:id` (`lib/kanban_web/controllers/api/task_param_filter.ex:158`, `:195-198`). `mark_reviewed` (`router.ex:221`) is an agent call that only acts on a verdict a person has already recorded.
- **Review evidence on the task** (`lib/kanban/tasks/task.ex`):

  | Field | Line | What it holds |
  |---|---|---|
  | `completion_summary` | `:288` | the agent's summary |
  | `completion_notes` | `:296` | long-form notes, including exploratory-testing findings |
  | `review_report` | `:345` | the review as markdown |
  | `reviewer_result` | `:360` | the verdicts; required sections at `lib/kanban/tasks/completion_validation/review_contract.ex:53-71` |
  | `acceptance_criteria` | `:171` | a string |
  | `behaviour_test_matrix` | `:246` | the behaviour matrix |
  | `security_considerations` | `:262` | an array of strings |

  The security review's findings arrive inside `reviewer_result["security_considerations"]`.
- **Changed files and diffs.** `changed_files` is an array of `{path, diff, diff_url}` (`task.ex:354`). It's written only by `PUT /api/tasks/:id/changed_files` (`router.ex:220`). Each diff is capped at 500 lines (`lib/kanban/tasks/completion_validation/changed_files.ex:26`).
- **The web shows diffs** in `KanbanWeb.ReviewDiffPanel` (`lib/kanban_web/components/review_diff_panel.ex:107`), **with no syntax highlighting.** Lines are only classed by their first character (`:27-53`). **Makeup isn't a dependency** (nor is `ex_doc`).

### 3.3 Dependencies, claims and goals

- **Dependencies.** A task's `dependencies` is an array of identifiers (`task.ex:301`), with no join table. `Kanban.Tasks.Dependencies.get_dependent_tasks/1` (`lib/kanban/tasks/dependencies.ex:189-201`) finds a task's dependents. **Nothing counts or ranks by dependents today.**
- **Claims.**
  - A claim lasts 60 minutes, written inline at `lib/kanban/tasks/agent_workflow/claiming.ex:87`.
  - Nothing releases an expired claim: the claim queries just treat it as claimable again (`claiming.ex:109`, `lib/kanban/tasks/agent_queries.ex:130`).
  - `Kanban.Notifications.ClaimExpiryWorker` sends `claim_expired`.
- **Released tasks.** The unclaim reason is not stored on the task. It's logged, then copied into the notification body (`claiming.ex:244-262`, `events.ex:298-308`).
- **`after_goal` failures.** They're recorded by `Goals.record_after_goal_failure/2` (`lib/kanban/tasks/goals.ex:275-280`). Each attempt `{exit_code, output, duration_ms}` is kept on the goal (`task.ex:378-387`).
- **Empty Ready columns.** Nothing detects them.
  - `Kanban.Agents.Roster` derives each agent's status (`:working`, `:waiting` or `:idle`) from the columns its tasks are in (`lib/kanban/agents/roster.ex:148-157`).
  - **Idle** means the agent has no task in Doing or Review, not that Ready is empty.
- **Drafts.** There's no draft concept. Backlog tasks can't be claimed only because the claim queries require a column named "Ready" (`agent_queries.ex:127`, `:203`).

### 3.4 Sign-in and access

- **The web sign-in.** `KanbanWeb.UserAuth` follows the `phx.gen.auth` layout (`lib/kanban_web/user_auth.ex:1`).
  - **Sudo mode** is a 10-minute window (`:400-416`).
  - **Two-factor sign-in** uses TOTP, in `Kanban.Accounts.TwoFactor` (`lib/kanban/accounts/two_factor.ex:1`).
  - **Company SSO** supports both OIDC and SAML (`lib/kanban/sso.ex:1-18`).
  - **An Organization can require two-factor.** `OrganizationTwoFactorGate` enforces it (`lib/kanban_web/user_auth/organization_two_factor_gate.ex:1`).
  - There are no idle-timeout or session-length policies.
- **API tokens are for agents.** `Kanban.ApiTokens.ApiToken` (`lib/kanban/api_tokens/api_token.ex:17-32`) is scoped to a user plus one board or one Organization workspace. It's authenticated by `KanbanWeb.Plugs.AuthenticateApiToken` (`lib/kanban_web/plugs/authenticate_api_token.ex:1`). **There is no person-level token.**
- **Plan checks.** `Kanban.Plans` makes every paid-or-free decision (`lib/kanban/plans.ex:1`).
  - `:notifications` is a paid feature (`:89-99`).
  - `check_user/3` (`:284`) and `check_board/3` (`:270`) return `{:error, {:plan_required, feature}}`.
  - Enforcement is behind `:plans_enforced` (`:129`).

### 3.5 Live updates, the API contract and the audit log

- **Sockets and channels.**
  - The endpoint declares only the LiveView socket (`lib/kanban_web/endpoint.ex:21-22`). **There is no `UserSocket` and no Phoenix Channel.**
  - `KanbanWeb.AgentsPresence` (`lib/kanban_web/channels/agents_presence.ex:1`) is a Presence on the topic `"agents"`.
- **PubSub topics** are inline strings: `"board:#{id}"` (`lib/kanban/tasks/broadcaster.ex:40`) and `"agents:#{id}"` (`:99`).
- **The OpenAPI contract.** `priv/openapi/stride-api.json` is OpenAPI 3.1.0. It's served at `/api/openapi.json` (`router.ex:208`). `test/kanban_web/controllers/api/open_api_contract_test.exs` keeps it in step with the router: every route documented, nothing extra, `bearerAuth` matching the pipeline.
- **The audit log.** `Kanban.AuditLog.event/2` (`lib/kanban/audit_log.ex:119-129`) does three things: it emits telemetry, writes a log line, and inserts an `audit_events` row (`lib/kanban/audit_log/audit_event.ex:40-54`). Keys that look like secrets are dropped (`audit_log.ex:98`).
- **Telemetry.** New events go through `Kanban.Telemetry.emit` (`lib/kanban/telemetry.ex:84-85`) and are declared in `Kanban.Telemetry.Catalog` ([`docs/telemetry.md`](../telemetry.md)).
- **Oban** is in place (`mix.exs:97`). **Pigeon isn't.**
- **Gettext** covers seven locales: de, en, es, fr, ja, pt and zh.

### 3.6 Metrics: Review wait reads as zero today

The measure that judges Phase 1 is how long tasks wait in Review. As written today, that metric comes out near zero for approved tasks:

- `fetch_review_wait_times` measures `reviewed_at - completed_at`, clamped at 0 (`lib/kanban/metrics.ex:419-442`).
- On a `needs_review` task, completion doesn't stamp `completed_at` (`lib/kanban/reviews.ex:12-14`).
- At approval, `persist_review_fields` stamps `reviewed_at` first (`reviews.ex:374-383`). `move_to_done` stamps `completed_at` afterwards (`lib/kanban/tasks/agent_workflow/review.ex:145`).

So the measured wait is a fraction of a second. The real wait runs from `review_requested_at` (`task.ex:368`), which completion stamps, to `reviewed_at`. **This has to be fixed before Phase 1 starts, so there's a baseline to compare against** ([§20](#20-phased-delivery), task 0).

### 3.7 CI and packaging

- **CI.** `.github/workflows/elixir.yml` is the only workflow, and it has no `paths` filter (`:9-16`).
- **Docker.** `.dockerignore` doesn't mention `mobile/`. The Dockerfiles copy only named folders (`Dockerfile.production:49-81`), so the apps would be sent in the build context but would never land in the image.
- **`.gitignore`.** Its `package.json`, `package-lock.json` and `node_modules` entries aren't anchored (`:64-66`). They would also match inside `mobile/`.

---

## 4. At a glance

```text
 iPhone / iPad (SwiftUI)          Android phone / tablet (Compose)
 ───────────────────────          ────────────────────────────────
 StrideKit: API client,           core: API client, auth,
 auth, cache, channel, push       cache, channel, push
        │   ▲                              │   ▲
 HTTPS  │   │ WebSocket            HTTPS   │   │ WebSocket
        ▼   │                              ▼   │
 ┌────────────────────────── Phoenix (this repo) ──────────────────────────┐
 │ /oauth/*        sign-in for a device: PKCE, rotating refresh tokens     │
 │ /api/me/*       the person API: decisions, reviews, boards, agents,     │
 │                 capture, settings, devices (device tokens only)         │
 │ /api/socket     UserSocket: me:inbox and me:agents channels             │
 │ Kanban.Decisions    builds and ranks Now                                │
 │ Kanban.Devices      devices, tokens, approval keys                      │
 │ Kanban.Push         a delivery channel in notify/3, Oban PushWorker     │
 │ Kanban.Reviews      approve and request changes (existing), plus audit  │
 └─────────────────────────────────────────────────────────────────────────┘
        │                              │
        ▼                              ▼
      APNs                            FCM
```

**The person API is separate from the agent API.**
- A device token works only on `/oauth/*`, `/api/me/*` and `/api/socket`.
- An agent's API token works only on the existing agent routes.
- A phone can never claim, complete or `mark_reviewed` a task ([§9.2](#92-two-kinds-of-token-never-mixed)).

---

## 5. Navigation and platform conventions

### 5.1 One navigation on both platforms

| Area | What it is |
|---|---|
| **Now** | The home screen: everything waiting on you, ranked by how much it holds up. It carries a badge with the count. |
| **Review** | The review queue, verdicts first. |
| **Boards** | One board, one column at a time; promote Backlog to Ready. |
| **Agents** | Who is on what, and each goal's progress. |
| **New task** | Quick capture. On iOS it's a top-corner button; on Android it's an extended floating button. |
| **Settings** | Opened from the avatar on Now: notifications, this device and sign-out. |

The analysis proposed four tabs: Now, Agents, Boards and Me. The design puts **Review** in Me's place. Review is the screen Phase 1 is built around, so it gets one tap. Settings is used rarely, so it moved to the avatar. **This document follows the design.**

### 5.2 iOS and iPadOS conventions

- Large titles.
- A tab bar with Now, Review, Boards and Agents.
- New task and Settings in the top corner.
- Sheets with a grabber.
- Face ID or Touch ID for Approve.
- A WidgetKit widget.

These come from the canvas's iOS notes.

### 5.3 Android conventions (Material 3)

- A top app bar.
- A navigation bar with a pill indicator.
- An extended floating button for New task.
- Filter chips.
- Sheets with 28 dp corners.
- `BiometricPrompt` for Approve.
- A Glance widget.

**Stride's own colours, not Material You.** The app uses Stride's colours from the generated tokens, not the wallpaper-based dynamic colour, so it looks like Stride on both platforms.

### 5.4 Tablets

Tablets get the same app with a split layout: navigation, then the review queue, then the selected task's spec beside its diff.
- **iPad** uses a sidebar (`NavigationSplitView`).
- **Android** uses `NavigationSuiteScaffold` (a rail at this width) with `ListDetailPaneScaffold`.

The layout switches on the available width, not the device, so an iPad in narrow split view gets the phone layout. The phone size limit doesn't apply on a tablet ([§6.15](#615-tablet-review-workspace)).

---

## 6. Screens

Each section gives the screen's job, what it shows, its actions and states, and the endpoint behind it. Names in quotes are the design's copy. They're English source strings, translated into all seven locales ([§17](#17-translations-accessibility-and-dark-mode)).

### 6.1 Sign in

- **Shows:**
  - the Stride logo and the line "Your agents do the work. Stride tells you when one of them is waiting on you";
  - three points: review verdicts first and approve with Face ID (on Android, "your fingerprint or face"); unblock released tasks, expired claims and failed goal hooks; keep Ready full.
- **Action:** **Sign in** opens a secure browser window: `ASWebAuthenticationSession` on iOS, a Custom Tab through AppAuth on Android.
  - The note under it says "Your company sign-in and two-step check work as they do on the web".
  - "New to Stride? Create an account on the web" opens the sign-up page in the system browser. The app creates no accounts.
- **Behind it:** the OAuth flow in [§7.1](#71-sign-in-for-a-device).
- **States:**
  - **Cancelled:** the user is back on the screen, with no error.
  - **Network error:** "Couldn't reach Stride. Check your connection and try again."
  - **No Organization plan:** a panel saying the app is part of the Organization plan, with a link to the pricing page ([§10](#10-plans-and-access)).

### 6.2 Turn on notifications

- **When:** shown once, right after the first sign-in, before the system permission prompt.
- **Shows:**
  - three sample notifications: "W2701 is ready for review now · Holds up 3 tasks", "Codex's claim on W2702 expired" and "G509 goal hook failed";
  - the promise: "Stride only sends a notification when something holds up your agents. Each one opens the app. Nothing is approved from a notification."
- **Choices:**
  - **"Only when it blocks something"** (Recommended): reviews, released tasks, expired claims and failed goal hooks.
  - **"Every event"**: also when a task moves or a goal finishes.
  - **Quiet hours:** 22:00 to 07:00 by default, in the device's time zone.
- **Actions:**
  - **Turn on notifications** asks for the system permission: iOS authorization; on Android 13 and later, `POST_NOTIFICATIONS`. It then registers the push token ([§7.8](#78-push-delivery)).
  - **Not now** skips the prompt; it can be turned on later in Settings.

### 6.3 Now: the decisions inbox

- **Header:**
  - "Now" with the avatar, which opens Settings;
  - "5 waiting on you · 6 tasks held up";
  - "3 agents working".
- **Filter chips:** All, Reviews, Problems (released, expired and hook failed) and Ready.
- **Order:** "Sorted by how much each one holds up" ([§7.4](#74-decisions-api)).

| Card | Shows | Actions |
|---|---|---|
| **Review** | "holds up 3", age, identifier and title, agent avatar, "Claude · 6 files · +41 −6", verdict pills (Acceptance, Tests, Patterns, Security) and the first failed verdict's note | **Open review** |
| **Claim expired** | "holds up 2", "Codex held it for 60 minutes with no update. It is back in Ready for another agent." | **Move to Backlog**, **Open on the web** |
| **Goal hook failed** | "holds up 1", the goal, "after_goal: git push rejected (non-fast-forward)" | **View log**, **Open on the web** |
| **Released by agent** | the agent's reason in quotes, from the `task_unclaimed` notification body | **Reply** (adds a comment), **Move to Backlog** |
| **Ready is empty** | "Ready is empty · Sales", "1 agent idle. 5 tasks in Backlog to choose from." | opens that board on Backlog |

- **Not in 1.0:** swipe to approve. Approval always goes through the review screen and a biometric check. Swiping to open a review is fine.
- **Live:** the list updates over the `me:inbox` channel ([§7.7](#77-live-updates)). A card leaves the list when its cause clears, for example when another reviewer approves the task or an agent claims the released task.
- **States:**
  - **Empty:** "Nothing is waiting on you. Your agents have what they need."
  - **Loading:** skeleton cards.
  - **Offline:** a banner, "Offline · showing what you had at 14:02", with the actions disabled ([§11](#11-offline-and-caching)).

### 6.4 Review: verdicts first

**What the screen shows, in order:**

1. **The header:** identifier and title, the priority dot, "holds up W2702, W2703, W2710", the agent and the time it took, and the goal.
2. **"What the agent says it did":** `completion_summary`.
3. **"Reviewer verdicts":** "3 of 4 passed", with tiles for Acceptance (4/4), Testing, Patterns and Pitfalls. A failed tile shows its note, for example "The member query is written in OrgLive.Show. Project rule: queries belong in the context module."
4. **"Tests and checks":** the `project_checks` result ("All passed").
5. **"Security review":** the `security_considerations` section ("No findings", or the count by severity).
6. **"Exploratory testing":** the findings count ("1 low finding").
7. **"Files · 6 · Flagged first":** flagged files first, each with `+`/`−` counts. A row opens the diff (§6.5).
8. **Bottom bar:** **Request changes** and **Approve** (with the Face ID or fingerprint glyph).

**States:**

| State | What happens |
|---|---|
| **Approving** | the biometric prompt (§6.6) |
| **Approved** | "Approved. W2702, W2703 and W2710 can start." with **Next**, which opens the next review |
| **Requesting changes** | the sheet (§6.7) |
| **Changes sent** | "Changes requested. W2701 is back in Doing for Claude." with **Next** |
| **Large change** | Approve is replaced by "Approve on tablet or web" (§6.8) |
| **Already decided** | "Sam approved this 2 minutes ago." The card leaves the queue (an HTTP 409 from the server) |
| **Resubmitted** | "Claude sent a new version. Reload to review it." (409, `review_requested_at` changed) |

**About the "Changes sent" copy.** Request changes leaves the task in the Review column today (§3.2), and the agent moves it when it calls `mark_reviewed`. So the copy has to match what the server actually reports. It should read "is waiting for Claude to pick up the changes" unless a decision changes that flow.

**Behind it:**
- `GET /api/me/reviews/:task_id` for the screen ([§7.5](#75-review-api));
- `POST .../approve` and `POST .../request_changes` for the actions.

**Exploratory findings.** These come from `completion_notes` today, which is free text. The count shown is the number of findings the structured exploratory block reports, when there is one. Otherwise the row says "See notes on the web". The free text isn't parsed on the phone.

### 6.5 Flagged file

- **Header:** the file name, "1 of 6", "flagged", "+11 −2", the language, and the full path.
- **The diff:**
  - read-only and unified, with line numbers;
  - syntax-highlighted by the server ([§7.6](#76-large-change-guard-and-highlighted-diffs));
  - long lines wrap.
- **The reviewer's note** sits inline at the line it names, for example "Patterns reviewer: this query belongs in the Organizations context, not the LiveView", when the issue carries a file and line ([§7.5](#75-review-api)).
- **Footer:** "Highlighted on the server. Long lines wrap. Notes on a single line come later; for now, put them in Request changes."
- **Actions:**
  - **Back to verdicts**;
  - **Next file**, or a swipe between files;
  - with a keyboard, F.

### 6.6 Approve with Face ID or BiometricPrompt

- **On iOS:** the system Face ID sheet, with the reason "Approve W2701".
- **On Android:** `BiometricPrompt` with the title "Approve W2701" and the subtitle "Moves it to Done and lets 3 waiting tasks start". It accepts "Touch the fingerprint sensor" or a face, with **Use PIN** and **Cancel**.

**Approval key: an Approve the server can verify.**

- **The key.** At sign-in, the app creates an approval key in the Secure Enclave (iOS) or the Android Keystore. The key is non-exportable, P-256, and needs user authentication for each use. The server stores its public key on the device row.
- **Approve:**
  1. The app asks for a one-time challenge.
  2. It unlocks the key with a biometric (or, as a fallback, the passcode).
  3. It signs the challenge plus the task, `review_requested_at` and the decision.
  4. It sends the signature with the approval.
- **The server** checks the signature against the device's public key ([§7.5](#75-review-api)), and the audit entry records `approval_key: true`.

A biometric check on its own happens only in the app. A compromised app could skip it and the server would never know. The signature proves that the device's protected key was unlocked for this exact approval. See [decision 4](#24-decisions-needed).

### 6.7 Request changes

- **What it is:** a sheet titled "Request changes", with **Cancel** and **Send**.
- **The field:**
  - "What needs to change" is required, as on the web (`reviews.ex:273-291`);
  - the keyboard's microphone is the dictation path, with no extra code;
  - the placeholder says "Dictate with the keyboard's microphone".
- **"Add the Patterns finding"** (one chip per failed verdict) inserts that verdict's note into the text, so the agent sees the finding it has to fix.
- **Send** calls `POST /api/me/reviews/:task_id/request_changes`. It needs no biometric: requesting changes only returns work to the agent.

### 6.8 Large change: not on a phone

- **The banner** sits above the verdicts: "Too large to approve on a phone. 14 files and 652 changed lines; a phone can approve up to 10 files or 500 lines. Approve it on a tablet or on the web. You can still request changes here."
- **The button.** Approve becomes **Approve on tablet or web**. It opens the review on the web in the system browser, at `/review` with that task selected.
- **The server decides.** The app reads `approvable_here` and the reason from the review response. It doesn't compute the limit itself, and the server refuses a phone approval above the limit even when an app asks ([§7.5](#75-review-api)).

### 6.9 Boards: promote to Ready

- **Header:**
  - the board name;
  - "1 agent idle · Ready is empty";
  - a board picker for the user's boards in the current workspace.
- **Column chips:** "Backlog 5", "Ready 0", "Doing 1" and "Review 1". Done is behind "Done", read-only.
- **Backlog cards:**
  - identifier and title, the priority dot and the first label;
  - "3 criteria · 2 files · 2 security notes";
  - or **Draft** for a captured task.
  - Tapping the checkbox selects the card; tapping the card opens the read-only task (title, description, acceptance criteria, key files, security considerations and comments).
- **Choose what agents can pick up:**
  - **"Review them before Done"** is a switch that sets `needs_review` on the selected tasks.
  - **"Move 3 to Ready"** promotes them.
- **Drafts** can't be selected for Ready on the phone; they say "Finish on the web" ([decision 6](#24-decisions-needed)).
- **Behind it:** `GET /api/me/boards`, `GET /api/me/boards/:id/columns/:name` and `POST /api/me/boards/:id/promote`.

### 6.10 Agents: goal progress

- **"Working now · 3 of 4 busy":** one row per agent, from `Kanban.Agents.Roster`. Each row shows the avatar, the name, the current task and a status chip:
  - **Review** ("W2701 waiting for your review");
  - **Doing** ("W2711 implementing · 22 min");
  - **Idle** ("Idle · Sales has nothing in Ready");
  - **Stuck**: over 60 minutes on a task (`roster.ex:37`).
- **"Goals · 3 open":** each goal shows its progress ("4/9"), what's waiting on you, what's in progress, and "Hook failed" when its last `after_goal` attempt failed.
- **Live:** `me:agents` ([§7.7](#77-live-updates)).
- **Gap: the hook chip.** The design shows "running checks · after_doing". The roster doesn't know which hook an agent is running: it derives status from columns. **1.0 shows the column and time on task**, and the hook chip waits until the server records the running hook.

### 6.11 New task (Capture)

- **The form:**
  - the board ("Sales");
  - the type, a segmented control with Work and Defect;
  - "Title";
  - "One sentence about it", with dictation.
- **Save** creates the task in that board's Backlog with `draft: true` and `created_via: "mobile"`.
- **The confirmation:** "Saved as a draft in Sales Backlog. Add acceptance criteria and key files on the web before an agent picks it up."
- **Behind it:** `POST /api/me/tasks`.

### 6.12 Settings

- **Account:** "Sam Rivera · Northwind · Organization plan".
- **Notify me:** "Only when it blocks something" (Recommended) or "Every event".
- **Events:** a switch each for Review requested, Task released, Claim expired and Goal hook failed, with the one-line explanations from the design.
- **Quiet hours:** a switch and a time range.
- **The system setting for sounds:** "Sounds and banners in iOS Settings", or on Android "Sound and vibration for each event in Android settings", which opens the app's notification settings.
- **This device:** "iPhone 15" or "Pixel 8", and **Sign out of this device**, which revokes the device on the server and wipes the cache.
- **Language and theme:** "Language and light or dark follow your iOS settings" (Android on Android).
- **A link to manage other devices** opens the web settings page.
- **Behind it:**
  - `GET/PUT /api/me/notification_settings` ([§7.9](#79-notification-settings-for-push));
  - `DELETE /api/me/devices/current`.

### 6.13 Push notifications and the widget

- **The notification:**
  - title "W2701 is ready for review";
  - body "Add seat count to org admin page. Tests pass, 1 pattern finding. Holds up 3 tasks.";
  - one action, **Open review**.
- **Every notification opens the app.** "There is no Approve on a notification: approving needs the review screen and Face ID."
  - On iOS each event type has its own notification category.
  - On Android each event type has its own notification channel, so it can be muted in system settings.
- **The body's facts come from structured fields only:** verdict counts, the holds-up count and the identifier and title ([§9.4](#94-what-a-notification-and-the-widget-may-show)).
- **The widget:**

  | Size | Shows |
  |---|---|
  | Small | "5 waiting on you · 1 review · 3 problems" |
  | Medium | the top three decisions by identifier and kind, for example "W2701 Review · holds up 3" |

  Tapping it opens Now.

### 6.14 Dark theme

- **Both themes on every screen,** following the system setting.
- **Colours come from the generated tokens,** which come from the `.stride-screen` tokens in `assets/css/app.css`. The same contrast rules apply as on the web ([`docs/dark-mode-contract.md`](../dark-mode-contract.md)): text at least 4.5:1, form-control borders at least 3:1.
- **Snapshot tests** cover each screen in both themes ([§19](#19-testing-strategy)).

### 6.15 Tablet review workspace

```text
┌────────────┬─────────────────────────┬──────────────────────────────────────────┐
│ Now      5 │ Review · 3 waiting      │ W2701 Review · holds up W2702, W2703, W2710│
│ Review   3 │ ● W2701  2m  holds up 3 │ Add seat count to org admin page          │
│ Boards     │   Acc Tst Pat✗ Sec      │ [Request changes  R]  [Approve  A]        │
│  Sales     │ ● W2705  40m  14 files  │ ┌ spec ────────────┐ ┌ diff ─────────────┐ │
│  Platform  │   Approve here, not on  │ │ summary          │ │ show.ex  1 of 6   │ │
│ Agents   4 │   a phone               │ │ criteria 4 of 4  │ │ 15 seat_count =   │ │
│            │ ○ W2699  2h   3 files   │ │ verdicts 3 of 4  │ │ 16   from(m in …) │ │
│ Settings   │                         │ │ checks, security │ │ ▸ reviewer note   │ │
│            │                         │ └──────────────────┘ └───────────────────┘ │
│            │                         │ J K next and previous · F next file        │
│            │                         │ A approve · R request changes              │
└────────────┴─────────────────────────┴──────────────────────────────────────────┘
```

- **The spec stays pinned beside the diff:** the summary, each acceptance criterion as a line, the verdicts, the checks and the security review. Each change can then be checked against what was asked.
- **The phone limit doesn't apply.** W2705 (14 files) can be approved here. Approve still asks for the biometric, and the device class on the approval is `tablet`.
- **Keyboard shortcuts** on both platforms, shown in the footer and in the iPad's ⌘ menu:
  - J and K for the next and previous task;
  - F for the next file;
  - A to approve;
  - R to request changes.
- **Portrait.** The sidebar folds away; in landscape all three columns show.

---

## 7. Backend changes

All of this lives in the Phoenix app and ships before the apps. Each item follows the existing patterns: contexts take `scope` first, there are no queries in controllers, and new telemetry is declared in the catalog.

### 7.1 Sign-in for a device

OAuth 2.0 for native apps (RFC 8252) with PKCE (RFC 7636). Stride is both the authorization server and the only client.

**Clients.** There are two fixed clients, `stride-ios` and `stride-android`, configured in code rather than in a table: Phase 1 has no third-party clients. Both use the redirect URI `com.stridelikeaboss.app:/oauth/callback`, a private-use scheme that both `ASWebAuthenticationSession` and AppAuth support.

**Authorize:** `GET /oauth/authorize`, in the `:browser` pipeline behind `:require_authenticated_user`.
- It runs in the system browser, so the person signs in exactly as on the web: password, SSO, two-factor, and the Organization's two-factor gate.
- It requires `code_challenge_method=S256`, a `state`, and `device_name` and `device_class` hints.
- **A confirmation page** says "Sign in to Stride on iPhone 15?" with **Allow** and **Cancel**. Without it, a link someone else sent could start a sign-in in a browser that's already signed in, and the code would go to an app that isn't the person's.
- **Allow** issues a one-time authorization code, valid for 60 seconds and stored hashed, and redirects to the app.

**Token:** `POST /oauth/token`, in a new `:oauth` API pipeline.

- **The `authorization_code` grant** takes the code, the `code_verifier`, the client id, and the device details: platform, model, OS version, app version, device class, locale, time zone and the approval public key ([§6.6](#66-approve-with-face-id-or-biometricprompt)). It:
  - creates the device;
  - returns an **access token** (opaque, 1 hour);
  - returns a **refresh token** (opaque, rotating, expiring after 30 days without use and 90 days after sign-in).
- **The `refresh_token` grant** rotates the refresh token. **Reusing an old refresh token revokes the device** and records `:device_refresh_reuse_detected` in the audit log, because that's the sign of a stolen token.
- **Refresh is refused** when the user is disabled, the device is revoked, or the user no longer meets the Organization's two-factor requirement. The app then returns to Sign in.

**Revoke:** `POST /oauth/revoke` revokes the device's tokens. Sign out of this device calls it.

**The person-API pipeline.** A new plug, `KanbanWeb.Plugs.AuthenticateDeviceToken`, reads `Authorization: Bearer`, looks the token up by its hash, and builds the same `Scope` the web uses (`Scope.for_user`). It also adds `current_device`. Every `/api/me/*` route then calls the same scope-first context functions as the LiveViews.

**Who sees devices, and where:**
- **People** see their devices on `/users/settings`: name, platform, app version, last seen, and **Revoke**.
- **Org-admins** see members' devices on the Organization members page, and can revoke one or all of a member's devices.
- Every sign-in and revoke writes an audit event ([§9.5](#95-audit-log)).

### 7.2 App version and minimum version

- **The version header.** Every request carries `X-Stride-App: ios/1.0.0 (42)` or `android/1.0.0 (42)`.
- **The minimum.** A plug compares the header with `config :kanban, :mobile_min_versions` (runtime config). Below the minimum it answers `426 Upgrade Required` with `{"error": "app_update_required", "store_url": ...}`, and the app shows a full-screen "Update Stride" with a store link.
- **The contract.** The `/api/me` API only adds fields; it never removes or renames one while a supported app version reads it. A breaking change gets a new path and a new minimum version.

### 7.3 `GET /api/me`

Returns:
- the user's display name and avatar initials;
- their Organizations and current workspace;
- the plan status (`app_unlocked`);
- the minimum app versions;
- the guard limits (`phone_max_files: 10`, `phone_max_lines: 500`);
- the device record.

The app calls it at launch and after every sign-in.

### 7.4 Decisions API

`GET /api/me/decisions` is built by a new `Kanban.Decisions` context (`build(scope)`). It's the one query behind Now, the badge, the widget and the inbox channel.

**Sources:**

| Kind | Source | Clears when |
|---|---|---|
| `review` | pending reviews the person can approve, using the same query and access check as `/review` (`reviews.ex:167-176`, `:361`) | the review is decided, or the task leaves Review |
| `released` | the person's unread or unresolved `task_unclaimed` notifications; the reason comes from the notification body | the task is claimed again, moved, or the card is acted on |
| `claim_expired` | the person's `claim_expired` notifications whose task is still unclaimed | the task is claimed, moved, or completed |
| `hook_failed` | goals on the person's boards whose last `after_goal` attempt failed (`task.ex:381-387`) | a later attempt succeeds |
| `ready_empty` | boards the person can write to with no Ready tasks, at least one Backlog task, and an agent that worked on the board in the last 24 hours and is idle now (`roster.ex:148-157`) | a task reaches Ready, or no agent is idle |

**Holds up:** the number of unfinished, unarchived tasks that depend, directly or through a chain, on the decision's task or goal. A goal counts as held up when its own `after_goal` failed.
- The count follows `dependencies` (`dependencies.ex:189-201`) to a depth of 5, capped at 50.
- It's computed in one query per board, using a recursive CTE over identifiers.
- `ready_empty` has no holds-up count. It carries the number of idle agents.

**Order:** by holds up, highest first, then by waiting time, oldest first. `ready_empty` cards come after every other card, because they invite a choice rather than unblock a specific task.

**Response, for each item:**
- `id`, a stable string such as `"review:task:4812"`;
- `kind`;
- `holds_up`, plus the identifiers of up to 5 of the held tasks;
- `since`;
- the task or goal summary: identifier, title, priority, agent and board;
- the kind's fields: verdict pills and the first failed note for a review, the reason for a release, the exit code for a hook;
- `actions`, the list of actions the server allows this person to take;
- `web_url`.

Plus a summary: `waiting`, `held_up` and `agents_working`.

**Size and cost.** At most 100 items. Pending reviews and notifications are already indexed by board and user; the `ready_empty` check is two counts per board.

### 7.5 Review API

**Reading:**

- **`GET /api/me/reviews`** is the review queue: the same items as the `review` decisions, in the same order.
- **`GET /api/me/reviews/:task_id`** returns everything §6.4 shows:
  - the summary;
  - the verdict sections, with each one's status and note;
  - the acceptance criteria;
  - the security considerations;
  - the exploratory count;
  - the behaviour matrix;
  - the file list: path, additions, deletions, `flagged`, the flag reason, and whether the diff was cut at the cap;
  - the size: files and changed lines;
  - `approvable_here` with a reason;
  - `review_requested_at`;
  - `holds_up`.
- **`GET /api/me/reviews/:task_id/files/:index`** returns one file's highlighted diff ([§7.6](#76-large-change-guard-and-highlighted-diffs)).

**Flagged files and inline notes.** A file is flagged when:
- a `reviewer_result` issue names its path, or
- the security section names it.

An issue with a line number is anchored to that line in the diff.

The issue entries' file and line fields must be checked against `review_contract.ex` when this is built. If the issue schema has no file field, add an optional `file` and `line` to it, and have the reviewer agent's prompt fill them. Without them, files are listed in diff order and the note shows only on the verdict tile.

**Acting:**

- **`POST /api/me/reviews/:task_id/approval_challenge`** returns a single-use nonce, valid for 2 minutes, bound to the device, the task and `review_requested_at`.
- **`POST /api/me/reviews/:task_id/approve`** takes `review_requested_at`, the nonce and the signature. The server checks, in order:
  1. the person can review the task: the existing `authorize_review_write`;
  2. the review is still pending, and its `review_requested_at` matches. Otherwise it answers 409 with `already_decided` or `resubmitted`, and the current state;
  3. the plan: `app_unlocked`;
  4. the large-change guard, for the device class ([§7.6](#76-large-change-guard-and-highlighted-diffs)). A phone above the limit gets `422 too_large_for_phone`;
  5. the signature, against the device's approval public key, with the nonce not yet used.

  Then it calls `Reviews.approve_review/3` unchanged and writes the audit event ([§9.5](#95-audit-log)).
- **`POST /api/me/reviews/:task_id/request_changes`** takes `review_requested_at` and `notes` (required). It runs the same checks 1–3, then calls `Reviews.request_changes_review/3` and writes the audit event.
- **Idempotency.** Both actions take an `Idempotency-Key` header. A retried request with the same key returns the first result instead of a 409, so a dropped response on a train doesn't look like a conflict.

### 7.6 Large-change guard and highlighted diffs

#### Large-change guard

A task is a **large change** when any of these holds:

- it changed more than **10 files**, counted from `changed_files`, or from `actual_files_changed` when `changed_files` is empty;
- it changed more than **500 lines**, counted as added plus deleted lines across all diffs;
- any diff was cut at the 500-line per-diff cap (`changed_files.ex:26`), because the true size is then unknown.

**Where the limit applies.**
- A device whose class is `phone` can't approve a large change.
- A tablet or the web can.
- Request changes is always allowed.

The device class is reported by the app at sign-in and stored on the device. An iPhone can't register as a tablet without a modified app, and a modified app would also have to pass App Attest or Play Integrity to matter: those checks are planned with the per-device limits in 1.1 ([§22](#22-risks)).

The limits are constants in Phase 1, `Kanban.Reviews.MobileGuard`, and are returned in `GET /api/me`. Org-set limits per device class are 1.1.

#### Highlighted diffs

A new module, `Kanban.Reviews.DiffHighlighter`, turns one file's unified diff into display lines.

- **Each line has:**
  - its kind: `add`, `del`, `ctx` or `hunk`;
  - the old and new line numbers;
  - `spans`, a list of `{class, text}` pairs.
- **The classes** are a small fixed set: `keyword`, `string`, `atom`, `comment`, `function`, `module`, `number`, `operator` and `plain`. Each app maps them to the generated token colours, so iOS, Android and later the web highlight code the same way.
- **The highlighter** is Makeup (`makeup` and `makeup_elixir`, plus the Erlang, HEEx and other lexers available on Hex).
  - These are **new dependencies**. Check each one's maintenance and run `mix deps.audit` and `mix hex.audit` when adding them.
  - The file extension picks the language. Unknown languages get `plain` spans with the add and delete colours only.
- **Lexing.** Diff lines are lexed one hunk at a time, with the `+` or `−` prefix stripped. A string or comment that starts outside a hunk may be coloured wrongly; that's acceptable for a review.
- **Caching.** Results are cached in ETS by task id, file index and a hash of the diff, with a one-hour expiry. A resubmitted task has a new diff hash.
- **Limit.** Responses are capped at the 500-line per-diff cap that already exists.

The web review could use the same highlighter later. That's a separate task, not part of Phase 1.

### 7.7 Live updates

**A new socket,** `KanbanWeb.UserSocket`, at `/api/socket`.

- **Connecting.** The app first calls `POST /api/me/socket_token` with its access token. That returns a single-use socket token valid for 60 seconds, which the app passes as the `token` connect parameter. `filter_parameters` keeps it out of the logs. The socket assigns the scope and the device.
- **Dropped devices.** When a device is revoked, the socket is disconnected through the device's own topic, `"device:<id>"`, which is broadcast on revoke.

**`me:inbox` channel:**
- **On join,** it subscribes the channel process to `Notifications.topic(user_id)` (`notifications.ex:128-130`) and to `"board:<id>"` for each board the person can see in the current workspace.
- **On any message,** it schedules a rebuild of `Kanban.Decisions.build/1`, coalesced to one per second. It then pushes `decisions` with the full list, or nothing when nothing changed.
- **Board access.** When `board_access_changed` arrives, it re-reads the person's boards and re-subscribes.

**`me:agents` channel:**
- It subscribes to `"agents:<id>"` (`broadcaster.ex:99`) for those boards.
- It pushes the roster and goal progress, coalesced the same way.

**Reconnecting.** After a reconnect, both channels send a full state on join, so the app never has to merge missed events.

### 7.8 Push delivery

**A third delivery channel** inside `Kanban.Notifications`, beside in-app and email.

- **Where it hooks in.** In `notify/3`, in the same transaction that inserts the rows and enqueues the emails (`notifications.ex:388-413`), a new `enqueue_pushes!` enqueues one `Kanban.Push.PushWorker` job per recipient. It does so only when:
  - the recipient has at least one active device with a push token, and
  - push is on for that event type.
- **The worker** runs on a new Oban queue, `:push` (5 attempts, backoff). It:
  1. re-checks the plan, as `EmailWorker` does (`email_worker.ex:127-133`);
  2. re-checks the person's push settings and quiet hours ([§7.9](#79-notification-settings-for-push));
  3. checks that the decision is still open. A review that was approved in the meantime isn't pushed;
  4. builds the payload in the device's locale ([§9.4](#94-what-a-notification-and-the-widget-may-show));
  5. sends it to each of the person's active devices.
- **The senders** go through Pigeon, a new dependency: APNs with token-based (`.p8`) authentication, and FCM HTTP v1 with a service account.
  - The Pigeon calls sit behind a behaviour, `Kanban.Push.Adapter`, so tests use a Mox double.
  - The credentials come from runtime config and secrets ([§15](#15-ci-signing-and-releases)).
- **Dead tokens.** An APNs `410 Unregistered` or an FCM `UNREGISTERED` clears that device's push token.
- **Collapsing.** iOS uses `apns-collapse-id`, and Android a tag, both set to the decision id, so a newer push about the same task replaces the older one.
- **The badge** is set to the decisions count on iOS.
- **The widget** is refreshed on each push: through the iOS Notification Service Extension, and on Android through `onMessageReceived` updating the Glance state.

### 7.9 Notification settings for push

- **Per event type:** a new `push` column on `notification_preferences`, beside `in_app` and `email` (`preference.ex:32-40`). `default_preference/1` gives:
  - `push: true` for `review_requested`, `task_unclaimed`, `claim_expired` and `after_goal_failed`;
  - `false` for everything else.
- **Per person:** a new table, `user_push_settings`, holds:
  - `mode`: `blocking` (the default) or `every`;
  - `quiet_hours_enabled`, `quiet_start` and `quiet_end`;
  - `time_zone`, taken from the device when it's set up.
- **The modes:**
  - **"Only when it blocks something"** pushes only the four blocking event types, and only when the item holds up at least one task or the event is a review.
  - **"Every event"** also pushes `task_reviewed`, `goal_completed`, `target_status_changed` and `mentioned`.
- **Quiet hours.** Pushes are held. When quiet hours end, the person gets **one** summary push if anything is still waiting, for example "3 things waited overnight", rather than a burst. A small Oban cron job (every 15 minutes) sends the summaries ([decision 5](#24-decisions-needed)).
- **The endpoints:** `GET/PUT /api/me/notification_settings`. The web preferences page `/users/notifications` (`router.ex:425`) gets a Push column and the quiet-hours setting, so the two never disagree.

### 7.10 Boards, tasks, agents and capture

All of these call existing context functions with the device's scope. Each one checks board access exactly as the web does.

| Endpoint | Calls | Notes |
|---|---|---|
| `GET /api/me/boards` | the board list for the current workspace | name, per-column counts, idle agents |
| `GET /api/me/boards/:id/columns/:name` | tasks in one column, by position | the card fields from §6.9; 100 per page |
| `POST /api/me/boards/:id/promote` | the existing move-to-column path, for several tasks in one transaction | sets `needs_review` when asked; refuses drafts; needs board write access |
| `GET /api/me/tasks/:id` | the task, read-only | title, description, acceptance criteria, key files, security considerations, last 20 comments |
| `POST /api/me/tasks/:id/comments` | the existing comment path | Reply on a released card |
| `POST /api/me/tasks/:id/move_to_backlog` | the existing move path | released and expired cards |
| `POST /api/me/tasks` | the existing task creation, into Backlog | `draft: true`, `created_via: "mobile"`, type `work` or `defect` only |
| `GET /api/me/agents` | `Kanban.Agents.Roster` and the goal trees (`goals.ex:83-104`) | the Agents screen |
| `GET /api/me/goals/:id/after_goal` | the goal's last attempt | exit code, duration, and the output only if the web goal page shows it ([decision 9](#24-decisions-needed)) |
| `GET /api/me/devices`, `DELETE /api/me/devices/:id` | `Kanban.Devices` | `DELETE .../current` signs out |
| `PUT /api/me/devices/current` | `Kanban.Devices` | updates the push token, locale, time zone and app version |

Drag-and-drop ordering, edits beyond `needs_review`, and goal promotion stay on the web.

### 7.11 The OpenAPI contract

- **Documented first.** Every route in §7.1–§7.10 goes into `priv/openapi/stride-api.json`, with its request and response schemas, before the apps are built against it.
- **A second security scheme.** Add `deviceAuth` (bearer) beside `bearerAuth`. Extend `open_api_contract_test.exs` so that each route's scheme matches its pipeline: `deviceAuth` for `/api/me/*`, `bearerAuth` for agent routes, none for `/oauth/token`.
- **Fixtures.** `mobile/shared/fixtures/*.json` holds example responses for previews, tests and screenshots. A new ExUnit test checks each fixture against its schema in the contract, so the fixtures can't drift from the API.

---

## 8. Database changes

New tables:

| Table | Columns | Notes |
|---|---|---|
| `user_devices` | `id`, `user_id`, `client_id`, `platform` (`ios`, `android`), `device_class` (`phone`, `tablet`), `name`, `model`, `os_version`, `app_version`, `locale`, `time_zone`, `push_token`, `push_environment` (`sandbox`, `production`), `approval_public_key`, `last_seen_at`, `revoked_at`, `revoked_by_id`, timestamps | index on `user_id`; unique on `push_token` where not null |
| `device_tokens` | `id`, `device_id`, `kind` (`access`, `refresh`), `token_hash`, `family_id`, `expires_at`, `used_at`, `inserted_at` | unique on `token_hash`; a refresh token family is revoked as a whole on reuse |
| `oauth_authorization_codes` | `id`, `user_id`, `client_id`, `code_hash`, `code_challenge`, `redirect_uri`, `device_name`, `expires_at`, `used_at`, `inserted_at` | purged daily |
| `approval_challenges` | `id`, `device_id`, `task_id`, `nonce_hash`, `review_requested_at`, `expires_at`, `used_at` | purged daily |
| `user_push_settings` | `user_id` (primary key), `mode`, `quiet_hours_enabled`, `quiet_start`, `quiet_end`, `time_zone`, `last_summary_at`, timestamps | one row per person, created on first change |

Changed tables:

| Table | Change |
|---|---|
| `notification_preferences` | add `push` boolean, default false; the defaults come from `default_preference/1` as today |
| `tasks` | add `draft` boolean, default false, and `created_via` string, nullable |

The token and code values are stored only as hashes, as `api_tokens` and `users_tokens` do today. Every table cascades on user delete.

Migrations need no backfill. Following the dev-database practice, run them as soon as they're written.

---

## 9. Security and privacy

### 9.1 Sign-in

- **The browser does the sign-in.** It goes through the system browser, never an embedded web view, so the app never sees a password. SSO, two-factor and the Organization's two-factor gate all apply unchanged.
- **The OAuth protections:**
  - PKCE `S256` is required;
  - codes are single-use and live 60 seconds;
  - `state` is checked;
  - the confirmation page names the device.
- **Token lifetimes.** Access tokens last an hour. Refresh tokens rotate, and reuse revokes the whole family and the device.
- **Rate limits.** Requests to `/oauth/token` and `/api/me/*` are limited per device and per IP, like the existing API.

### 9.2 Two kinds of token, never mixed

- **A device token** works only on `/oauth/revoke`, `/api/me/*` and `/api/socket`.
- **An agent's API token** is refused on those routes.
- **The agent routes** (claim, complete, `mark_reviewed`, `after_goal` and the rest) refuse device tokens.

That keeps the rule that a phone never becomes an agent, and the rule that an agent never records a human verdict (`task_param_filter.ex:158`).

### 9.3 On the device

| | iOS | Android |
|---|---|---|
| **Tokens** | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | encrypted with a key in the Android Keystore |
| **Approval key** | the Secure Enclave, `.biometryCurrentSet` with the passcode as fallback | the Keystore, `setUserAuthenticationRequired(true)` |

- **Re-enrolled biometrics.** On iOS, `.biometryCurrentSet` means a newly added face or fingerprint invalidates the key. The app then asks the person to sign in again.
- **The cache:**
  - iOS: Data Protection class `completeUntilFirstUserAuthentication`;
  - Android: app-private storage;
  - on both, it's wiped on sign-out, on a `device_revoked` answer, and when the person changes.
- **Hidden in the app switcher.** Review screens are covered by a blur on iOS and `FLAG_SECURE` on Android, so code doesn't show in the app switcher.
- **No third-party SDKs** for analytics, crash reporting or ads in Phase 1. Crash reports come from Xcode Organizer and Play Console vitals.

### 9.4 What a notification and the widget may show

- **Allowed:** the event kind, the identifier, the task or goal title, counts (holds up, verdicts passed and failed, files), and agent names.
- **Never:**
  - agent free text: summaries, reasons and notes;
  - review notes;
  - hook output;
  - code;
  - comment text.

  This matches the existing rule (`events.ex:11-16`). The released-task reason appears only inside the app, after sign-in.
- **Hiding titles.** An Organization security policy, a new `hide_titles_in_notifications` on `organization_security_policies` (`lib/kanban/organizations/security_policy.ex:37-41`), replaces the title with the kind alone: "W2701 is ready for review". The widget follows the same setting.

### 9.5 Audit log

New `Kanban.AuditLog.event/2` actions:

| Action | When | Metadata |
|---|---|---|
| `:review_approved` | any approval, **web or app** | `task_id`, `identifier`, `board_id`, `via` (`web`, `ios`, `android`), `device_id`, `device_class`, `app_version`, `approval_key` (boolean), `files`, `changed_lines` |
| `:review_changes_requested` | any change request, web or app | the same, without `approval_key` |
| `:device_signed_in` | a device is created | `device_id`, `platform`, `device_class`, `app_version` |
| `:device_revoked` | sign-out, revoke by the person, by an org-admin, or by reuse detection | `device_id`, `reason` |
| `:device_refresh_reuse_detected` | an old refresh token is reused | `device_id` |

Reviews write no audit event today (§3.2), so **web reviews start writing one too.** Then "approved from a phone" can be compared with "approved on the web". These rows follow the existing Organization scoping and redaction (`lib/kanban/audit_log/organization_scope.ex:1`), and appear on `/org/audit`.

### 9.6 Security review

Phase 1 adds an authorization server, a new token type, a socket and a push path. It gets a security review before the beta. It's also a good candidate for an exploratory-testing charter campaign on the token lifecycle and the review actions ([§19](#19-testing-strategy)).

---

## 10. Plans and access

**The apps are an Organization feature,** as notifications are today (`plans.ex:89-99`). Phase 1 adds a new plan feature, `:mobile_app`, next to `:notifications`.

- **Signing in.** Anyone can sign in. `GET /api/me` returns `app_unlocked: false` for a person who isn't in an Organization while enforcement is on. The app then shows the locked panel: what the app does, that it's part of the Organization plan, and a link to the pricing page.
- **The server checks every call.** Each `/api/me/*` route except `/api/me` and the device routes calls `Plans.check_user(scope, :mobile_app, ...)`. Board routes also call `check_board`, so a person in an Organization still can't use the app on a board outside it.
- **Push respects the plan too.** It's sent only for events the plan allows, because `notify/3` already drops events on free boards (`notifications.ex:444-449`).
- **Without enforcement.** With `:plans_enforced` off (dev and review), everything is unlocked, as for the other features.

Whether Free users get a read-only app is [decision 2](#24-decisions-needed).

---

## 11. Offline and caching

**Reading works offline; acting needs a connection.**

- **What's cached:**
  - the decisions list;
  - the review queue;
  - the last 20 reviews opened, with their highlighted diffs;
  - the boards' column counts and Backlog cards;
  - the agents list;
  - the device's settings.
- **Where it's kept:**
  - iOS: SwiftData, or GRDB if SwiftData's migration story proves weak in the spike;
  - Android: Room;
  - on both, keyed by the API's ids, with each response's fetch time.
- **Offline:**
  - a banner says when the data is from: "Offline · showing what you had at 14:02";
  - Approve, Request changes, Move to Ready, Reply and Save are disabled, with "Needs a connection";
  - nothing is queued.
- **Back online:**
  - the app refetches the open screen and rejoins its channels;
  - a review that changed while offline shows the 409 states from §6.4.

Decisions made offline and sent later are 1.2 ([§21](#21-not-in-phase-1)). They need their own design for stale decisions.

---

## 12. The iOS and iPadOS app

| Area | Choice |
|---|---|
| Minimum version | iOS and iPadOS 17 |
| Language and UI | Swift 6 and SwiftUI; `@Observable` view models; no business logic in views |
| Layout | `TabView` on iPhone; `NavigationSplitView` on iPad, switching on horizontal size class |
| Project | XcodeGen (or Tuist) `project.yml`; the `.xcodeproj` is generated and not committed |
| Modules | `Stride` (app target), `StrideKit` (Swift package), `StrideWidgets` (WidgetKit extension), `StrideNotificationService` (Notification Service Extension) |
| API | client generated by swift-openapi-generator from `priv/openapi/stride-api.json`, on `URLSession` with async/await |
| Sign-in | `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession = false`, so an existing web sign-in is reused |
| Tokens | Keychain, shared with the extensions through an app group keychain access group |
| Approval key | `SecKeyCreateRandomKey` in the Secure Enclave with `SecAccessControl` `.biometryCurrentSet` or `.devicePasscode`; signing through `LAContext` |
| Live updates | SwiftPhoenixClient, one socket, `me:inbox` and `me:agents` |
| Cache | SwiftData (or GRDB) in the app group container, so the widget can read the count |
| Push | APNs; one `UNNotificationCategory` per event type with an Open action; the service extension updates the badge and the widget |
| Widget | WidgetKit, small and medium; timeline refresh every 30 minutes and on push |
| Keyboard | `.keyboardShortcut` for J, K, F, A and R, with a ⌘ menu |
| Strings | an Xcode string catalog generated from gettext ([§14](#14-repository-structure)) |
| Colours and type | asset-catalog colours (light and dark) and type styles generated from the tokens; Geist and Geist Mono bundled |
| Accessibility | Dynamic Type up to the accessibility sizes, VoiceOver labels on every control, 44-point targets, `accessibilityAudit` in UI tests |

**StrideKit owns everything shared by the app and its extensions:**
- the generated client and an `APIClient` wrapper that adds the version header, refresh and retry;
- `AuthStore`, the Keychain;
- `ApprovalSigner`;
- `Cache`;
- `LiveChannel`;
- `PushRegistration`.

The view models depend on protocols, so previews and tests run against the shared fixtures.

---

## 13. The Android app

| Area | Choice |
|---|---|
| Minimum version | Android 9 (API 28), targeting the current API level |
| Language and UI | Kotlin and Jetpack Compose with Material 3; view models with `StateFlow`; Hilt for injection |
| Layout | `NavigationSuiteScaffold` (bottom bar on phones, rail on tablets and foldables) and `ListDetailPaneScaffold` for Review |
| Modules | `app`; `core:network` (generated client), `core:auth`, `core:data` (Room), `core:designsystem`, `core:push`; `feature:now`, `feature:review`, `feature:boards`, `feature:agents`, `feature:capture`, `feature:settings`; `widget` |
| API | Kotlin client generated by openapi-generator from the same contract, on OkHttp with kotlinx.serialization |
| Sign-in | AppAuth for Android with Custom Tabs and PKCE |
| Tokens | encrypted with an AES key in the Android Keystore, stored with DataStore |
| Approval key | an EC P-256 key in the Keystore with `setUserAuthenticationRequired(true)` and `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`; signed through `BiometricPrompt.CryptoObject` |
| Live updates | JavaPhoenixClient, or a small OkHttp WebSocket client speaking the Phoenix protocol |
| Cache | Room |
| Push | FCM; one notification channel per event type, created at first launch; the `POST_NOTIFICATIONS` permission asked on Android 13 and later from §6.2 |
| Widget | Glance, small and medium; updated from the cache and on push |
| Keyboard | `onKeyEvent` handlers for J, K, F, A and R on tablets and with a hardware keyboard |
| Strings | `strings.xml` for each locale, generated from gettext |
| Colours and type | a Compose colour scheme and typography generated from the tokens; no dynamic colour |
| Accessibility | TalkBack content descriptions, font scaling to 200%, 48 dp targets, Accessibility Test Framework checks in UI tests |

---

## 14. Repository structure

Both apps live in this repository, so one task can change the API and both apps together. **The Phoenix app stays at the root.** Moving it would break the Dockerfiles, the Fly configs, CI, the `.stride.md` hooks and the compile-time reads from `priv/`.

```text
kanban/
├── lib/ test/ assets/ config/ priv/     the web app and API
│   ├── priv/openapi/stride-api.json     the contract both apps generate from
│   └── lib/mix/tasks/mobile.*.ex        mobile.tokens, mobile.strings, mobile.api
├── mobile/
│   ├── CLAUDE.md                        rules for work across both apps
│   ├── shared/
│   │   ├── tokens.json                  generated from assets/css/app.css
│   │   ├── strings/                     generated from priv/gettext, seven locales
│   │   └── fixtures/                    example API responses, checked against the contract
│   ├── ios/
│   │   ├── CLAUDE.md  project.yml
│   │   ├── Stride/ (App/, Features/, DesignSystem/)
│   │   ├── StrideKit/  StrideWidgets/  StrideNotificationService/
│   │   ├── StrideTests/  StrideUITests/
│   │   └── fastlane/
│   └── android/
│       ├── CLAUDE.md  settings.gradle.kts  gradle/libs.versions.toml
│       ├── app/  core/  feature/  widget/
└── .github/workflows/  elixir.yml  ios.yml  android.yml
```

**Shared sources of truth.** The web app stays the source. Generators make the app copies, and a test fails when a copy is out of date, the same pattern as `test/kanban/telemetry_docs_test.exs`.

| Source | Generator | Copies | Check |
|---|---|---|---|
| `assets/css/app.css` (the `.stride-screen` tokens) | `mix mobile.tokens` | `mobile/shared/tokens.json`, iOS colour assets, the Compose colour and type file | an ExUnit test regenerates in memory and compares |
| `priv/gettext/*/LC_MESSAGES/mobile.po` (a new `mobile` domain) | `mix mobile.strings` | the Xcode string catalog, Android `strings.xml` for each locale | a test fails when a string is missing in any locale, or a copy is stale |
| `priv/openapi/stride-api.json` | `mix mobile.api` | the Swift and Kotlin clients | the fixture test (§7.11); both app CI jobs run when the contract changes |

**The app strings in gettext.** They go in their own gettext domain, `mobile`, so `mix gettext.extract --merge` keeps them with the web's. They're translated in the same pass as web strings. Placeholders use gettext's `%{name}` form, and the generator converts them to each platform's format.

**Other repository changes:**
- **CI:** `paths-ignore: ['mobile/**']` on `elixir.yml` pushes and pull requests, so app-only changes don't run the Elixir suite or redeploy.
- **Docker:** `/mobile/` in `.dockerignore`.
- **`.gitignore`:**
  - anchor `/package.json`, `/package-lock.json` and `/node_modules` (`:64-66`);
  - add the Xcode and Gradle build folders, `*.xcodeproj` under `mobile/ios`, `local.properties`, and keystores.
- **Agent instructions:** `mobile/CLAUDE.md`, `mobile/ios/CLAUDE.md` and `mobile/android/CLAUDE.md` carry each platform's rules, the way `AGENTS.md` does for the web:
  - both themes;
  - all seven locales;
  - accessibility labels;
  - no business logic in views;
  - regenerate after changing the contract, tokens or strings.
- **Stride hooks:** `after_doing` keeps its 120-second limit. It adds only fast checks for `mobile/` files a task touched (swift-format lint, ktlint and the generator checks). Full builds and UI tests run in `ios.yml` and `android.yml`.

---

## 15. CI, signing and releases

### 15.1 CI

| Workflow | Runner | Runs on changes to | Jobs |
|---|---|---|---|
| `elixir.yml` | Linux | everything except `mobile/**` | the existing suite, plus the new contract, fixture and generator tests |
| `ios.yml` | macOS | `mobile/ios/**`, `mobile/shared/**`, `priv/openapi/**` | generate the project, build, Swift Testing, snapshot tests, XCUITest on one iPhone and one iPad simulator |
| `android.yml` | Linux | `mobile/android/**`, `mobile/shared/**`, `priv/openapi/**` | Gradle build, ktlint, unit tests, screenshot tests, instrumented UI tests on an emulator |

**Pinned toolchains.** Each app job pins its toolchain: the Xcode version, the JDK, and the Android Gradle Plugin through the version catalog.

### 15.2 Signing and secrets

- **Where secrets live:** in the GitHub Actions secrets, never in the repository.
  - iOS: an App Store Connect API key, with fastlane `match` or Xcode Cloud managed signing.
  - Android: the upload keystore, with Play App Signing holding the release key.
- **Server-side push credentials:** the APNs `.p8` key and the FCM service account are Fly secrets, read in `config/runtime.exs`.
- **Separate push sandboxes.** The review app (`kanban-review`) uses the APNs sandbox and a separate Firebase project, so test pushes never reach production devices.

### 15.3 Releases

| Platform | Beta | Production | Notes |
|---|---|---|---|
| iOS and iPadOS | TestFlight; internal testers first, then external testers, which needs Apple's beta review | App Store | privacy manifest (`PrivacyInfo.xcprivacy`); App Privacy answers: account data and identifiers only, no tracking; `ITSAppUsesNonExemptEncryption` false (HTTPS only) |
| Android | Play Console internal testing, then closed testing | production, with a staged rollout | Data safety form; register Stride's developer account as an **organization**, which avoids the 12-tester, 14-day closed-test rule for new personal accounts |

**Store rules to remember:**
- The app creates no accounts (sign-up stays on the web), so it needs no in-app account deletion.
- The web offers email and password plus company SSO (OIDC and SAML). Company SSO doesn't trigger Apple's Sign in with Apple rule. If a consumer social login is added to the web later, revisit this.
- An old app version stays in use for months. The API rules in §7.2 apply, and the minimum version is raised only for security fixes.

---

## 16. Telemetry

New events, named by the rule in [`docs/telemetry.md`](../telemetry.md) and declared in `Kanban.Telemetry.Catalog` with their `metrics` and `persist` fields. Metadata carries only ids, fixed labels and counts.

| Event | Measurements | Metadata | Why |
|---|---|---|---|
| `[:kanban, :device, :signed_in]` | `count` | `platform`, `device_class` | adoption |
| `[:kanban, :device, :revoked]` | `count` | `platform`, `reason` | sign-outs, revokes and reuse detection |
| `[:kanban, :push, :sent]` | `count` | `platform`, `event_type` | push volume by event |
| `[:kanban, :push, :failed]` | `count` | `platform`, `event_type`, `reason` | APNs and FCM errors, dead tokens |
| `[:kanban, :push, :held]` | `count` | `event_type`, `reason` (`quiet_hours`, `mode`, `resolved`) | how often pushes are held back |
| `[:kanban, :review, :approved]` | `count`, `files`, `changed_lines` | `via`, `device_class`, `board_id` | phone versus web approvals ([§23](#23-how-to-judge-it)) |
| `[:kanban, :review, :changes_requested]` | `count` | `via`, `device_class`, `board_id` | the same for change requests |
| `[:kanban, :review, :phone_approval_refused]` | `count`, `files`, `changed_lines` | `board_id` | how often the guard stops a phone |
| `[:kanban, :decisions, :built]` | `duration`, `count` | `source` (`api`, `channel`) | the cost of Now |
| `[:kanban, :api, :outdated_app_refused]` | `count` | `platform` | who is stuck below the minimum |

- **Request telemetry.** The `/api/me/*` routes are covered by the existing API request telemetry through `ApiTelemetry` in the new pipeline.
- **The docs.** After changing the catalog, refresh the event reference in `docs/telemetry.md`; `test/kanban/telemetry_docs_test.exs` fails until it matches.

---

## 17. Translations, accessibility and dark mode

- **Every visible string** in both apps, every server-built push text, and every new web string (the device list, the confirmation page and the push settings) is in gettext. Each is translated into de, en, es, fr, ja, pt and zh in the same task. Run `mix gettext.extract --merge` and check for new fuzzy entries.
- **Push text** is built on the server in the device's locale, so a notification arrives in the language the phone uses even when the web account is set to another.
- **Layouts survive longer translations.** German and Portuguese labels run long, so the screens are checked at the largest text size in German.
- **Dark mode on the new web pages** follows [`docs/dark-mode-contract.md`](../dark-mode-contract.md), with `mix dark_mode.scan` as part of precommit.
- **Accessibility:**
  - every control has a label;
  - verdict pills say their state in words ("Patterns failed"), not by colour only;
  - the diff reads line by line with "added" or "removed";
  - nothing depends on swipes alone.

---

## 18. Docs

- **A user guide,** `docs/mobile-apps.md`: what the apps do, signing in, notifications and quiet hours, reviewing on a phone and the size limit, devices and revoking them, and the Organization plan.
- **API reference:** `docs/api/` pages for the `/api/me` endpoints and the OAuth flow, linked from `docs/api/README.md`. They say the endpoints are for the Stride apps, not for agents.
- **Telemetry:** `docs/telemetry.md`, as in §16.
- **The developer README:** a mobile section with the Mac, Xcode, JDK and Android SDK setup, and how to run each app against a local server.
- **The release notes:** CHANGELOG entries for the backend changes as they ship, and for each app release.
- **The roadmap:** ROADMAP moves *Native mobile apps* from Planned to In progress when Phase 1 starts.
- **The docs index:** every new doc under `docs/` gets an entry in `docs/README.md`. Links follow [`docs/doc-link-contract.md`](../doc-link-contract.md).

---

## 19. Testing strategy

### 19.1 Backend (ExUnit)

- **OAuth:**
  - PKCE mismatch;
  - a reused code;
  - an expired code;
  - a wrong redirect URI;
  - refresh rotation;
  - reuse detection revoking the family and the device;
  - a disabled user;
  - a revoked device;
  - an Organization requiring two-factor for a person without it;
  - an agent token refused on `/api/me/*`, and a device token refused on agent routes.
- **Decisions:**
  - each kind appears and clears under its rule;
  - holds-up counts with chains, cycles, archived tasks, the depth limit and the cap;
  - the order;
  - boards the person can't see never show;
  - the free-board plan check.
- **The review API:**
  - approve and request changes through the existing `Reviews` functions;
  - 409 for already decided and for resubmitted;
  - idempotent retries;
  - the guard at 10 and 11 files, 500 and 501 lines, and a capped diff;
  - a tablet approving a large change;
  - a missing, wrong, reused or expired signature;
  - audit rows for web and app.
- **The diff highlighter:** Elixir, HEEx and an unknown language; a hunk starting inside a string; caching by diff hash.
- **Channels:** `Phoenix.ChannelTest` for join, the coalesced rebuild, re-subscribing after `board_access_changed`, and the disconnect on revoke.
- **Push:**
  - the worker against a Mox `Kanban.Push.Adapter`;
  - modes and quiet hours across time zones and daylight-saving changes;
  - the morning summary;
  - dead-token cleanup;
  - holding a push for an already-resolved decision;
  - a payload test that fails if a title field ever carries a summary, a reason or notes.
- **The contract:** the extended OpenAPI contract test, plus the fixture schema test.
- **The generators:** the tokens and strings staleness tests, and a missing translation in one locale.
- **Telemetry:** each new event through `Kanban.TelemetryHelpers.attach_telemetry/2`.

### 19.2 iOS

- **Unit tests:** Swift Testing for view models and StrideKit, against the shared fixtures: refresh on 401, the 426 update screen, offline states, and the 409 states.
- **Snapshot tests:** each screen in light and dark, at the default and the largest accessibility text size, on an iPhone and an iPad.
- **UI tests:** XCUITest for sign-in (against a stub authorization page), approve (with a simulated Face ID match and no-match), request changes, the large-change guard, and promote to Ready. `performAccessibilityAudit()` runs on each screen.

### 19.3 Android

- **Unit tests:** JUnit and Turbine for view models and `core`, against the shared fixtures.
- **Screenshot tests:** Roborazzi (or Paparazzi) in light and dark, at 100% and 200% font scale, on a phone and a tablet.
- **UI tests:** Compose UI tests for the same flows as iOS, with `BiometricPrompt` faked behind an interface. Accessibility Test Framework checks run on each screen.

### 19.4 Exploratory and beta

- **Exploratory charters** before the beta: the token lifecycle (sign-in, refresh, revoke, two devices), approving at the guard boundaries, Now under rapid change (two reviewers on one task), push during quiet hours across a time-zone change, and offline-then-online on the review screen.
- **The beta:** with the first Organizations, through TestFlight and a Play closed test, before the stores.

---

## 20. Phased delivery

**The order:** Phase 1 ships in three parts, each its own goal. The backend comes first and is useful on its own. iOS follows, then Android with the same scope.

### Phase 1a — Backend

0. **Fix the Review wait metric** to measure `review_requested_at → reviewed_at`, and start collecting a baseline ([§3.6](#36-metrics-review-wait-reads-as-zero-today)). This is a defect on its own; do it now, whatever happens to the apps.
1. `Kanban.Devices`: the tables, OAuth authorize (with the confirmation page), token and revoke, `AuthenticateDeviceToken`, the version plug, and `GET /api/me`.
2. Devices on `/users/settings` and on the Organization members page, with revoke and the device audit events.
3. The review API: detail, approve, request changes, the 409 rules, idempotency, the approval challenge and signature, `MobileGuard`, and the review audit events for web and app.
4. `Kanban.Reviews.DiffHighlighter` (Makeup) and the file endpoint.
5. `Kanban.Decisions` with holds-up ranking, and `GET /api/me/decisions` and `/reviews`.
6. Boards, column reads, promote with `needs_review`, task detail, comment, move to Backlog, capture with `draft` and `created_via`, and the agents endpoint.
7. `UserSocket` with the `me:inbox` and `me:agents` channels.
8. Push: Pigeon, `Kanban.Push`, `PushWorker`, the `push` preference column, `user_push_settings`, quiet hours with the summary job, the web preferences page, and the lock-screen policy.
9. The OpenAPI additions, `deviceAuth` in the contract test, and the fixtures with their schema test.
10. Telemetry events and `docs/telemetry.md`.
11. The monorepo groundwork:
    - the `mobile/` skeleton with its `CLAUDE.md` files;
    - `mix mobile.tokens`, `mix mobile.strings` and `mix mobile.api` with staleness tests;
    - the `mobile` gettext domain;
    - CI `paths-ignore` and the `ios.yml` and `android.yml` workflows;
    - `.dockerignore` and `.gitignore`.
12. Docs: the API reference, `docs/mobile-apps.md` (marked as coming), and the CHANGELOG.

### Phase 1b — iOS and iPadOS 1.0

1. The project from `project.yml`, StrideKit with the generated client, `AuthStore`, `APIClient` with refresh and the version header, and sign-in (§6.1).
2. The design system from the generated tokens and strings, and shared views (pills, cards, avatars and the diff line).
3. Now with the live channel, the cache and its states (§6.3).
4. Review, the flagged file, the approval key and approve, request changes, and the large-change guard (§6.4–§6.8).
5. Boards and promote (§6.9), Agents (§6.10), New task (§6.11).
6. Push registration, notification categories, the service extension, and the onboarding prompt (§6.2, §6.13).
7. Settings (§6.12) and the widget (§6.13).
8. The iPad split layout, the review workspace and keyboard shortcuts (§6.15).
9. The accessibility and localisation pass, snapshot tests in both themes, and UI tests.
10. TestFlight beta with the first Organizations, then App Store review and release.

### Phase 1c — Android 1.0

The same ten steps on Android: Gradle modules, the generated Kotlin client, AppAuth, the design system, then Now, Review, Boards, Agents, New task, push channels, Settings, the Glance widget, the tablet layout, the quality pass, then a Play internal test, a closed test and production.

**What the backend doesn't change for Android.** Android adds only FCM credentials and Play-specific store work. If a screen needs a server change during Phase 1c, it's made contract-first, and both apps are updated in the same task.

**Turning this into Stride work.** Each phase becomes a Stride goal with one task per numbered item, split further where an item is larger than about three hours. Each Phase 1b and 1c task names the design screen it builds.

---

## 21. Not in Phase 1

| Feature | When | Why it waits |
|---|---|---|
| Goal progress outside the app: Live Activity on iOS, a progress notification on Android | 1.1 | needs the server's push-to-update path |
| Bug capture with a screenshot or photo and markup | 1.1 | needs JSON upload on the attachment pipeline (`lib/kanban/attachments/pipeline.ex:78`); today the API can only download (`router.ex:243`) |
| Request changes from the notification's text field | 1.1 | 1.0 keeps every decision on the review screen |
| Org-set approval limits for each device class, with App Attest and Play Integrity | 1.1 | 1.0 has one fixed limit |
| Decisions made offline and sent later | 1.2 | needs a stale-decision design |
| More widgets (target status, weekly throughput), the share sheet | 1.2 | |
| Siri and Shortcuts, App Actions | 1.2 | |
| Notes on a line of the diff, pen notes, drag and drop between columns, several windows | Stage 3 | tablet work beyond the review workspace |
| Planning mode, mission control, showing on a TV | Stage 3 | |
| The watch | later | |
| Syntax highlighting in the web review | separate task | can reuse the highlighter from §7.6 |

---

## 22. Risks

- **Approving without looking.** This is the main risk. The mitigations:
  - verdicts first;
  - the server-enforced size limit;
  - a biometric-protected approval key;
  - an audit entry naming the device;
  - the measure in §23 that compares later change requests on phone and web approvals.
- **The guard trusts the app's device class.** A modified app could claim to be a tablet. In 1.0 the approval key still proves which device approved, and the audit log records it. 1.1 adds App Attest and Play Integrity before Organizations can set their own limits.
- **Too many notifications.** If every event pushes, people mute the app within a week. The mitigations:
  - "Only when it blocks something" is the default;
  - pushes are collapsed per decision;
  - quiet hours end with a single summary;
  - resolved decisions aren't pushed.
- **Two clients to maintain.** Every API change, string and policy now has two more consumers. Contract-first changes, generated clients, generated tokens and strings, and the staleness tests keep that cost down.
- **Old app versions.** A store release can't be rolled back like a deploy. The API stays additive, and the minimum version is a last resort.
- **App store review** slows fixes compared with the web. Keep logic on the server where it's cheap, such as the guard, the ranking and the push text.
- **Competing with sales time.** Phase 1a task 0 is worth doing now. The rest should start when the baseline shows real waits ([decision 12](#24-decisions-needed)).

---

## 23. How to judge it

**Before:** four weeks of baseline from the fixed metric (task 0), on the boards of the beta Organizations.

**After,** comparing boards whose reviewers use the app with the baseline and with boards whose reviewers don't:

- the median and 90th-percentile Review wait, `review_requested_at → reviewed_at`;
- time from `claim_expired`, `task_unclaimed` or `after_goal_failed` to the first action on that task;
- time Ready sits empty while an agent is idle;
- the share of approvals made on a phone, and how often changes are later requested, or a defect is filed, against tasks approved on a phone compared with on the web. If phone approvals do worse, the guard needs tightening;
- how often the guard refuses a phone approval, and how often that review is then finished on a tablet or the web within the hour;
- push opt-in, and how many people turn push off within two weeks;
- Organizations that name the app as a reason to buy.

---

## 24. Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| 1 | Build an installable web app with web push first, as the analysis suggested, or go straight to native? | Go straight to native, but ship Phase 1a first and collect the baseline. If waits are already short, stop after 1a. |
| 2 | Organization only, or a read-only app for Free users to discover the plan? | Organization only in Phase 1, matching notifications. Free users can sign in and see the locked panel. |
| 3 | How long after iOS 1.0 should Android 1.0 ship? | Start Phase 1c when the iOS beta is with the first Organizations. The backend is shared, so the gap is mostly app work. |
| 4 | A server-verified approval key, or a biometric check in the app only? | The approval key. It's a small amount of work and makes "approved with a biometric on this device" something the audit log can prove. |
| 5 | Quiet hours: drop held pushes, or send one summary when they end? | One summary. Silence overnight shouldn't mean the morning starts with no signal. |
| 6 | Captured tasks: add a `draft` flag, and refuse to promote drafts from the phone? | Yes. On the web, promoting a draft clears the flag after a confirmation. |
| 7 | Who sees a review on Now: everyone who can review the board, or an assigned reviewer? | Everyone who can review, as `/review` works today. Assigned reviewers are a separate feature. |
| 8 | Include the Organization setting that hides titles in notifications in 1.0? | Yes. It's small, and security buyers will ask. |
| 9 | Show a failed `after_goal` hook's output on the phone? | Show the exit code and duration, plus the output only if the web goal page already shows it, with the same redaction. Never in a push. |
| 10 | Request changes leaves the task in Review today (§3.2). Should the phone copy say "back in Doing", or match what happens? | Match what happens. Changing where the task goes is a separate workflow decision. |
| 11 | Which languages does the diff highlighter cover at launch? | Elixir, HEEx, Erlang, JavaScript and CSS, whichever Makeup lexers are maintained; plain text otherwise. |
| 12 | Start the backend now, or after the five-Organization sales goal? | Task 0 now. The rest of Phase 1a when the baseline shows real waits on paying boards. |
