# Import from Jira — Implementation Design

**Roadmap item:** *Import from Jira*, under *Planned* ([ROADMAP](../../ROADMAP.md)). This design covers **Jira only**; Linear is out of scope.
**Status:** Proposed design, not yet decomposed into tasks. Decisions 1–18 in [§24](#24-decisions-needed) were settled on 2026-10-30, and decisions 19–23 on 2026-11-10
**Date:** 2026-10-28, revised 2026-10-30 to make the epic rewrite part of the core import, and again on 2026-10-30 to move the agent side into a new plugin, `stride-import`, with a variant for every agent runtime; revised again on 2026-11-10 to apply the exploratory review (`.exploratory/jira-import-design/SUMMARY.md`) and record decisions 19–23

This document describes how a team brings its existing work from Jira into
Stride: how Stride connects to Jira, how the team chooses what to bring
across, how every field is mapped, how the team maps extra fields of its own,
what happens to data Stride has no place for, and how work that is already in
progress survives the move. It ends with the architecture, the database
changes, the screens, the security rules, the tests and a phased delivery
plan.

**Import is an Organization plan feature**, and so is the rewrite. When paid
plans are enforced, only a workspace that belongs to an Organization can start
an import. In an Organization workspace only the Organization's enabled
org-admins run imports; members ask an org-admin ([§19](#19-permissions-and-plans)).

Every epic comes across one of two ways, chosen epic by epic. A **direct
import** copies the issues into Stride tasks field by field. A **rewrite**
hands the epic's not-started issues to an agent, which writes new Stride tasks
that cover everything in them. A coverage check shows that every issue and
every requirement in it is cited by a task and flags thin citations, and a
person ticks each issue as reviewed before signing the result off. The check
proves citation, not delivery; the person signing is the one who judges
delivery. Jira issues are often thin, out of date
or written for people who already know the context, so Stride recommends the
rewrite for all work that has not started. Work that has started, and work
that is done, is always imported directly. [§6A](#6a-rewrite-or-import-epic-by-epic)
describes the choice and the rewrite.

The agent side of the rewrite is a new plugin, **`stride-import`**, separate
from the Stride workflow plugin. It ships in a variant for every agent runtime
Stride supports: Claude Code, Codex CLI, GitHub Copilot CLI, Gemini CLI,
OpenCode and Pi. [§16A](#16a-the-agent-side-plugin-stride-import) describes it.

It is a one-way import. Keeping Stride and Jira in step afterwards is a
different feature, covered by the earlier *Jira as a Backend for Stride* plan.
The import is built around a source adapter, so the later *Import from Trello
and CSV* roadmap item, or Linear if it is ever wanted, adds an adapter and
nothing else.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Terms used in this document](#2-terms-used-in-this-document)
3. [What already exists that the import builds on](#3-what-already-exists-that-the-import-builds-on)
4. [The import at a glance](#4-the-import-at-a-glance)
5. [Connecting to Jira](#5-connecting-to-jira)
6. [Choosing what to import](#6-choosing-what-to-import)
   - [6A. Rewrite or import, epic by epic](#6a-rewrite-or-import-epic-by-epic)
7. [Where imported work lands](#7-where-imported-work-lands)
8. [The common item model](#8-the-common-item-model)
9. [Standard field mapping](#9-standard-field-mapping)
10. [Value mappings](#10-value-mappings)
11. [Mapping additional fields](#11-mapping-additional-fields)
12. [Data that does not map](#12-data-that-does-not-map)
13. [Work already in progress](#13-work-already-in-progress)
14. [Text, comments, attachments, history and dates](#14-text-comments-attachments-history-and-dates)
15. [People and board membership](#15-people-and-board-membership)
16. [Architecture](#16-architecture)
   - [16A. The agent-side plugin: stride-import](#16a-the-agent-side-plugin-stride-import)
17. [Database changes](#17-database-changes)
18. [Screens](#18-screens)
19. [Permissions and plans](#19-permissions-and-plans)
20. [Security and privacy](#20-security-and-privacy)
21. [Telemetry, audit log and the import report](#21-telemetry-audit-log-and-the-import-report)
22. [Testing strategy](#22-testing-strategy)
23. [Phased delivery](#23-phased-delivery)
24. [Decisions needed](#24-decisions-needed)
25. [Appendix A: Jira API reference](#appendix-a-jira-api-reference)
26. [Appendix B: rich text conversion rules](#appendix-b-rich-text-conversion-rules)

---

## 1. Goals and non-goals

### Goals

- A team can move a Jira project or board into Stride without losing titles,
  descriptions, comments, attachments, labels, status, assignees, hierarchy or
  blocking links.
- The person importing sees **exactly** what will happen before anything is
  written: counts, a sample of tasks as Stride will show them, every field that
  will not come across, and every person who could not be matched.
- Standard fields map automatically with sensible defaults; the importer can
  override every default and can map the team's own custom fields onto Stride
  fields.
- Nothing from Jira is silently thrown away. Data Stride has no field for is
  kept with the task and can be read and downloaded.
- Work that has not started arrives as tasks an agent can work from. The
  importer can have an agent rewrite each epic's not-started issues into new,
  fully specified Stride tasks, and Stride recommends it. A coverage check
  shows that every issue and every requirement in it is cited by a task, and
  a person reviews each issue and signs the result off before anything is
  written ([§6A](#6a-rewrite-or-import-epic-by-epic)).
- Work already in progress keeps its place, its owner and its review state,
  and never becomes claimable by an agent by accident.
- A team that keeps working in Jira during the move can bring the changes
  across again before it switches over.
- An import can be undone.

### Non-goals (for this roadmap item)

- **Linear.** Not part of this design.
- **Two-way sync.** Stride does not push changes back to Jira, apart from the
  optional "moved to Stride" marker in [§13.6](#136-cutover-and-the-optional-moved-to-stride-marker).
- **Trello and CSV.** A separate roadmap item; the adapter interface in
  [§16.2](#162-the-source-adapter-behaviour) is designed for them.
- **Jira Data Center in the first release.** It is planned for Phase 4
  ([§23](#23-phased-delivery)), because its API version, text format and
  network location all differ from Jira Cloud.
- **File types Stride does not store.** The import copies Jira attachments into
  Stride's own attachments, which shipped in Stride 3.1.0 ([Task Attachments](ATTACHMENTS-DESIGN.md)).
  A file Stride cannot store (a type outside its allow-list, over its size
  limit) stays a link to Jira; see [§14.3](#143-attachments).
- **Creating Stride accounts.** People are matched to existing accounts or
  invited; the import never creates a user.
- **Running a model on Stride's servers.** The rewrite runs in the team's own
  agent, against its own checked-out repository ([§6A.5](#6a5-how-a-rewrite-runs)).
  Stride prepares the input, checks the output and writes the tasks.

---

## 2. Terms used in this document

| Term | Meaning |
|---|---|
| **Source** | The system being imported from: `jira_cloud` (later `jira_dc`; the adapter design leaves room for `trello` and `csv`) |
| **Connection** | Stored credentials for one Jira site, such as one `*.atlassian.net` site |
| **Container** | Something in Jira that holds work and can be chosen as a unit: a Jira project or a Jira board |
| **Item** | One Jira issue, including epics and sub-tasks |
| **Run** | One import, from choosing the site to the final report. A run can be re-synced while it is open |
| **Mapping** | The full set of rules that turn Jira issues into Stride tasks: statuses, issue types, priorities, people, labels and custom fields |
| **Destination board** | The Stride board an item is written to |
| **Import link** | The permanent record joining a Stride task to the Jira issue it came from |
| **Direct import** | Copying issues into Stride tasks field by field, through the mapping ([§9](#9-standard-field-mapping) to [§11](#11-mapping-additional-fields)) |
| **Rewrite** | Having an agent write new Stride tasks that cover a set of not-started issues ([§6A](#6a-rewrite-or-import-epic-by-epic)) |
| **Epic bundle** | The JSON document a rewrite is written from: the epic and the issues being rewritten, as normalised items |
| **Draft** | The tasks an agent proposes for one epic, with its coverage map. Stored on the run, not on the board, until it is signed off |
| **Coverage map** | For each task in a draft, the Jira keys, the source ids and the source files it covers |
| **Source id** | The id the bundle gives each acceptance-criteria line, checklist item, description paragraph and comment paragraph of an issue. It is derived from the content (a hash of the normalised text), so it does not move when other lines are added or removed ([§6A.5](#6a5-how-a-rewrite-runs)) |
| **Org-admin** | An enabled org-admin of the Organization that owns the destination workspace. Only org-admins run imports in an Organization workspace ([§19](#19-permissions-and-plans)) |
| **Importer** | The person running an import. In an Organization workspace this is always an org-admin; in a personal workspace (only while plans are not enforced), its owner |
| **Source link** | The permanent record joining a rewritten task to the Jira issues it was written from |
| **Import plugin** | `stride-import` and its runtime variants: the agent-side plugin that fetches a bundle, drafts the tasks, reviews them and submits the draft ([§16A](#16a-the-agent-side-plugin-stride-import)) |
| **Variant** | One build of the import plugin for one agent runtime, such as `stride-copilot-import` for GitHub Copilot CLI |

---

## 3. What already exists that the import builds on

The import is new code, but most of its hard parts already have a pattern in
the app. Each new module below names the one it follows.

| Need | Existing code | How the import uses it |
|---|---|---|
| Writing many untrusted rows in one go | `Kanban.Workspaces.Export.Importer` ([Workspace Export](../workspace-export.md)) | Same rules: every row goes through its schema changeset, context functions that broadcast, notify, emit telemetry or enforce WIP limits are skipped, users are matched by email and never created, a report lists everything skipped or repaired. The importer writes the whole workspace in one transaction (`timeout: :infinity`) and stores attachment blobs inside it (`Importer.Attachments`). The import narrows that to one transaction per board and copies files after commit ([§16.3](#163-pipeline)) |
| Repairing rows that break a current rule | `Kanban.Workspaces.Export.Importer.Repairs` | Same idea for over-long label names and comments |
| Storing a credential that must be read back | `Kanban.Encryption` and `Kanban.Encryption.EncryptedBinary` (AES-256-GCM under `ENCRYPTION_KEY`, with a version byte so the key can be rotated), as `Kanban.SSO.SsoConnection` stores its client secret. The older `Kanban.Integrations.SecretBox` and `EncryptedString` derive their key from `secret_key_base` | The Jira API token is an `EncryptedBinary` field with `redact: true` ([§5.3](#53-where-credentials-live-and-for-how-long)). `EncryptedString` is not used, because rotating `secret_key_base` would silently drop every stored token |
| Calling a URL a user typed without reaching internal hosts | `Kanban.Webhooks.UrlGuard`, and the address pinning in `Kanban.Webhooks.Transport` and `Kanban.SSO.pinned_request/1` | `UrlGuard` only checks and resolves; the caller must connect to the address it approved. Every Jira request runs `UrlGuard.check(url, allow_http: false)` and connects through a pinned request. The pinning in `Kanban.SSO.pinned_request/1` moves into a shared helper that SSO and the import both use ([§20](#20-security-and-privacy)) |
| Background jobs | Oban, with queues in `config/config.exs` (Lifeline `rescue_after: {60, :minutes}`) | New `imports` queue, concurrency 2 per node. Uniqueness and job limits in [§16.3](#163-pipeline) |
| HTTP | `Req` (project rule). `Kanban.Webhooks.Transport` reads `req_options` from config, which the test environment points at a `Req.Test` stub. (`Kanban.GitHub` injects a function instead) | The Jira client follows `Webhooks.Transport`: `Req` with configured `req_options` and `Req.Test` stubs |
| Task identifiers | `Kanban.Tasks.Identifiers.pregenerate_task_identifiers/2` | Identifiers are generated per board under the board's advisory lock, taken after the column locks ([§16.3](#163-pipeline)) |
| Two-level hierarchy | `Kanban.Tasks.Task.HierarchyValidations` | Goals contain only work and defect tasks; Jira sub-tasks are flattened ([§10.2](#102-hierarchy)) |
| AI-optimized boards | `Kanban.Boards.create_ai_optimized_board/3` (`ai_optimized_board: true`, the fixed Backlog, Ready, Doing, Review, Done columns) | Every board the import writes to is AI-optimized ([§7.2](#72-ai-optimized-board-or-custom-board)). The function cannot run inside the import's transaction: it commits its own, broadcasts and emits telemetry as it creates the columns, and falls back to the personal workspace. The import adds a non-broadcasting builder to `Kanban.Boards.Creation` that both use |
| Labels | `Kanban.Labels`, `Kanban.Labels.Label` (nine colour tokens, 40-character names, trimmed, unique per board ignoring case) | Jira labels and components become board labels ([§10.6](#106-labels-and-colours)) |
| Archiving with a reason | `Kanban.Tasks.Archiving` (`:completed`, `:duplicate`, `:wontdo`, `:deferred`, `:cancelled`). Archiving a goal archives its unarchived children with the goal's reason | Won't-do, cancelled and duplicate issues ([§13.2](#132-what-happens-to-each-kind-of-item)). A closed epic with open children is not archived ([§6.2](#62-completed-and-cancelled-work)) |
| Feature gating | `Kanban.Plans`, the only module that decides paid versus free | A new `:imports` feature makes the import and the rewrite Organization-only ([§19](#19-permissions-and-plans)) |
| Who may act in an Organization workspace | `Kanban.Workspaces.Policy.can_manage_workspace?/2` (an enabled org-admin of the workspace's Organization), `Kanban.Boards.OrgBoardMembers.lock_and_check/3` (asked before every board-membership insert on an Organization board), `Kanban.Workspaces.Invitations` | Only org-admins run imports ([§19](#19-permissions-and-plans)). Every board membership the import writes goes through `lock_and_check/3`, and Invite sends a workspace invitation ([§15.1](#151-matching)) |
| Files on tasks and comments | `Kanban.Attachments`, shipped in Stride 3.1.0: its storage behaviour, limits (`Kanban.Attachments.Limits`), plan gate, `Usage`, the pending-tombstone steps in `Attachments.Pipeline` and the blob cleanup worker ([Task Attachments](ATTACHMENTS-DESIGN.md)) | Jira attachments are copied through it ([§14.3](#143-attachments)). The rewrite's source files use the same storage, the same pending-tombstone steps and the quota, which needs changes to the cleanup worker and `Usage` ([§17](#17-database-changes)) |
| Agents downloading task files | The plugins' attachment download contract (`stride/docs/porting-attachments.md`: `.stride/attachments/<STEM>/`, a manifest, sha256 checks), with a section of its own for rewrite downloads | The import plugin downloads an epic's files under the rewrite section, with a download script of its own ([§6A.5](#6a5-how-a-rewrite-runs), [§16A.5](#16a5-the-rewrite-epic-procedure)) |
| One plugin family across every runtime | The ideation and security-review families: a Claude Code source plugin (`stride-ideation`, `stride-security-review`) and a port for Codex CLI, GitHub Copilot CLI, Gemini CLI and OpenCode, each with its own manifest and release. Pi has no port of either family and no marketplace: only the workflow port `stride-pi` exists | The import plugin is built the same way, as a new family with six variants ([§16A](#16a-the-agent-side-plugin-stride-import)). Pi has no family precedent, so `stride-pi-import` is the first Pi companion package ([§16A.8](#16a8-pi-the-first-companion-package)) |
| Credential detection | `Kanban.Tasks.CredentialShapes`. It has no pattern for Atlassian API tokens today | Warns when imported text looks like it carries a secret. The import adds Atlassian token shapes ([§20](#20-security-and-privacy)) |
| Audit log | `Kanban.AuditLog.event/2`, with each action declared in `@audit_actions` (`Kanban.Telemetry.Catalog.Families`) | New import audit actions ([§21.2](#212-audit-log)) |
| Telemetry | `Kanban.Telemetry.emit/3`, `Kanban.Telemetry.Catalog` ([Telemetry](../telemetry.md)) | New `import` events ([§21](#21-telemetry-audit-log-and-the-import-report)) |
| Agents writing goals and tasks | The batch shape of [`POST /api/tasks/batch`](../api/post_tasks_batch.md) and the field rules of the Stride plugin's `create-goals` skill | A rewrite draft uses the same goal and task shape. The import plugin carries a pinned copy of those field rules, so it does not depend on which Stride plugin, full or lite, is installed ([§16A.4](#16a4-what-each-variant-contains)) |
| Writing tasks from a source document, with a review pass | stride-ideation's `/stridify` (stamps `source_spec` and `source_spec_sha256`) and its requirements-decomposer and requirements-reviewer agents | The rewrite records the hash of the bundle it was written from. The import plugin's drafter and coverage-reviewer agents follow the decomposer and reviewer: the reviewer reports without editing ([§6A.6](#6a6-the-second-pass-a-coverage-report), [§16A.6](#16a6-the-agents)) |

---

## 4. The import at a glance

```text
 Connect ──► Choose scope ──► Fetch ──► Rewrite or ──► Map ──► Preview ──► Import ──► Rewrite ──► Report
   │             │              │       import           │         │          │          │          │
 site,        projects,      pull     per epic,      statuses,  counts,    write the  per epic:  links to
 email,       boards,        issues   rewrite        types,     sample     direct     agent      boards,
 token,       epics,         into     recommended    people,    cards,     imports,   drafts,    unmatched
 test it      filters, JQL   staging  for not-       labels,    warnings   one        coverage   people,
                                      started work   fields                transaction check,    coverage,
                                                                           per board   sign-off  downloads
                                                                                                    │
                                                                   Re-sync changes ◄────────────────┤
                                                                   Finish migration ◄───────────────┘
```

The run is a state machine stored in `import_runs.status`:

```text
draft → fetching → fetched → importing → imported → finished      (finished: Phase 3)
  │         │         │          │           │
  │         └─────────┴──────────┴─► failed  ├──► resyncing → imported   (Phase 3)
  └─────────┴─────────┴──► cancelled         ├──► importing → imported   (Retry this board)
                                             └──► undone
```

Every transition is a compare-and-set update (`UPDATE … WHERE status = <expected>`),
so two requests can never move the same run at once. Only one of import,
retry, re-sync and undo runs for a run at a time ([§16.3](#163-pipeline)).

| From | Event | To | Guard and notes |
|---|---|---|---|
| `draft` | **Fetch** | `fetching` | The scope is saved, and relative filters (**Recent**, **Updated since** a number of days) are frozen to absolute dates |
| `draft`, `fetching`, `fetched` | **Cancel** | `cancelled` | Staging is purged |
| `fetching` | Fetch done | `fetched` | |
| `fetching` | Fetch error, or the staging limit ([§6.3](#63-size-limits)) | `failed` | Staging is purged |
| `fetched` | **Import** | `importing` | The preview has no blocking error |
| `importing` | Every board job ended, at least one board committed | `imported` | Failed boards are listed with **Retry this board** |
| `importing` | Every board failed | `failed` | No board exists, so there is nothing to undo |
| `importing` | **Cancel** | `imported`, or `cancelled` when no board has committed | Board jobs not yet started are cancelled. Boards already written stay, and **Undo import** removes them |
| `imported` | **Retry this board** | `importing` | Only for a failed board, and only while its staged items are kept ([§17](#17-database-changes)) |
| `imported` | **Re-sync changes** (Phase 3) | `resyncing` | Needs a stored credential |
| `resyncing` | Re-sync done, or failed (for example a revoked token) | `imported` | A failure is shown on the run page and in the report, and changes nothing already written |
| `imported` | **Finish migration** (Phase 3) | `finished` | No rewrite is `preparing`, `pending` or `drafted`, no file copy is running, and no conflict is open. Checked again after Finish's last re-sync ([§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)) |
| `imported` | **Undo import** | `undone` | The run's jobs are cancelled first ([§13.7](#137-undo)) |

The credential's expiry is not a run transition. It deletes the credential and
leaves the run `imported` ([§5.3](#53-where-credentials-live-and-for-how-long)).

Each epic chosen for rewrite has its own state, stored in
`import_rewrites.status`, while the run is `imported`:

```text
preparing → pending → drafted → signed_off   (the tasks are written at sign-off)
                         │
                         └──► pending         (draft discarded, or sent back with a note)
pending / drafted → imported_directly         (the importer changes their mind)
```

| From | Event | By | To | Notes |
|---|---|---|---|---|
| (none) | **Import** writes the board | Stride | `preparing` | The source files are still being copied ([§16.3](#163-pipeline)) |
| `preparing` | Every file copied or failed | Stride | `pending`, or `drafted` when a draft from before a re-sync rebuild is kept (marked stale) | The bundle is frozen and hashed |
| `pending`, `drafted` | Re-sync rebuilds the bundle (Phase 3) | Stride | `preparing` | A draft is kept and marked stale |
| `pending`, `drafted` | `POST …/draft` accepted | The agent, through the API | `drafted` | A new draft replaces the old one |
| `drafted` | **Send back**, or **Discard draft** | An org-admin | `pending` | |
| `drafted` | **Sign off** | An org-admin | `signed_off` | Only the draft the signer saw, with nothing uncovered ([§6A.7](#6a7-sign-off)) |
| `pending`, `drafted` | **Import directly instead** | An org-admin | `imported_directly` | |

`signed_off` and `imported_directly` are final. All the rewrite API endpoints
refuse a rewrite in either state with `409 rewrite_closed`, and the bundle
endpoint refuses a `preparing` one with `409 not_ready`
([§16.6](#166-the-rewrite-api)).

A run can be finished only when no rewrite is `preparing`, `pending` or
`drafted`.

Fetching and importing are separate steps on purpose. Fetching copies the
Jira issues into a staging table once, so the importer can change the
mapping, preview it and fix warnings any number of times without calling Jira
again. Only **Import**, **Retry this board**, and a rewrite's **Sign off** or
**Import directly instead** write tasks (and, in Phase 3, re-sync).

---

## 5. Connecting to Jira

### 5.1 Jira Cloud

| | Phase 1 | Phase 3 |
|---|---|---|
| Method | Site URL + account email + API token (HTTP basic auth) | OAuth 2.0 (3LO) app ("Stride Import") |
| Site | `https://<name>.atlassian.net`, typed by the importer. Any other host is refused: the name must be a single label under `atlassian.net`, which also means the email addresses Jira returns come from Atlassian ([§15.1](#151-matching)) | Chosen from `accessible-resources` after consent |
| Scopes needed | The token has the user's own access | `read:jira-work`, `read:jira-user`, `offline_access` (plus `write:jira-work` only for the optional marker in [§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)) |
| What the importer sees | Every project and board their Jira account can browse | same |

**Test connection** calls `GET /rest/api/3/myself` and `GET /rest/api/3/serverInfo`
and shows the site title and the account it is connected as, so the importer
can tell they pasted the right token. If `deploymentType` is not `Cloud`, it
shows a warning pointing to Phase 4.

The connection page links to Atlassian's own page for creating an API token
and says plainly that the token has the same access as the account that
created it, so the importer should use an account that can see everything
they want to move and nothing more.

### 5.2 Jira Data Center (Phase 4)

Personal access token as a bearer token, REST API v2, wiki-markup text instead
of the Atlassian document format. On hosted Stride the site must be publicly
reachable; on a self-hosted instance an operator can allow private addresses
through config (see [§20](#20-security-and-privacy)). A Data Center site is
run by the customer, so the email addresses it returns are never treated as
verified.

### 5.3 Where credentials live and for how long

- Stored in `import_connections.credential` as a `Kanban.Encryption.EncryptedBinary`
  field with `redact: true`, as `SsoConnection` stores its client secret, so
  inspecting a connection (in a crash report, an Oban error or `dbg`) never
  prints the token. List queries select named columns through one query
  helper, so the credential is loaded only where a request to Jira is made.
  Never logged, never in telemetry metadata, never in the report, never in a
  workspace export, never shown again after it is saved (the form shows only
  "a token is saved, added by Ana on 3 Oct").
- A connection belongs to a **workspace**. In an Organization workspace it can
  be created and used only by the Organization's enabled org-admins, checked
  at the moment of use; the person who created it has no right of their own
  ([§19](#19-permissions-and-plans)). Several runs can share one connection.
- **Its lifetime is the connection's, not a run's.** The credential is deleted
  when the last unfinished run using the connection finishes
  ([§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)), or after 30
  days in which no run using it fetched, re-synced, retried a board or signed
  off a rewrite. **Expiry deletes only the credential.** The runs stay
  `imported`, Undo stays offered, and a re-sync asks for a token again. The
  expiry runs in `CleanupWorker` (Phase 1) and writes an audit event with no
  user ([§21.2](#212-audit-log)). An org-admin can delete the credential at any
  time from the run page, which first lists the runs that use it.
- Archiving a workspace deletes its import connections, as it already revokes
  its workspace tokens and invitations.
- The stored form carries a key version byte, so `ENCRYPTION_KEY` can be
  rotated without losing stored tokens. If the key that encrypted a credential
  is ever removed, `EncryptedBinary.load/1` returns `:error` (unlike
  `EncryptedString`, which loads `nil`). `Kanban.Imports` therefore reads the
  credential in its own query and treats a failed load as a missing token: the
  run page asks for it again.

---

## 6. Choosing what to import

Scope is chosen in three layers: containers, then (optionally) epics inside
them, then filters. The page shows live counts as each choice changes. Counts
come from Jira's approximate-count endpoint, not a full fetch.

Choosing **how** each epic comes across, rewritten or imported directly, is a
separate step after the fetch ([§6A](#6a-rewrite-or-import-epic-by-epic)),
because the recommendation needs the issues' statuses and text.

### 6.1 Containers, epics and filters

| Layer | Choices | Notes |
|---|---|---|
| Projects or boards | Either **projects** (everything in them) or **boards** (everything matching the board's saved filter), each with its issue count | A Jira board's column layout is not copied: every destination is an AI-optimized board ([§7.2](#72-ai-optimized-board-or-custom-board)), and its statuses map to the five fixed columns. A board whose filter reaches into several projects shows which ones |
| Epics | Every epic in scope, with child count, status and assignee. Plus a row **Issues with no epic** | Unticking an epic leaves out the epic and its children |
| Filters | Issue types; status categories (To Do, In Progress, Done); **Updated since**; labels to include or exclude; components; fix versions; sprints | |
| Advanced | A JQL box, combined with the choices above using `AND` | For teams who already have the query they want. Shown, but collapsed. The JQL is sent only to the Jira site the connection names. A JQL syntax error from Jira is shown under the box |

### 6.2 Completed and cancelled work

Teams rarely want years of closed work on a new board, but they often want the
recent history. This is a separate choice on the scope page because it changes
the counts so much:

| Choice | Done issues with a "done" resolution | Won't-do, cancelled and duplicate issues |
|---|---|---|
| **Recent** (default) | Resolved in the last 90 days → Done column | Not imported |
| **All** | Every resolved issue → Done column | Archived with a reason ([§13.2](#132-what-happens-to-each-kind-of-item)) |
| **Open work only** | Not imported | Not imported |
| **Archive closed work** | Every resolved issue → archived as `:completed`, so it is searchable but off the board | Archived with a reason |

An open child under a closed epic is always imported, together with its epic,
whatever the choice, so no open work loses its goal. Such an epic is **not
archived**, even under **All** or **Archive closed work**, because archiving a
goal archives its unarchived children with the goal's reason
(`Kanban.Tasks.Archiving`). It is placed by its children like any goal
([§10.3](#103-status-to-column)), and its Jira resolution is kept on its
import link.

The 90-day window of **Recent** is turned into an absolute date when the run
is first fetched, so a later re-sync uses the same window.

### 6.3 Size limits

| Limit | Value | When it is reached |
|---|---|---|
| Issues per run | 20,000 | The scope page refuses to continue and suggests splitting by project, epic or date |
| Issues per destination board | 20,000 until Phase 1 measures the write ([§16.5](#165-long-transactions)) | **One board for everything** can put a whole run on one board, so the measurement is made at that size |
| Comments per issue | 500 (newest kept) | Older comments are counted in the report and stay in Jira |
| Text per comment | 10,000 characters (the existing comment cap), counting the *Originally by* prefix and the shortening note ([§14.2](#142-comments)) | Shortened, with a note, and listed under *repaired* |
| Staged data per run | 500 MB, measured as the sum of `import_staged_items.byte_size`, the length of each encoded item, set on every upsert so a retried page is not counted twice | Checked in the same transaction as each page's upsert. The fetch stops and fails with a clear message. Attachment files are not staged and do not count |
| Attachment files | The configured attachment limits (`Kanban.Attachments.Limits`: `max_file_bytes/0`, `max_files_per_task/0`, `organization_quota_bytes/0`; 25 MiB, 20 and 10 GiB by default) | Files over a limit stay links to Jira ([§14.3](#143-attachments)) |

The limits are config values (`config :kanban, Kanban.Imports, ...`), so a
self-hosted operator can raise them.

---

## 6A. Rewrite or import, epic by epic

### 6A.1 Why rewrite

A direct import is faithful: what was in Jira is what arrives. That is right
for work that has started or finished, because it carries people, review
state and history. For work that has not started it carries Jira's problems
across as well. Issues are often a title and a sentence, out of date,
duplicated across epics, or split in ways that suited a sprint plan rather than
the work. And Jira has nothing for the fields an agent works from
([§9.3](#93-stride-fields-jira-does-not-fill)), so every directly imported task
needs enriching before an agent can take it.

A rewrite treats the not-started issues of an epic as requirements, not as
tasks. An agent reads all of them, with their comments and links, and writes
the Stride tasks that would deliver them: sized for Stride, with
`key_files`, `testing_strategy`, `acceptance_criteria` and the other
agent-facing fields filled from the team's repository. A coverage check then
shows that every issue, and every line and paragraph in them, is cited by a
task, and warns where a citation looks thin. The check proves citation, not
delivery: the person signing reads each issue beside the tasks that cite it,
ticks it as reviewed, and signs the result off ([§6A.6](#6a6-the-second-pass-a-coverage-report)).
Nothing is written to the board before that.

### 6A.2 The choice and the recommendation

After the fetch, the **Rewrite or import** page lists every epic in scope, plus
one row per project for **Issues with no epic**. Each row shows the counts of
not-started, in-progress and done issues, the recommended path, the signals
behind it, and a choice the importer can change.

| What the epic holds | Paths offered | Recommended |
|---|---|---|
| Only not-started issues | **Rewrite** or **Import directly** | **Rewrite** |
| Started or done issues, and not-started issues ([§6A.3](#6a3-epics-already-in-progress)) | **Import started work, rewrite the rest** or **Import directly** | **Import started work, rewrite the rest** |
| Only started or done issues | **Import directly** | **Import directly**: there is nothing to rewrite |

**Stride recommends the rewrite for every epic with not-started work.** The
row also shows the signals that make the case for that epic, so the importer
can see where a rewrite matters most:

- issues with no description, or a description under 100 characters,
- issues with nothing that reads as acceptance criteria (no checklist, no
  *Acceptance criteria* heading, no mapped acceptance-criteria field),
- issues not updated in Jira for 180 days or more,
- issues with no estimate,
- titles that are near-duplicates of an issue in another epic.

The signals inform the choice. They never change the recommendation to
**Import directly** for an epic with not-started work: the agent-facing
fields are empty on a direct import whatever the issue's quality. The page has
**Rewrite all recommended** and **Import all directly** at the top.

**The rewrite is always offered and always recommended.** It is preselected on
every epic with not-started work, in every import. No Organization,
workspace, plan or config setting turns it off, hides this page, or changes the
recommendation. A team that wants a direct import chooses it here, epic by
epic or with **Import all directly**, and the run report records that choice.

The page also offers **Rewrite without files**, which sends the agent the
issues' text and file names but not the files themselves
([§6A.5](#6a5-how-a-rewrite-runs)), for a team that does not want its Jira
attachments read by its agent's model.

The choice is saved with the run (`import_runs.options`), so going back to the
page after a mapping change keeps it.

### 6A.3 Epics already in progress

An epic with work under way is split. Its started and done issues are imported
directly, so the people on them, their columns, their review state and their
history all survive ([§13.2](#132-what-happens-to-each-kind-of-item)). Its
not-started issues are rewritten. Both end up under the **same goal**: the
import creates the goal from the epic, writes the started work under it, and
the rewrite adds its tasks to that goal at sign-off.

| Issue | Path |
|---|---|
| Not started, and its parent story (if it is a sub-task) not started | Rewritten |
| Not started sub-task of a story that is in progress or in review | Imported directly with its story. It is part of the plan of the person doing the story, so it is not reworded under them |
| In progress, in review | Imported directly |
| Done, won't do, cancelled, duplicate | Imported directly, per [§6.2](#62-completed-and-cancelled-work) |

The bundle for a split epic also carries the started and done issues, marked
**context only**, so the agent knows what is already built or being built and
does not write tasks for it. Generated tasks can depend on the imported ones by
identifier, because those identifiers exist by the time the draft is written.
Context-only issues are not part of the coverage check.

### 6A.4 Issues with no epic

Not-started issues with no epic are grouped into one rewrite per project
(or, if the importer chooses, per component). Each becomes a goal named
*<Project>: work with no epic*, editable on the sign-off page. The importer can
also import them directly instead, as top-level tasks per [§10.2](#102-hierarchy).
Each group has a key of its own (`import_rewrites.group_key`: the epic's Jira
id, `noepic:<project>`, or `noepic:<project>/<component>`), so no-epic groups
are kept unique like epics ([§17](#17-database-changes)).

### 6A.5 How a rewrite runs

The rewrite runs in the team's own agent, against its own checked-out
repository, because filling `key_files` and `patterns_to_follow` needs the
code. Stride prepares the input, checks the output and writes the tasks.

1. **Stride builds the epic bundle** when the run is imported. It holds the
   epic and every issue being rewritten as normalised `Kanban.Imports.Item`
   values ([§8](#8-the-common-item-model)), with the mapped values (priority,
   labels, complexity) alongside as hints, and the context-only issues of a
   split epic. Each acceptance-criteria line, checklist item, description
   paragraph and comment paragraph in it gets a **source id**, which the
   coverage map cites ([§16A.4](#16a4-what-each-variant-contains)). The id is
   derived from the content: a prefix (`ac:`, `checklist:`, `para:`, or
   `comment:<comment id>:`) and the first 12 hex characters of the SHA-256 of
   the normalised text (Unicode NFC, whitespace collapsed, trimmed,
   lowercased), with `-2`, `-3` added when the same text repeats in one issue.
   An id therefore stays the same when other lines are added, removed or
   moved, and changes only when its own text changes. A sub-task is an item of
   its own in the bundle, so it is covered by its own key and ids; its parent
   gets no line for it.
   Restricted issues and comments skipped under
   [§20](#20-security-and-privacy) are never in it. An issue held out because
   its text looks like it carries a credential ([§6A.8](#6a8-constraints-and-risks))
   is listed by key only, as **held out**, so the coverage check still sees it.
   The bundle is serialised once and stored as those exact bytes
   (`import_rewrites.bundle_json`, text) with the SHA-256 of the bytes. It is
   served byte for byte, so any client can hash what it received. The hash
   proves the bundle arrived intact and is the current version; it does not
   prove who sent it. The bundle lists each issue's attachments as metadata,
   and the files themselves are copied into Stride as **source files**
   (below). Until every file is copied or has failed, the rewrite is
   `preparing` and the bundle endpoint answers `409 not_ready`; then the
   bundle is frozen and hashed, and the rewrite becomes `pending`.
2. **An org-admin starts the rewrite** from the run page. The page shows the
   command to run in the agent, for one epic or for every pending one, in the
   form the importer's runtime uses: `/stride-import:rewrite-epic 41 42` in
   Claude Code, for example, or the `stride-import-rewrite-epic` skill in Codex
   CLI ([§16A.3](#16a3-the-variants)). The agent needs the import plugin
   installed and an API token whose creator is still an org-admin: a
   workspace token for the destination workspace (only org-admins make
   those), or a board token for the destination board. The rewrite endpoints
   find the board from the rewrite id, so a workspace token needs no
   `X-Stride-Board` header, and the new boards an import creates are reached
   without a new token. The page shows the destination board too
   ([§16.6](#166-the-rewrite-api)).
3. **The agent fetches the bundle**
   (`GET /api/import_rewrites/:id` for its state, then
   `GET /api/import_rewrites/:id/bundle` for the bytes) and the import
   plugin's drafter agent writes the epic's goal and tasks, using the bundle
   and its source files as its context and the team's repository for the
   agent-facing fields. The output is the goal-and-tasks shape of
   [`POST /api/tasks/batch`](../api/post_tasks_batch.md), with the extensions
   named in [§16.6](#166-the-rewrite-api), and the plugin applies the same
   field rules as the `create-goals` skill. Beside it, the agent writes a
   **coverage map**: for each task, the Jira keys, the source ids and the
   source files it covers; for each key, id or file it chose not to cover, a
   reason.
4. **The plugin's coverage-reviewer agent** reads the bundle and the draft
   and reports, without editing, what it finds
   ([§6A.6](#6a6-the-second-pass-a-coverage-report)). Its report is the
   agent's own claim: Stride cannot check that it ran, or that it ran apart
   from the drafter.
5. **The agent submits the draft** (`POST /api/import_rewrites/:id/draft`),
   with the coverage map, the reviewer's findings, the bundle hash it worked
   from, and the download result of every file in the manifest (downloaded,
   skipped by a cap, failed, or not fetched because the run chose **Rewrite
   without files**). The draft is written to a local file first, as
   `/stridify` does, so it can be read before it is sent.
6. **Stride checks the draft** on receipt: every task through its changeset
   without inserting, as the preview does; the draft's dependencies resolved
   (index range, no task depending on itself) and checked for cycles, together
   with the dependencies Jira links will add at sign-off
   ([§10.7](#107-dependencies-and-other-relations)), because a changeset
   checks cycles only for a task that already has an id; the coverage map
   against the bundle, and the warnings Stride computes
   ([§6A.6](#6a6-the-second-pass-a-coverage-report)); the bundle hash against
   the stored one; the size cap; and the credential scan. The rewrite becomes
   `drafted`.

A large epic is split by story into chunks that fit the agent's context. The
command handles the chunks and renumbers the task indexes when it merges
them, in the dependencies and the coverage map alike. Coverage is computed
across all of them, and the result is still one goal per epic.

**Source files.** Screenshots, designs, logs and specs are often where an
issue's real requirements are, so the agent needs the files, not just their
names.

- When the bundle is built, Stride copies each rewritten issue's attachments
  from Jira into attachment storage, as [§14.3](#143-attachments) does for
  directly imported tasks, with the same allow-list, magic-byte check, size
  limit. They are held by the rewrite (`import_rewrite_files`),
  not by a task, because the task they belong to does not exist yet. They are
  stored through a new `Kanban.Attachments.store_rewrite_file` function, with
  the same file checks, the quota lock and the pending-tombstone steps as a
  task upload, and they count against the quota while they are held
  ([§17](#17-database-changes)). A file whose only references are in skipped
  comments ([§20](#20-security-and-privacy)) is not copied. A file that cannot
  be copied is listed in the bundle as a Jira link with its reason.
- The bundle lists each file with the same eight keys as a task attachment
  (`id`, `filename`, `content_type`, `byte_size`, `sha256`, `comment_id`,
  `uploaded_at`, `download_url`; `comment_id` is always `null`, because no
  Stride comment exists yet), plus the Jira key it came from. The
  `download_url` is `/api/import_rewrites/<id>/files/<file id>`
  ([§16.6](#166-the-rewrite-api)).
- The import plugin downloads them under the attachment download contract
  (`stride/docs/porting-attachments.md`), with a download script of its own:
  into `.stride/attachments/rewrite-<id>/`, with a manifest, a sha256 check on
  every file, and the token never on a command line. The Stride plugins'
  download code lives in their post-claim hooks, which the import plugin does
  not depend on, and the rewrite rules differ from the task rules in layout,
  manifest identity, path rule, caps and `429` handling. It hands the
  directory to the agents and removes it once the draft is submitted. The
  contract has a section of its own for rewrite downloads ([Task Attachments](ATTACHMENTS-DESIGN.md#91-the-contract-w2521),
  *Rewrite downloads*):
  - the manifest names the rewrite and its bundle hash instead of a task;
  - files are fetched only after the bundle hash matched, and only from
    `/api/import_rewrites/<id>/files/`;
  - the plugin downloads through its own script, so the agent's curl guard
    never sees the request and needs no exemption;
  - the caps are 25 MiB per file, 20 files per Jira issue, and 500 MiB per
    rewrite within 600 s.
- The agent reads images and PDFs with its runtime's own tools and treats
  every file as untrusted data. A file the caps skipped is still listed in
  the manifest, so the agent knows it exists and the coverage map must still
  account for it. The manifest's result for each file is sent with the draft,
  so Stride knows which files the model never saw
  ([§6A.6](#6a6-the-second-pass-a-coverage-report)).
- The coverage map, and only the coverage map, names the source files each
  task needs (`files`: file ids). A file can go to more than one task.

### 6A.6 The second pass: a coverage report

The second pass is not a second agent saying "looks complete". It has three
parts: checks Stride computes from the coverage map and the bundle, findings
from a reviewer agent, and a tick from the person signing for each Jira issue.

| Check | Done by | Finds |
|---|---|---|
| **Every key is accounted for** | Stride, from the coverage map | Jira keys in the bundle that no task cites, and keys the agent marked *dropped* (each needs a reason). Issues held out of the bundle for credential-shaped text count as uncovered |
| **Every source id is accounted for** | Stride, from the coverage map | Acceptance-criteria lines, checklist items, description paragraphs and comment paragraphs no task cites |
| **Every file is accounted for** | Stride, from the coverage map | Source files no task takes and the agent did not mark *not needed* with a reason |
| **Files the model never saw** | Stride, from the download results | Files cited or marked *not needed* that were never downloaded (skipped by a cap, failed, or **Rewrite without files**). They are listed apart, and are not counted as covered until the person signing confirms each one |
| **Merges and splits are visible** | Stride, from the coverage map | Where several issues became one task, or one issue became several, so the person signing sees the change in shape |
| **Thin citations** | Stride, computed warning | An issue with description or comment prose that is cited only by its key, with none of its paragraph ids |
| **Wide tasks** | Stride, computed warning | One task citing more than five Jira keys (a config value) |
| **No shared terms** | Stride, computed warning | A task whose title, description and acceptance criteria share no word (after removing common words) with the text of the issues it cites |
| **Citations are real** | The reviewer agent | A task that cites PAY-88 but does not cover what PAY-88 asks for |
| **Nothing is invented** | The reviewer agent | Requirements, limits or behaviour in a task that no issue or comment supports |
| **Later comments are honoured** | The reviewer agent | A task written from an issue's description when a later comment changed the scope |
| **No instructions aimed at agents** | The reviewer agent | Text carried over from Jira that tells an agent what to do outside the task |
| **Each issue is reviewed** | The person signing | A tick per Jira issue, given after reading the issue beside the tasks that cite it. Sign-off needs every tick ([§6A.7](#6a7-sign-off)) |

**What the check proves.** The id check proves that every key, id and file
was **cited** by some task or dropped with a reason. It does not prove that a
task **delivers** what it cites: the coverage map is written by the drafter,
and a task can cite a paragraph it ignores. The computed warnings point at the
citations most likely to be empty, and the person signing, not the check,
decides that the work is covered.

**The reviewer's findings are the agent's claim.** They arrive in the same
request as the draft, from the same procedure, so Stride cannot tell an empty
list from a review that never ran, or check the `independent` flag
([§16A.6](#16a6-the-agents)). The sign-off page shows the findings, and the
flag, under *Reported by the agent*, and nothing in Stride trusts them: no
finding or flag clears a warning or replaces a tick.

The report has seven lists: **Covered**, **Uncovered**, **Dropped with a
reason**, **Not downloaded**, **Warnings**, **Reported by the agent** (the
reviewer's findings) and **Merges and splits**. The reviewer follows the
pattern of stride-ideation's requirements-reviewer: it reports and never
edits.

### 6A.7 Sign-off

Only an org-admin signs off ([§19](#19-permissions-and-plans)). The sign-off
page shows the draft as task cards (the real task card component, as the
preview does), and under each card every agent-facing field in full:
`verification_steps` with their commands, `testing_strategy`, `key_files`,
`patterns_to_follow` and the rest, because a card alone hides the fields an
agent will act on. Text the reviewer reported as aimed at an agent, and
command-shaped text, is highlighted. Beside the cards are the coverage report
and each Jira issue with the tasks that cite it, its text, and a **Reviewed**
tick. The person signing can:

- **Sign off**, which writes the goal and its tasks to the board's Backlog in
  one transaction, with source links ([§12](#12-data-that-does-not-map)), and
  then copies each source file onto every task the coverage map gives it to,
- **Send back** with a note, which returns the rewrite to `pending`; the next
  run of the command receives the note,
- **Leave out** a task from the draft,
- **Mark dropped** an uncovered key or source id, with a reason,
- **Confirm** a file the model never saw, or mark it dropped,
- **Import directly instead**, which writes the epic's issues as a direct
  import would, with their source files copied onto the tasks of the issues
  they came from, and **Import this issue directly** for one issue, such as
  one held out for credential-shaped text.

**What sign-off requires.**

- **Nothing uncovered.** Every key, source id and file is covered or marked
  dropped by the person signing. An issue held out of the bundle for
  credential-shaped text has no route onto the board except being dropped
  with a reason or imported directly, so it blocks sign-off until one of those
  is chosen.
- **Every issue ticked** as reviewed.
- **Coverage against the current bundle.** Coverage is computed again at
  sign-off, against the bundle as it is then. Because source ids are derived
  from content, a re-sync that changed an issue changes only the ids of the
  lines that changed. A stale draft ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira))
  cannot be signed off until every new or changed id is covered or dropped.
- **The draft the signer saw.** The sign-off form carries the draft's id and
  the hash of its bytes. If the stored draft changed after the page loaded,
  for example because the agent submitted again, sign-off is refused and the
  page shows the new draft.

If the sign-off transaction fails (a task the changeset now refuses, a
dependency that no longer resolves), nothing is written, the rewrite stays
`drafted`, and the page shows the error on the task it came from, so the
person can leave the task out or send the draft back.

The transaction takes the board's column locks (`Kanban.Tasks.ColumnLocks.lock/1`,
every column of the board) before the board's identifier lock, the order
`Kanban.Tasks.GoalCreation` uses, because sign-off writes to a board people
are already using. Taking them the other way round can deadlock against a
task being created at the same time.

Signed-off tasks land in Backlog like all
imported work ([§13.1](#131-the-principles)); moving them to Ready is a
separate human step. Each one shows **Written from PAY-88, PAY-91** under its
title. Generated tasks are unassigned, because one task can cover issues
assigned to different people; the source assignees are shown in the
**Written from** panel. The person signing can assign a task to one of them
before signing off, under the matching rules of
[§15](#15-people-and-board-membership); adding that person to the board goes
through `OrgBoardMembers.lock_and_check/3` like every other membership the
import writes.

The sign-off page shows each source file with the tasks it will be attached
to, so the person signing can move one. Files are copied from the rewrite's
storage onto the tasks by `AttachmentWorker` after the transaction commits,
through `Kanban.Attachments.import_attachment/4`, with the per-task limit and
the quota checked again; a file attached to two tasks counts twice against the
quota. The storage behaviour has no copy callback, so the worker streams each
stored file to a temp file and stores that under the new key. A file that cannot be copied is listed on the rewrite page with
**Retry**. Once every file is copied, the rewrite's source files are deleted
through the blob tombstones. The **Written from** panel still lists every
source file with its Jira link.

**Import directly instead** needs the issues at full size, and the bundle
caps each item at 64 KB. It is written from the staged items, which are kept
while any rewrite of the run is open ([§17](#17-database-changes)), and never
from a capped bundle item. If the staged items are gone, the issues are
fetched again from Jira, which needs the stored credential.

Writing at sign-off, rather than when the agent submits, is what keeps a bad
draft off the board. The API has no delete and no reparenting, so a draft
written straight to the board could only be cleaned up by hand. A draft on the
run can be sent back or replaced as often as needed.

### 6A.8 Constraints and risks

| Risk | Rule |
|---|---|
| **Jira text goes to a model provider** | The rewrite runs in the team's own agent, so whatever provider that agent uses receives the bundle. The **Rewrite or import** page says so. The importer can choose **Rewrite without files**, or import an epic directly |
| **Files go to a model provider** | Source files are downloaded by the team's agent and read with its model, like the bundle's text. The **Rewrite or import** page says so, and **Rewrite without files** sends metadata only |
| **A file tries to steer the agent** | Files are untrusted data from Jira users. The agent reads only manifest-listed files, never runs or unpacks one (archives are not stored at all), and reports text in a file that tries to direct it, as the attachment contract requires |
| **Restricted issues reach the agent** | Skipped issues and comments are never in the bundle. If the importer opted in to restricted issues, those issues are imported directly unless the importer ticks a second box that names the model-provider exposure |
| **Imported text tries to steer the agent** | The bundle is untrusted data, not instructions: the existing agent rule applies, the reviewer flags instructions carried into a task, and the sign-off page shows every agent-facing field in full, with command-shaped text highlighted ([§6A.7](#6a7-sign-off)) |
| **Imported text carries secrets** | The bundle is built after the same `Kanban.Tasks.CredentialShapes` scan as the preview, with the Atlassian token shapes the import adds ([§20](#20-security-and-privacy)). An issue with a match is held out of the bundle, listed by key as uncovered, and blocks sign-off until it is dropped with a reason or imported directly. After a mapping change that excludes the field, **Rebuild bundle** on the run page builds the bundle again. Drafts are scanned again on receipt |
| **The drafter reads the repository, and the repository holds `.stride_auth.md`** | Both agents' rules forbid reading `.stride_auth.md`, `.env` and other credential files, and the contract script pins that rule. Tool limits on agents are advisory on some runtimes (Codex CLI documents no tools key for custom agents), so the procedure also checks that no field of the draft contains the token before it submits, and Stride's credential scan on receipt is the last check |
| **The draft is untrusted input** | It is validated by the task changesets and the dependency checks, capped in size (2 MiB of JSON and 200 tasks), and never written until a person signs it off. A draft submitted against an older bundle hash is refused |
| **Two runs give different tasks** | The rewrite is not deterministic. The coverage report is what makes a result checkable. The bundle, its hash, the signed-off draft and the report are kept with the run, so a rewrite can be audited later |
| **Jira changes after the rewrite** (Phase 3) | Re-sync never edits rewritten tasks ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)). A change to a rewritten issue is listed under **Changed after rewrite**, naming the tasks written from it |
| **The team has no agent, or no repository** | **Import directly** is always available, and a run never waits on a rewrite to import the rest. Without a repository the agent still writes the tasks, with `key_files` left for enrichment |
| **Cost and time** | Each epic costs a model run and a review. The command runs per epic or over all pending ones, and pending rewrites do not block the board: the started work is already on it |
| **Two levels only** | Goals never contain goals ([§10.2](#102-hierarchy)). An epic's stories and sub-tasks all become tasks under one goal |

---

## 7. Where imported work lands

### 7.1 New boards, by default

Each run creates **new AI-optimized boards** in the current workspace
([§7.2](#72-ai-optimized-board-or-custom-board)). The importer chooses one of:

- **One board per container** (default): one Stride board per Jira project or
  board, named after it ("Payments (from Jira)"), editable.
- **One board for everything**: all chosen containers on one board, with a
  label per project so they can be told apart.

Importing **into an existing board** comes in Phase 3, and only into an
existing AI-optimized board. It needs collision rules (existing labels,
identifier ranges) that new boards do not, and new boards make undo trivial.
Undo of an import into an existing board deletes only what the run wrote,
never the board ([§13.7](#137-undo)).

### 7.2 AI-optimized board or custom board

**The import writes only to AI-optimized boards.** Every board a run creates
has `ai_optimized_board: true` and the five fixed columns, and a custom board
is not offered. The Phase 3 import into an existing board accepts only a
board with `ai_optimized_board: true`.

**How the board is made.** `Kanban.Boards.create_ai_optimized_board/3` cannot
be called inside the import's transaction. It commits its own transaction,
then creates the columns with broadcasts and telemetry, so a board that later
rolls back would already have been announced. It also puts the board in the
user's personal workspace when the named workspace is refused, which would
skip the plan check made on the destination workspace. The import adds a
builder to `Kanban.Boards.Creation` that returns the board, its owner's
`board_users` row and the five columns as one `Ecto.Multi`, with no broadcast
and no telemetry. `create_ai_optimized_board/3` is changed to use the same
builder, so the column set stays in one place. The import refuses, rather
than falls back, when the destination workspace is refused, and sends the
board and column telemetry after commit.

| | AI-optimized board |
|---|---|
| Columns | The fixed five: Backlog, Ready, Doing, Review, Done |
| Agents | Agents claim from Ready once a human moves work there |
| Status mapping | Every Jira status maps to one of the five ([§10.3](#103-status-to-column)) |

**Why only AI-optimized boards.** The import exists to bring a team's work to
where agents can do it, and the rewrite ([§6A](#6a-rewrite-or-import-epic-by-epic))
writes tasks for agents to claim. An AI-optimized board is the board Stride's
agent workflow is built around: a fixed Ready column agents claim from, a
Review column for the review gate, and column names whose meaning never has to
be guessed. A custom board copied from a Jira layout would bring four
problems with it:

- **Column meaning is guessed.** `Kanban.Columns.Stage` decides from column
  names whether a column means *not started*, *in progress* or *done*, and
  classifies unknown names by position. A Jira layout of
  `Backlog | Selected for Development | In Progress | Done` would make
  *Selected for Development* an **in progress** column, and every task in it
  would be marked started.
- **Agents may find nothing to claim.** Agents claim only from a column named
  exactly "Ready", which most Jira layouts do not have.
- **Agents cannot reach it.** Board and workspace API tokens reach only
  AI-optimized boards (`KanbanWeb.BoardLive.ApiTokens`), and the rewrite's
  agent needs a token that reaches the destination board ([§16.6](#166-the-rewrite-api)).
- **Each layout needs its own mapping.** Status-to-column mapping, the stage
  warnings and goal placement would all have to handle arbitrary columns.

Fixing the five columns removes all four, so the mapping page has no board
layout to design and every imported status lands in a column whose meaning is
known. The columns of an AI-optimized board cannot be added to or edited
afterwards, so a Jira workflow with more steps than the five columns is
carried by labels instead: a status that is not the column's own name (for
example *QA* in Review) keeps its name as a `jira-status:` label, which the
importer can switch off on the mapping page ([§10.6](#106-labels-and-colours)).

### 7.3 Identifiers

Imported tasks get normal Stride identifiers (`W12`, `D3`, `G2`). They are not
named after the Jira keys, because agents, hooks, dependencies and the API
all rely on the `W`/`D`/`G` prefixes. The Jira key (`PAY-88`) is kept on the
import link and is shown on the task as **Imported from PAY-88**, linking to
the issue. Identifiers are numbered per board, so `W42` exists on every
board; a link to an issue on another destination board names that board too
([§14.1](#141-descriptions)). Searching for a Jira key on the board finds the
task (Phase 2).
Rewritten tasks get normal identifiers too, written at sign-off, and show
**Written from PAY-88, PAY-91** instead ([§6A.7](#6a7-sign-off)); a key search
finds every task written from that issue.

---

## 8. The common item model

The Jira adapter turns each issue into one struct, `Kanban.Imports.Item`.
Mapping, preview and writing only ever see this struct. Keeping Jira's raw
shape inside the adapter is what lets a later Trello or CSV adapter reuse the
whole pipeline.

| Field | Type | Notes |
|---|---|---|
| `external_id` | string | Jira's numeric issue id. Never the key, because keys change when an issue moves project |
| `external_key` | string | `PAY-88` |
| `external_url` | string | `https://<site>/browse/PAY-88` |
| `container_ref` | string | Which chosen project or board it came from |
| `kind` | `:issue` \| `:epic` \| `:subtask` | From the issue type's hierarchy level |
| `source_type` | string | The issue type name |
| `title` | string | `summary` |
| `body` | string | Already converted to Stride text ([Appendix B](#appendix-b-rich-text-conversion-rules)) |
| `status` | `%{id, name, category}` | `category` is `:todo`, `:in_progress`, `:review` or `:done`. `:review` comes from the name rule in [§10.3](#103-status-to-column), which applies only to statuses in Jira's *In Progress* category |
| `resolution` | string or nil | |
| `priority` | `%{id, name, rank}` | `rank` is the priority's place in the site's priority order (0 for none, then 1, 2, … with no upper bound) |
| `estimate` | number or nil | Story points, from whichever custom field the site uses ([§10.5](#105-complexity)) |
| `time_estimate_seconds` | integer or nil | `timeoriginalestimate` |
| `labels` | `[String.t()]` | |
| `components`, `fix_versions` | `[%{name, release_date}]` | |
| `assignee`, `reporter`, `creator` | `%{account_id, name, email}` or nil | `email` is often nil ([§15](#15-people-and-board-membership)) |
| `parent_external_id` | string or nil | The epic or the parent of a sub-task |
| `initiative` | item or nil | For an epic under a type above epic (Jira Premium), that issue, kept whole so it can be stored as unmapped data ([§10.1](#101-type)) |
| `links` | `[%{type, direction, external_id}]` | `type` is `:blocks`, `:duplicates`, `:relates`, `:clones` or the custom link name |
| `created_at`, `updated_at`, `resolved_at` | datetimes | |
| `due_date` | date | |
| `sprint` | `%{name, state, start_date, end_date}` or nil | The issue's current or latest sprint |
| `comments` | `[%{external_id, author, body, created_at, restricted?}]` | |
| `attachments` | `[%{external_id, filename, url, size, mime_type, author, created_at}]` | Metadata only; the files are fetched at import time, never staged ([§14.3](#143-attachments)) |
| `transitions` | `[%{field, from, to, at, actor}]` | From the changelog. The actor is kept in the import link's unmapped changelog, not on Stride's history rows ([§14.4](#144-history)) |
| `restricted?` | boolean | Issue security level set |
| `fields` | map | **Every other field**, keyed by field id, with its name and type. This is what custom field mapping reads ([§11](#11-mapping-additional-fields)) and what unmapped-data preservation stores ([§12](#12-data-that-does-not-map)) |

---

## 9. Standard field mapping

### 9.1 Standard Jira fields

These map without the importer doing anything. Every row can be changed on the
mapping page.

| Jira field | Stride field | Default rule |
|---|---|---|
| `summary` | `title` | Jira caps summaries at 255 characters, which fits Stride's 255-character title |
| `description` (Atlassian document format) | `description` | Converted per [Appendix B](#appendix-b-rich-text-conversion-rules) |
| `issuetype` | `type` (`work` / `defect` / `goal`) | [§10.1](#101-type) |
| `parent` (epic, or the parent of a sub-task) | `parent_id` | [§10.2](#102-hierarchy) |
| `status` (with `statusCategory`) + `resolution` | column + `status` | [§10.3](#103-status-to-column) |
| `priority` | `priority` | [§10.4](#104-priority) |
| Story points (custom field) or `timeoriginalestimate` | `complexity` | [§10.5](#105-complexity) |
| `labels`, `components` | labels | [§10.6](#106-labels-and-colours) |
| `assignee` | `assigned_to_id` | Matched person ([§15](#15-people-and-board-membership)) |
| `reporter` (`creator` as fallback) | `created_by_id` | Matched person; unmatched → empty, name kept on the import link |
| `issuelinks` of type *Blocks* | `dependencies` | [§10.7](#107-dependencies-and-other-relations) |
| Resolution *Duplicate* on a resolved issue | archived `:duplicate` + `duplicate_of_id`, or `:wontdo` | One rule, in [§13.2](#132-what-happens-to-each-kind-of-item). A *duplicates* link on an open issue is a relation ([§10.7](#107-dependencies-and-other-relations)) |
| `comment` | task comments | [§14.2](#142-comments) |
| `created` | `inserted_at` | Kept, so ages stay true. No changeset casts `inserted_at`, so it is set on the struct before the changeset ([§14.6](#146-how-jira-times-are-written)) |
| `resolutiondate` | `completed_at` | Required when status is completed (existing rule). When Jira has none, which happens when an issue reaches Done with no resolution, the time of the last changelog move into a *Done*-category status is used, then `updated`, and the task is listed under *repaired* |
| Changelog: the first move into an *In Progress*-category status | `claimed_at` | On done, in-review and in-progress tasks, so imported work counts in the AI board's cycle and wait times. None when the issue never moved into *In Progress* ([§14.4](#144-history)) |
| `updated` | stored on the import link | Used by re-sync; the task's own `updated_at` is the import time |
| Browse URL | import link | Shown as **Imported from** |

### 9.2 Other Jira fields and their defaults

| Jira field | Default | Can be mapped to |
|---|---|---|
| `components` | Label `component: <name>` | label |
| `fixVersions` | Label `release: <name>` | label, delivery target (on goals). A goal has one target, so an epic with several dated versions gets the earliest unreleased one as its target, and the others as `release:` labels |
| `versions` (affects versions) | Unmapped data | label, description section |
| Sprint (custom field) | Label `sprint: <name>` for active and future sprints; closed sprints kept as unmapped data | label |
| `duedate` | Unmapped data | description section, label |
| `environment` | Description section **Environment** for bugs, otherwise unmapped data | `where_context`, description section |
| Story points | `complexity` and kept as unmapped data | `complexity` |
| `timeoriginalestimate`, `timeestimate`, `timespent`, `worklog` | Unmapped data: the totals, and the worklog entries (author, time, comment) within the 64 KB cap | — ([§12](#12-data-that-does-not-map)) |
| `resolution` | Drives Done vs archived ([§13.2](#132-what-happens-to-each-kind-of-item)) | — |
| `attachment` | Copied as task attachments; files Stride cannot store stay links on the import link ([§14.3](#143-attachments)) | description section (as links) |
| Development info (linked branches, commits, pull requests) | Links on the import link, where the site exposes them | description section |
| `watches`, `votes` | Dropped and counted | — |
| `security` (issue security level) | Issue skipped unless the importer opts in ([§20](#20-security-and-privacy)) | — |
| `rank` | Used to order tasks inside each column | position |
| Every other custom field | Unmapped data, unless the importer maps it ([§11](#11-mapping-additional-fields)) | see [§11.2](#112-what-a-field-can-be-mapped-to) |

### 9.3 Stride fields Jira does not fill

Stride's agent-facing fields have no equivalent in Jira: `key_files`,
`verification_steps`, `testing_strategy`, `patterns_to_follow`, `pitfalls`,
`why`, `what`, `where_context`, `security_considerations`,
`required_capabilities`, `behaviour_test_matrix` and the rest. On a direct
import they are left empty unless the importer maps a custom field to them
([§11](#11-mapping-additional-fields)). A rewrite fills them, which is the
main reason Stride recommends it for not-started work ([§6A](#6a-rewrite-or-import-epic-by-epic)).

That is why imported work lands in **Backlog**, not Ready ([§10.3](#103-status-to-column)):
a task an agent can claim needs this context. After the import the report
offers **Enrich these tasks** for directly imported tasks that have not
started. This is a link to the existing task-enrichment flow
(`stride:task-enricher`), run task by task by a human or an agent before the
work is promoted to Ready. The import does not run enrichment itself.

---

## 10. Value mappings

Every table below is the **default**. The mapping page shows each one as an
editable table of *Jira value → Stride value*, filled in from the values
actually found in the fetched issues, so the importer only sees values that
occur.

### 10.1 Type

| Jira issue type | Stride `type` |
|---|---|
| *Epic* (hierarchy level 1) | `goal` |
| *Bug* | `defect` |
| *Story*, *Task*, *Improvement*, *New Feature*, *Spike*, and any other standard type | `work` |
| *Sub-task* (any sub-task type) | `work`, or `defect` when the type name is a bug type; placed per [§10.2](#102-hierarchy) |
| A custom type | Chosen on the mapping page; `work` until chosen, within the hierarchy rule in [§11.4](#114-validation) |
| A type above epic (Jira Premium levels such as *Initiative*) | Not imported as a task. The whole issue is kept as unmapped data on the import link of each goal under it, and it gets a label on each of those goals. The label keeps the key and cuts the name in the middle to fit 40 characters (`initiative: PLAT-7 Platform rel…`), so two initiatives with the same opening words stay apart |

### 10.2 Hierarchy

Stride has exactly two levels: a goal contains work and defect tasks, and a task
inside a goal has no children (`HierarchyValidations`). Jira goes deeper, so it
is flattened:

| Jira shape | Stride result |
|---|---|
| Epic → story/task/bug | goal → work/defect |
| Epic → story → sub-task | goal → work (story) and work (sub-task), side by side under the goal. The sub-task's description starts with *Part of W14: <story title>*, and the import link records the original parent |
| Story → sub-task, with no epic | Default: story and sub-task are both top-level tasks, and the sub-task starts with *Part of W14*. Option **Stories with sub-tasks become goals**: the story becomes a goal holding its sub-tasks |
| Initiative (Premium) → epics | Initiatives are not imported as tasks; each epic becomes its own goal with an `initiative:` label, and the initiative's data on its import link ([§10.1](#101-type)) |
| Epic whose children land on different destination boards (one board per container, and an epic with children in several projects) | The goal is created on the board holding most of its children; children on other boards lose their parent link, and the report lists them |

The table describes a direct import. A rewritten epic becomes one goal, and
every task the rewrite writes sits directly under it, whatever shape the
issues had in Jira. For a split epic ([§6A.3](#6a3-epics-already-in-progress))
the goal is created by the import with the started work under it, and the
rewritten tasks join it at sign-off. Rewriting never moves a task between
goals.

### 10.3 Status to column

Every destination is an AI-optimized board ([§7.2](#72-ai-optimized-board-or-custom-board)),
so every Jira status maps to one of its five columns. The defaults:

| Jira status | Stride column | Stride `status` | Notes |
|---|---|---|---|
| *To Do* category, status named *Backlog* or in the board's backlog | Backlog | `open` | |
| Any other *To Do* category status (*To Do*, *Selected for Development*, *Open*) | **Backlog** | `open` | Not Ready: see below. Option **Put To Do work in Ready** |
| *In Progress* category | Doing | `in_progress` | [§13](#13-work-already-in-progress) |
| An *In Progress* category status whose name contains the whole word *review*, *QA*, *testing* or *verify* | Review | `in_progress` | Name rule is editable; `needs_review: true`, `review_status: :pending`. The rule never applies to a *To Do* or *Done* status, so *QA Done* stays Done and *Ready for QA* stays in Backlog. The mapping page shows each status's resulting column |
| *Done* category with a "done" resolution (*Done*, *Fixed*, *Resolved*, or none) | Done | `completed` | `completed_at` falls back when Jira has no resolution date ([§9.1](#91-standard-jira-fields)) |
| *Done* category with *Won't Do*, *Won't Fix*, *Cannot Reproduce*, *Declined*, *Cancelled* | Done column, archived | `completed` | [§13.2](#132-what-happens-to-each-kind-of-item) |
| *Done* category with resolution *Duplicate* | Done column, archived `:duplicate` or `:wontdo` | `completed` | [§13.2](#132-what-happens-to-each-kind-of-item). A *duplicates* link on an issue that is not resolved does not archive it |

Every task needs a column (`tasks.column_id` is not null), so an archived
task is written in the Done column, after the live tasks, with `archived_at`
set to its resolution time (with the same fallback as `completed_at`).

**Why To Do work goes to Backlog.** Agents claim the next task from the
column named Ready (`Kanban.Tasks.AgentQueries`). If imported work landed in
Ready, any agent connected to the board could claim a task whose description
was written for a human and that has none of the context in [§9.3](#93-stride-fields-jira-does-not-fill),
the moment the import finished. Backlog matches how Stride already treats new
work: a human reviews it and promotes it.

Goal columns are not mapped. A goal's column follows its children, by the
rule in `Kanban.Tasks.GoalTargetColumn`. The import knows every child's
column before it writes anything, so it computes each goal's column and
position in memory and inserts the goal there, with its own `status` and
`completed_at` taken from Jira. It does not call `Kanban.Tasks.GoalPlacement`,
which would set `completed_at` to the import time for a goal in Done, set a
goal in Doing to `open`, and bump `updated_at` after the import links are
written. An epic with no imported children is placed by its own status, using
the table above.

### 10.4 Priority

| Jira (default priority scheme) | Stride |
|---|---|
| Highest, Blocker | `critical` |
| High, Critical | `high` |
| Medium, Major | `medium` |
| Low, Lowest, Minor, Trivial | `low` |
| No priority | `medium` (Stride's default); the report counts them |
| Any value not listed here | `medium` until the importer chooses; the report counts them |

Jira sites can rename and add priorities, so the list is built from the
site's priority list ([Appendix A](#appendix-a-jira-api-reference)) and every
value found is listed for mapping, in the site's own order.

### 10.5 Complexity

Stride's `complexity` is `small`, `medium` or `large`. Story points live in a
custom field whose id differs per site (often named *Story Points* or *Story
point estimate*); the adapter proposes it from the field catalogue and the
importer confirms it. The default thresholds are editable:

| Jira value | Stride |
|---|---|
| Points below 3, or original estimate below 4 hours | `small` |
| Points from 3 to below 8, or from 4 hours to below 2 days | `medium` |
| Points 8 or more, or 2 days or more | `large` |
| No estimate | `small` (the schema default), counted in the report |
| Epics | `large`, whatever the estimate |

The ranges are half-open, so 6, 7 and fractions such as 2.5 have a row. When
an issue has both, points win over the time estimate. A day is 8 hours unless
the site's time-tracking setting says otherwise.

The raw estimate is always kept as unmapped data, so nothing is lost when the
thresholds are wrong.

### 10.6 Labels and colours

- Labels are board-scoped, so each destination board gets its own copy of the
  labels its tasks use.
- Names longer than 40 characters are shortened. Stride trims label names
  and keeps them unique per board ignoring case, while Jira can hold
  `Backend` and `backend` apart. So labels are merged on the trimmed,
  lowercased and shortened name, the first spelling seen is kept, and every
  merge is listed under *repaired*. Without this, the unique index would roll
  back the whole board.
- **Colour.** Jira labels and components have no colour, so they get gray.
  Labels added by mapping rules get one colour per prefix (`release:` blue,
  `sprint:` teal, `component:` purple), so they are easy to tell apart. The
  importer can change any colour on the mapping page.
- Labels added by mapping rules (`release:`, `sprint:`, `component:`,
  `initiative:`, `jira-status:`, `blocked`, the per-project label) are listed on the mapping
  page with a checkbox each, so a team that does not want them can switch
  them off.

### 10.7 Dependencies and other relations

| Jira link | Stride result |
|---|---|
| A *blocks* B (both imported, both work/defect, same destination board) | `B.dependencies` gains A's identifier |
| Either end is an epic, the other end is not imported, or the ends are on different boards | Not a dependency; kept in unmapped data on both import links as *Blocked by PAY-12 (not imported)* |
| A cycle of *blocks* links | Stride refuses circular dependencies, but its check walks only rows already written, so the result would depend on write order. The import finds cycles in memory on the issue graph before the preview, and in each cycle drops the link from the most recently created issue. The preview and the report name each dropped link |
| *Duplicate* on a resolved issue | [§13.2](#132-what-happens-to-each-kind-of-item) |
| *Duplicate* on an open issue | A relation: unmapped data on both ends, as the row below |
| *Relates*, *Cloners*, and any custom link type | Unmapped data on both ends, with a link to the other issue (or its Stride identifier, if imported) |

**Links to rewritten issues.** A rewritten issue has no task of its own, so a
*blocks* link to or from it is carried in the bundle and resolved at sign-off
through the coverage map: the tasks covering the blocking issue become
dependencies of the tasks covering the blocked one, under the same rules as
the table (same board, no cycles). Inside one epic the agent sets dependencies
itself, as the draft's own index-based dependencies. A link to an epic that is
still `pending` is resolved when that epic is signed off.

**Blocked status.** Stride sets `:blocked` from a task's dependencies in
`Kanban.Tasks.Dependencies.update_task_blocking_status/1`, which broadcasts,
so the import does not call it. It applies the rule in memory, after the
dependencies are resolved, to the tasks it writes as `open`: one with a
dependency that is not completed is written `:blocked`. In-progress and done
tasks keep their status, because the import keeps the state of work under
way.

---

## 11. Mapping additional fields

Teams keep important information in fields of their own: an
*Acceptance Criteria* text field, a *Customer* select list, a *Team* field.
This section is how the importer puts those into Stride fields instead of
leaving them as unmapped data.

### 11.1 Discovery

After the fetch, the mapping page lists **every field that has a value on at
least one fetched issue**, with:

- its name and id (`Acceptance Criteria` · `customfield_10042`),
- its type (text, rich text, number, date, single select, multi select,
  cascading select, user, version, URL, checkbox),
- how many issues have a value,
- three sample values.

Field names and types come from `GET /rest/api/3/field`. Two custom fields with
the same name, which Jira allows, are shown with their ids so the importer can
tell them apart.

### 11.2 What a field can be mapped to

| Stride target | Accepts | Transform options |
|---|---|---|
| `acceptance_criteria` | text, rich text | Rich text becomes one criterion per list item or line |
| `why`, `what`, `where_context`, `patterns_to_follow`, `database_changes`, `validation_rules`, `logging_requirements`, `error_user_message`, `error_on_failure` | text, rich text | Replace, or append to what another mapping wrote |
| `pitfalls`, `out_of_scope`, `technology_requirements`, `security_considerations` | text, rich text, multi select, checkbox | Split into list items by line, list item or selected option. `security_considerations` entries are refused over 255 characters each (existing column limit), and a credential-shaped entry is a changeset error, not a warning ([§11.4](#114-validation)) |
| `complexity` | number, single select | Thresholds (numbers) or value table (selects) |
| `priority` | single select | Value table |
| `type` | single select | Value table |
| `required_capabilities` | multi select | Value table into the allowed capability list; unknown values dropped and counted |
| Labels | single select, multi select, cascading select, checkbox, version, user | One label per value, with an optional prefix (`customer: Acme`) |
| Description section | anything | Appended to the description under a heading named after the field |
| `technical_details` key | anything | Stored as a key in the task's `technical_details` JSON object, value kept as typed JSON |
| Delivery target (goals only) | version, date | A version with a release date, or a date field on the epic, becomes a target named after it |
| Do not import | anything | Not copied to the task, still kept as unmapped data ([§12](#12-data-that-does-not-map)) |

Some task fields are locked on free boards (`telemetry_event`, at most 255
characters, and `metrics_to_track`, per `Kanban.Plans.locked_task_fields/0`). An import's
destination is always in an Organization workspace when plans are enforced
([§19](#19-permissions-and-plans)), so they are always offered as targets.

### 11.3 Section extraction

Many teams write *Acceptance criteria* as a heading inside the description
rather than in a field. The mapping page offers **section rules**: *move the
description section headed `Acceptance criteria` (or `AC`, `Definition of
done`) into `acceptance_criteria`*. The same works for `Out of scope` and
`Steps to reproduce`. A section rule removes the section from the description
only when it moved it. The preview shows the result on real issues before
anything is written.

### 11.4 Validation

- A mapping whose field type cannot fill the target (a date into `pitfalls`)
  cannot be saved, and the page says why.
- Two mappings writing the same single-value target are refused unless one is
  set to **append**.
- Every value is checked by the task changeset during preview, so a value too
  long for its column shows up as a preview warning on the issue it belongs
  to, not as a failed import.
- **A mapped value that fails its changeset is not written to the field.** It
  is kept in unmapped data and listed under *repaired*, with the field and the
  reason. A value is shortened only where this document says so (comments,
  label names), and then with a marker.
- **A credential-shaped `security_considerations` entry** is a changeset error
  (`Task.MapFieldValidations` refuses it), and it must not be kept anywhere.
  The preview shows it as a blocking error on that issue, naming the issue and
  field but never the value, until it is fixed in Jira or the mapping leaves
  the field out.
- **Type mapping keeps the two levels.** `goal` can be chosen only for
  hierarchy-level-1 types (epics) or for issues that have no parent, and a
  level-1 type can map only to `goal`. A mapping that breaks this cannot be
  saved: a goal with a parent is refused by `HierarchyValidations`, and an epic
  mapped to `work` would leave a work task with children, which nothing would
  refuse.

### 11.5 Mapping presets

The mapping is saved with the run as versioned JSON (an embedded schema,
`Kanban.Imports.Mapping`, `version: 1`). The importer can **save it as a
preset** for the Organization, such as "Our Jira mapping", and apply it to the
next run from the same site. This matters for teams that move one project at a
time. A preset never holds credentials.

---

## 12. Data that does not map

Nothing is dropped silently. Every Jira datum ends in one of four places, and
the preview tells the importer which place each kind ends in.

| Where it goes | What it holds | Where people see it |
|---|---|---|
| **Mapped** into a Stride field | Everything in [§9](#9-standard-field-mapping) and [§11](#11-mapping-additional-fields) | The task |
| **Kept as unmapped data** on the import link | Every remaining field value, link, link to a file that was not copied, worklog totals and entries, sprint history, original parent, the full changelog with each change's Jira actor ([§14.4](#144-history)), mapped values a changeset refused ([§11.4](#114-validation)), and, on a goal, the initiative above its epic | The **Imported from** panel on the task: collapsed by default, a readable list, plus **Download Jira data** (JSON) |
| **Counted, not kept** | Votes, watchers, rank values | The report shows how many of each were left out |
| **Skipped**, with a reason | Restricted issues and restricted comments, and files referenced only from them ([§20](#20-security-and-privacy)), issues beyond the limits ([§6.3](#63-size-limits)), comments that are blank after conversion | The report, issue by issue |

**Why not put unmapped data in the description or in `technical_details`?**
The description is what people and agents read first, so a long tail of
*Customer: Acme / Sprint 12 / Story points: 5* lines would push the actual
description down. `technical_details` is handed to agents as implementation
context, so Jira metadata there would be noise in every agent's prompt. The
import link keeps the data next to the task without putting it in front of
anyone. An importer who wants a field in the description maps it to a
**description section** explicitly.

Unmapped data per issue is capped at 64 KB. Cutting serialised JSON at a byte
offset would leave invalid JSON, so the import drops whole entries instead:
the oldest changelog and worklog entries first, then the largest field
values, until the rest fits. The result is valid JSON, flagged as *truncated*
in the panel, with a list of what was dropped. Jira may not be there after the
team finishes the move, so the run page offers org-admins **Download all Jira
data**: the full staged items of the imported issues as JSON, without the
restricted content that was skipped, while staging is kept. Finish migration
reminds the importer of it.

**Who can read it.** Unmapped data follows the task's visibility: anyone who
can see the task can open the panel. Because that includes read-only members
and guests, people values in it keep the display name only; Jira email
addresses and account ids are removed before it is stored. Unmapped data is
not returned by the task API or the MCP tools in Phase 1, so it does not
reach agents.

**Rewritten issues.** A rewritten issue has no task of its own, so its data
cannot live on an import link. The whole item, mapped fields and the rest,
stays in the rewrite's bundle on `import_rewrites`, with the same 64 KB cap per
issue, cut by whole entries in the same way. Each task written from it gets a **source link** per issue it covers,
and its **Written from** panel lists those issues: key, title, status,
assignee, the lines and paragraphs of each issue the task cites, and
**Download Jira data** for each one, with Jira email addresses and account ids
removed as above. So nothing from a rewritten issue is dropped either. It is one
click away from every task written from it, and an issue the rewrite left out
is in the coverage report with its reason.

---

## 13. Work already in progress

### 13.1 The principles

1. **Work keeps its place.** Something being worked on stays on the board in a
   column that means "in progress", with the same person on it.
2. **Imported work is never claimable by surprise.** Agents claim only from
   Ready, and nothing is imported into Ready unless the importer asks for it.
   Imported in-progress work has an owner, not an agent claim: it gets a
   `claimed_at` from Jira for the metrics, but never a `claim_expires_at`, and
   the claim queries look only at `claim_expires_at`, so no agent can take it
   over and no expiry job moves it. Its assignee can still complete it or
   unclaim it, in person or through an agent using the assignee's own token,
   as with any task assigned to them; unclaiming puts it in Ready.
3. **Nobody is notified by the import.** No assignment emails, no mention
   notifications, no review requests, no webhooks, no Slack messages. The
   board reloads once when the import finishes. One later email does mention
   imported work: imported Review tasks are in the review queue (`/review`),
   so the weekly digest lists them. Their `review_requested_at` is the import
   time, so the queue and the digest do not show them as weeks overdue; the
   time they entered review in Jira is kept in their history.
4. **Jira keeps working until the team switches.** Re-sync brings changes
   across; the team chooses when to stop.

### 13.2 What happens to each kind of item

| Jira state | Column | Task fields | Notes |
|---|---|---|---|
| To Do, in an epic being rewritten | No task of its own; covered by the rewrite's tasks, written to Backlog at sign-off | `status: :open` on the rewritten tasks | [§6A](#6a-rewrite-or-import-epic-by-epic). Put To Do work in Ready does not apply to rewritten tasks |
| To Do, imported directly | Backlog (Ready if the importer opts in) | `status: :open` | |
| In Progress, assignee matched | Doing | `status: :in_progress`, `assigned_to_id` set, `claimed_at` = its first move into an *In Progress* status (from the changelog), **no** `claim_expires_at` | A claim is an agent's 60-minute lease; a person working on something holds an assignment, not a claim. `claimed_at` without `claim_expires_at` is valid, no claim query sees it, and no expiry job will move it |
| In Progress, assignee not matched | Doing | `status: :in_progress`, unassigned, `claimed_at` as above | Listed in the report under **In progress with nobody on it**, so someone picks it up |
| In Progress, unassigned in Jira | Doing | as above | Same report section |
| In review | Review | `status: :in_progress`, `needs_review: true`, `review_status: :pending`, `claimed_at` as above, `review_requested_at` = the import time | No review-requested notification is sent. The time it entered review in Jira is kept in its history ([§13.1](#131-the-principles)) |
| Done with a "done" resolution | Done (or archived, per [§6.2](#62-completed-and-cancelled-work)) | `status: :completed`, `completed_at` = `resolutiondate` (with the fallback in [§9.1](#91-standard-jira-fields)), `claimed_at` as above or none if it never moved into *In Progress*, `completed_by_id` = matched assignee | |
| Won't Do, Won't Fix, Declined, Cannot Reproduce | Done column, archived `:wontdo` | `archive_note` = *Imported: <resolution>* | `archive_note` is required for `:wontdo` (existing rule) |
| Cancelled | Done column, archived `:cancelled` | `archive_note` as above | |
| Resolved as *Duplicate*, original imported **on the same board** | Done column, archived `:duplicate` | `duplicate_of_id` = the imported original | The archive changeset requires `duplicate_of_id` with `:duplicate`, and the original has no id until it is written. So the duplicate is inserted unarchived in the first pass and archived through the archive changeset in the second pass. The preview validates it against the staged original's key |
| Resolved as *Duplicate*, original not imported, or on another board | Done column, archived `:wontdo` | `archive_note` = *Imported: duplicate of PAY-12*, or *Imported: duplicate of PAY-12 (W12 on Payments)* | `duplicate_of_id` on another board is refused by the workspace importer, so a later export would not import again |
| A closed epic with open children | placed by its children | the epic's own `status` | Not archived ([§6.2](#62-completed-and-cancelled-work)) |
| A status named *Blocked*, or a *Flagged* issue | the column of its category | `status` per category | Stride's `:blocked` status is not taken from Jira, because Stride sets it from dependencies ([§10.7](#107-dependencies-and-other-relations)). The blocking issue becomes a dependency where possible, and the label `blocked` is added |

### 13.3 Sprints in flight

Stride has no sprints. The active sprint becomes a label (`sprint: Sprint 14`)
on the issues in it, so the team can filter the board to "what we committed
to" during the move. Future sprints get labels too; closed sprints are kept as
unmapped data only. Teams that plan by release can map a fix version with a
release date to a **delivery target** on the goals instead ([§11.2](#112-what-a-field-can-be-mapped-to)).

### 13.4 Agents on the new board

- A board-scoped agent token cannot reach a board created by the import, but
  a **workspace-scoped** token can (API tokens belong to a board or a
  workspace; only org-admins create workspace tokens, and a workspace token
  names the board on each request). Nothing can be claimed during the import anyway, because the
  board does not exist until its transaction commits and nothing is written to
  Ready by default.
- After the import, an agent can claim only what a human moves into Ready.
  The run report links to the board's Backlog filtered to the imported tasks,
  with a reminder to add the context agents need before moving work to Ready
  ([§9.3](#93-stride-fields-jira-does-not-fill)).
- If the importer turned on **Put To Do work in Ready**, the preview shows a
  warning naming the number of tasks agents will be able to claim the moment
  the import finishes, and saying that their text was written in Jira by
  anyone who could create or comment on an issue there, so no person will
  have read it before an agent acts on it. Re-sync never puts work in Ready,
  whatever this option says ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)).

### 13.5 Re-sync: when the team keeps working in Jira

Most teams cannot stop work for a migration. Re-sync (Phase 3) lets them
import, try Stride, and bring Jira's changes across again until they are
ready to switch.

**Re-sync changes** on an `imported` run:

1. Fetches issues in the run's scope **updated since the last fetch**, using
   the stored credential. `last_fetched_at` is the time the last fetch
   **started**, so an issue updated during a long fetch is not missed. Jira
   reads a JQL date to the minute, in the time zone of the account's profile
   (to be checked, [Appendix A](#appendix-a-jira-api-reference)), so the
   clause is written in that time zone (from `GET /rest/api/3/myself`), one
   day earlier than `last_fetched_at`. An issue whose `updated` equals the
   import link's `source_updated_at` is skipped.
2. For each fetched issue:
   - **New in Jira** → created as in the first import, but always in Backlog,
     whatever the Ready option.
   - **Already imported** → compared **field by field**. The import link keeps
     a snapshot of what Stride last wrote from Jira for each field (a hash of
     the title, the description, the column, the priority, the assignee, the
     label set and each mapped field). `updated_at` is not used: moving one
     card bumps `updated_at` on every card it reshuffles, while a label change
     does not bump it at all. For each field:
     - Stride's value still equals the snapshot → updated from Jira.
     - Stride's value differs and Jira's has not changed → Stride's is kept.
     - Both changed → **not touched**. Listed under **Conflicts**, showing
       both versions side by side, with **Take the Jira version** and **Keep
       Stride's**. Stride's edits are never overwritten without a person
       choosing it.
     New comments are added; existing comments are not edited. The title and
     description of a task that is no longer in Backlog are never updated
     without a person accepting the change, as a conflict, because an agent
     may already act on them. A column change that would land in Ready lands
     in Backlog instead.
   - **Claimed by an agent in Stride** (it has a `claim_expires_at`, which an
     imported task never has) → never touched, whatever changed.
   - **Deleted in Stride** → not created again. Deleting a task nilifies its
     import link's `task_id` and sets `deleted_in_stride_at`, so the link
     survives. The issue is listed under **Deleted in Stride**. The same holds
     for a file removed in Stride.
   - **Moved out of scope or deleted in Jira** → not deleted in Stride;
     listed under **No longer in Jira**. They are found by searching for the
     run's linked keys directly (`key in (…)`, in batches), not by searching
     the scope again, so an issue that only aged out of a date filter is not
     reported.
   - **Attachments** on an imported issue follow the same rule as its other
     fields: a new Jira file is copied, unless the task changed in Stride
     (then it is listed with the conflict). A file removed in Jira is not
     removed in Stride; it is listed under **No longer in Jira**.
   - **Rewritten, and the rewrite still `pending` or `drafted`** → the bundle
     is rebuilt with the new version (the rewrite is `preparing` again while
     new files are copied). A draft written from the old bundle is marked
     *stale*. Because source ids come from the content, only the ids of lines
     that changed are new. The sign-off page shows what changed, and the draft
     can be signed off once every new or changed id is covered or dropped
     ([§6A.7](#6a7-sign-off)), or sent back.
   - **Rewritten and signed off** → the tasks written from it are never
     touched. The issue is listed under **Changed after rewrite**, with the
     change and the tasks that cover it, so a person decides what to do.
   - **New in Jira, in an epic chosen for rewrite** → not started: added to
     the rewrite (a signed-off epic gets a new `pending` rewrite holding just
     the new issues; the unique index covers open rewrites only,
     [§17](#17-database-changes)). Started: imported directly under the
     epic's goal. Each task's **Written from** panel links to the rewrite that
     wrote it.
3. Updates the run's counts and report.

**How it writes.** Re-sync writes to boards people are using, so it works in
short transactions, one issue (or a small chunk) at a time, each taking the
board's column locks before the identifier lock as sign-off does
([§6A.7](#6a7-sign-off)). Files are copied after commit by `AttachmentWorker`,
as in the first import. A board is never locked for the whole re-sync.

Re-sync uses the mapping saved with the run. Changing the mapping between
re-syncs applies only to issues created or updated from then on, and the page
says so.

### 13.6 Cutover and the optional "moved to Stride" marker

**Finish migration** (Phase 3) closes the run, in this order:

1. One last re-sync.
2. The finish rule is checked again, because that re-sync can itself add a
   `pending` rewrite: no rewrite may be `preparing`, `pending` or `drafted`,
   no file copy may be running and no conflict may be open. If the rule no
   longer holds, Finish stops there, says why, and the run stays `imported`.
3. The "moved to Stride" marker, if it was chosen (below). Issues it could not
   mark are listed in the report.
4. The stored credential is deleted, unless another unfinished run uses the
   same connection ([§5.3](#53-where-credentials-live-and-for-how-long)).
5. Re-sync and undo are disabled, and the run becomes read-only history.

Before Finish, the run page reminds the importer that **Download all Jira
data** goes when staging is purged ([§12](#12-data-that-does-not-map)).

Optionally (off by default, needs a token that can edit issues, Phase 3),
Finish migration can mark Jira: add a comment *Moved to Stride: <link>* and the
label `moved-to-stride` to every imported open issue. This is the only write
Stride ever makes to Jira. It is a separate checkbox with its own
explanation, because it needs write access and it changes the team's other
tool. It runs before the credential is deleted, because it needs it.

### 13.7 Undo

**Undo import** is offered to org-admins while the run is `imported` and no
re-sync conflict is pending. Who may undo does not depend on who owns the
boards now: board ownership can be handed on after an import, and
`Boards.delete_board` refuses anyone but the owner, so undo has its own check
([§19](#19-permissions-and-plans)). In Phase 1, which has no Finish, undo stays
offered for as long as the run exists, and the confirmation below is what
guards it. Undo first cancels the run's queued and running jobs (import,
retry, re-sync, file copies) and takes the run's status guard
([§4](#4-the-import-at-a-glance)).

Because a run creates new boards, undo deletes those boards and everything on
them, after a confirmation that names the boards and the number of tasks.
Deleting a board also deletes its API tokens, webhook endpoints, labels,
memberships and every file on it. If anything has changed in Stride on those
boards since the import, the confirmation lists it and asks the importer to
type the board name: tasks added, tasks edited or moved (by the field
snapshot), comments, files uploaded in Stride, agent completions, API tokens,
webhook endpoints and members added. After **Finish migration**, undo is no
longer offered; the boards are ordinary boards.

**An import into an existing board** (Phase 3) is undone differently: the
board is never deleted. Undo deletes only the tasks this run linked (an
`import_task_links` or `import_source_links` row with this run's id), with
their comments, history and files, and the labels the run created that no
other task uses. The run records which boards it created and which it wrote
into (`import_run_boards.created`), so undo knows which rule applies.

Signed-off rewrites are on those boards, so undo removes them with
everything else. Copied attachments go with their tasks: the attachments
table's delete trigger queues every blob for the cleanup worker, so undo needs
no file code of its own. Undo is not needed to throw away a rewrite before sign-off:
**Send back** or **Import directly instead** does that ([§6A.7](#6a7-sign-off)).

---

## 14. Text, comments, attachments, history and dates

### 14.1 Descriptions

Stride shows descriptions as plain text with line breaks kept. Jira's
Atlassian document format is converted to readable Markdown-flavoured text
([Appendix B](#appendix-b-rich-text-conversion-rules)), so lists, headings,
code, tables and links stay readable as text today and render properly if
Stride later renders Markdown.

- Mentions become `@Display Name` text. They are **not** turned into Stride
  mentions, which would notify people.
- Inline images become a line naming the file: *[image: screenshot.png] (attached)*
  when the file was copied ([§14.3](#143-attachments)), or
  *[image: screenshot.png](Jira URL)* when it was not. The Jira link needs a
  Jira login to open.
- Links to other imported issues (a smart link, a browse URL, or a bare
  `PAY-123` key) are rewritten to the Stride identifier with the original key
  in brackets: `W42 (PAY-123)`. Identifiers are numbered per board, so this is
  done only when the target is on the same board. A target on another
  destination board is written `W42 on Payments (PAY-123)`, so it never names
  a different task on the reader's own board.

### 14.2 Comments

| Rule | Detail |
|---|---|
| Order | Oldest first, with the Jira `created` time kept as the comment's time ([§14.6](#146-how-jira-times-are-written)) |
| Author matched | Comment authored by that Stride user |
| Author not matched | No author; the comment starts with *Originally by Jane Doe on 3 Mar 2026:* |
| Automation and apps (Jira Automation, the GitHub app) | Kept with *Originally by <app name>*; option **Skip automated comments** |
| Restricted comments (visible only to a group or project role) and Jira Service Management internal notes | **Skipped** and counted ([§20](#20-security-and-privacy)), and so is a file referenced only from them |
| Over 10,000 characters | Shortened so that the *Originally by* prefix, the text and *(shortened on import, full text in Jira)* together fit the 10,000-character cap; listed under *repaired* |
| Blank after conversion (for example a comment holding only a macro) | **Skipped** and counted under *empty after conversion*, because the comment changeset refuses blank text |
| Edited in Jira | The current text; `edited_at` not set |
| `mentioned_user_ids` | Left empty, so no mention notification is ever sent |
| Comments on a rewritten issue | Not copied as task comments. They are in the bundle, so the agent writes from them, and in the **Written from** panel ([§12](#12-data-that-does-not-map)) |

### 14.3 Attachments

Task attachments ship before this import ([Task Attachments](ATTACHMENTS-DESIGN.md)),
so Jira attachments are **copied into Stride** as task attachments, not just
linked. Every file goes through `Kanban.Attachments`, which stays the only
place that stores files, checks types and enforces limits and the plan.

**What is copied.** A Jira attachment is copied when all of these hold, and is
otherwise kept as a link on the import link, with the reason:

| Rule | From | When it fails |
|---|---|---|
| The destination board can hold attachments | The attachments plan gate (`:attachments` in `Kanban.Plans`) | Always true when plans are enforced, because an import's boards are always Organization boards ([§19](#19-permissions-and-plans)), and always true while they are not. It can fail only if a self-hosted operator turns plan enforcement on while files are still being copied to a personal workspace; the rest then stay links, reason *plan* |
| The type is on the allow-list (PNG, JPEG, GIF, WebP, PDF, plain text, Markdown, CSV, JSON) and the first bytes agree with it | `TaskAttachment.create_changeset/3` | Link, reason *type not stored* (a `.zip`, `.docx`, `.svg`, `.mp4` and the like) or *type mismatch* |
| At least 1 byte, and a file name that is still usable after sanitising (not empty, `.` or `..`) | `TaskAttachment.create_changeset/3` | Link, reason *empty* or *bad name* |
| At most the per-file limit (25 MiB by default) | `Limits.max_file_bytes/0` | Link, reason *too large* |
| At most the per-task limit (20 files by default) | `Limits.max_files_per_task/0` | The oldest are copied up to the limit; the rest stay links, reason *too many files* |
| The quota has room (`Limits.organization_quota_bytes/0`, 10 GiB by default, for the Organization; for the board in a personal workspace while plans are not enforced) | The quota | Copying stops at the quota; the rest stay links, reason *quota* |
| The file is referenced from a comment that was kept, or from no comment at all | [§20](#20-security-and-privacy) | Not copied, reason *restricted*, and counted under **Skipped** |

The preview shows, per board, how many files and bytes will be copied, how
many will stay links and why, and how much of the quota the import will use.
The importer can choose **Copy attachments** (the default where the board
allows it) or **Link to Jira only**.

**How files are copied.** Files are never staged and never held in memory:

- After a board's transaction commits, `AttachmentWorker` jobs (queue
  `imports`, one per batch of 50 files) download each file from the
  connection's own Jira site with
  `GET /rest/api/3/attachment/content/{id}?redirect=false`. Each request runs
  `UrlGuard.check/2` again and connects through the pinned request
  ([§20](#20-security-and-privacy)), with Req's `redirect: false`, and any
  redirect is treated as an error. The body streams to a temp file and is
  refused if it grows past the size Jira reported or past the per-file limit.
- Before downloading, the worker looks for the file's `import_attachment_links`
  row, and skips the file when it is there.
- `Kanban.Attachments.import_attachment/4`, a function the import adds to the
  attachments context, stores it. It runs the same changeset, magic-byte check,
  limits, quota lock and pending-tombstone protocol as `create_attachment/4`,
  but sets `uploaded_by_id` to the matched Jira author ([§15](#15-people-and-board-membership))
  instead of the importer, and sends no per-file broadcast. `task_attachments`
  has no upload-time column, so the Jira upload time goes in `inserted_at`
  ([§14.6](#146-how-jira-times-are-written)). One board reload is sent when a board's files are done. It emits
  the attachments context's own `uploaded` and `upload_refused` events with
  `source` set to `import`, so attachment metrics count every stored file.
- In the same transaction as the attachment row, `import_attachment/4` writes
  the file's `import_attachment_links` row, unique on the board, the site, the
  Jira attachment id and the task, so a retried job, a re-sync or a retried
  sign-off copy can never store a file twice on one task.
- A file that fails (Jira error, storage error) is retried by the job, then
  left as a link and listed in the report with **Retry failed files**.

Copying runs while the run is `imported`. The boards are usable as soon as
their transaction commits, and files appear as they arrive; the run page shows
the progress, and **Finish migration** waits until copying is done.

**Files embedded in descriptions and comments.** Jira attachments belong to the
issue, and descriptions and comments embed them as media nodes. A media node is
matched to an issue attachment by file name, where that name is unique on the
issue. A matched file embedded in exactly one comment is attached to that
comment (`comment_id`); every other file is attached to the task, except a
file whose only references are in skipped comments, which is not copied. The text line
becomes *[image: screenshot.png] (attached)*, and keeps the Jira URL only when
the file was not copied ([§14.1](#141-descriptions)).

Media nodes may carry a Media Services id and no file name at all. If Jira
returns them that way, name matching has nothing to match. So how Jira links a
media node to an attachment is a Phase 1 spike that must be answered before
the matching is built ([Appendix A](#appendix-a-jira-api-reference)). Until
then the fallbacks are: the file name, then the node's `alt` text, and
otherwise the line *[image] (attached)* with the file attached to the task.
Unmatched nodes are counted in the report.

**Linked pull requests.** Linked branches and pull requests from Jira's
development panel, where the site exposes them, are not files. They are listed
on the import link under **Linked pull requests**, as before.

**Rewritten issues.** Their files are handed to the agent and copied onto the
tasks written from them at sign-off ([§6A.5](#6a5-how-a-rewrite-runs),
[§6A.7](#6a7-sign-off)).

### 14.4 History

Stride's task history records creation, moves between columns, priority
changes and assignment changes. It has no actor column, and a move or
priority row refuses user fields. The import writes history rows as Stride
writes them today, with no actor, and keeps the Jira actor of each change in
the import link's unmapped changelog ([§12](#12-data-that-does-not-map)). It
reads the Jira changelog and writes:

- a `:creation` entry at the Jira creation time,
- a `:move` entry for each status change **that crosses a Stride column**,
  using the mapped columns, at the Jira time,
- `:priority_change` entries, with the mapped Stride priorities, for each
  change whose old and new values map to **different** Stride priorities
  (Low to Lowest is `low` to `low`, so it is not written),
- `:assignment` entries, with the matched people.

Status changes inside one Stride column (two Jira statuses that both map to
Doing) are not written. The full changelog is kept as unmapped data. Every
row's time is the Jira time ([§14.6](#146-how-jira-times-are-written)).

**Metrics.** On an AI-optimized board, cycle time is `completed_at` minus
`claimed_at`, and backlog wait runs from creation to `claimed_at`; tasks with
no `claimed_at` are left out, and history rows are not read
(`Kanban.Metrics.TaskQueries`). So the import sets `claimed_at` on done and
in-progress tasks from the issue's first move into an *In Progress*-category
status in the changelog ([§13.2](#132-what-happens-to-each-kind-of-item)).
An issue that never moved into *In Progress* gets none and is left out of
those two metrics, as a Stride task that was never claimed would be. Imported
work therefore counts in the AI board's cycle and wait times, and the history
rows keep the task's own history panel true.

Rewritten tasks are new work, so their history starts at sign-off with a
`:creation` entry, with no actor, like every creation entry. A rewritten
issue's changelog stays in the bundle. Since the issues were not started, no
cycle time is lost.

**Exclude imported history** (Phase 2) is a checkbox on the metrics pages,
so a team can measure its Stride period alone. It excludes **tasks that have
an import link** (`import_task_links`), whatever happened to them since,
because the AI metrics read task fields, not history rows, and a history row
cannot tell an imported move from one made in Stride. Tasks written by a
rewrite have no import link and are not excluded: they are Stride work.
Imported history counts by default ([§24](#24-decisions-needed), decision 7).

### 14.5 Dates and time zones

Jira timestamps are stored in UTC as Stride does everywhere. Jira dates
without a time (`duedate`, version release dates) are kept as dates.

Stride tasks have **no due date**. Due dates are unmapped data by default, and
can be mapped to a label or a description section. On epics they can become a
delivery target. Delivery targets are the closest Stride concept, but they
belong to goals only (`validate_target_requires_goal_type`).

### 14.6 How Jira times are written

No changeset in Stride casts `inserted_at`: `Task.changeset`,
`TaskComment.changeset`, `TaskHistory.changeset` and
`TaskAttachment.create_changeset/3` all leave it to Ecto, which fills in the
current time. A Jira time passed in the attributes would be dropped without a
word. So the import puts each Jira time on the struct **before** the
changeset (`%Task{inserted_at: created}`), and Ecto keeps a timestamp that is
already set. Rows written with `Repo.insert_all` carry their timestamps
explicitly. This applies to tasks (Jira `created`), comments (their
`created`), history rows (the changelog time) and attachments (the Jira upload
time). A test asserts that each of the four survives the write.

---

## 15. People and board membership

### 15.1 Matching

1. Collect every person the issues refer to (assignee, reporter, comment
   author, changelog actor), with their Jira account id, display name and email
   if Jira returns one.
2. Match by email, case-insensitive, to a Stride user who is **enabled** and
   **a member of the Organization**. This is the workspace importer's rule
   (`Kanban.Workspaces.Export.Importer.Users`), which never gives board access
   to someone outside the importing Organization. **In a personal workspace**
   (possible only while plans are not enforced) the only person matched
   automatically is the importer. Matching every other Jira email against all
   Stride accounts would let a crafted Jira site (or a self-hosted one) find
   out which addresses have accounts, add people to the importer's board
   without their consent, and attribute work to them. Everyone else there is
   left unassigned or invited. No row is ever attributed to someone outside
   the destination's members, whatever the workspace.
3. The mapping page lists every person with their match, and lets the importer:
   - pick a Stride user by hand (search limited to the Organization or, for a
     personal workspace, the importer),
   - choose **Invite** for an unmatched email. On an Organization board, board
     invitations do not exist on their own: Invite sends a **workspace
     invitation** to the destination workspace (`Kanban.Workspaces.Invitations`,
     sent by the org-admin running the import) **after** the import, with the
     board grant, so the invitation is about a board that exists. Accepting it
     gives the person an Organization seat, as a guest, and the board access
     follows. The mapping page says so beside each Invite, and treats the
     Jira-supplied address as unverified: the invitation goes to that mailbox,
     and whoever holds it can accept. Invitations are limited to 20 an hour
     per inviter; those past the limit are queued and sent as the limit
     allows, and the report lists any still waiting,
   - choose **Leave unassigned**.
4. Every matched person who appears as an assignee is added to the destination
   board with **modify** access. People who appear only as comment authors or
   changelog actors are not added; their names show on the issues. People
   assigned only to rewritten issues are not added by the import, because
   rewritten tasks are written unassigned. The sign-off page lists them, and
   assigning one of them a task there adds them to the board ([§6A.7](#6a7-sign-off)).
5. **Every board membership the import writes** (at import, re-sync and
   sign-off) calls `Kanban.Boards.OrgBoardMembers.lock_and_check/3` inside the
   board's transaction, which locks the Organization row and then the board
   row and checks membership. Each match is also checked again at write time
   (enabled, still a member), because matches are chosen on the mapping page,
   possibly days earlier. A person who fails the check is not added, their
   tasks are written unassigned, and the report lists them under **not
   added**.

**Jira often hides email addresses.** Atlassian returns `emailAddress` only
when the user's profile visibility allows it, so many Jira imports will have
few email matches. The mapping page makes manual matching quick:

- it lists the people by how many issues they are on, most first,
- it suggests a match by display name,
- it applies a saved preset's people matches (by Jira account id) to later
  runs from the same site.

Jira app and automation accounts (`accountType` other than `atlassian`) are
never matched to people. Phase 1 accepts only `*.atlassian.net` sites
([§5.1](#51-jira-cloud)), so the email addresses come from Atlassian. A Data
Center site's addresses (Phase 4) are never treated as verified.

### 15.2 The importer

The importer, an org-admin in an Organization workspace, becomes the owner of
every board the run creates. An issue with
no matched reporter gets no `created_by_id`, not the importer's: the task
history should not claim the importer wrote work they did not write.

### 15.3 Free-board member cap

Does not apply to imports. On a free board, with plans enforced, a board holds
at most three human members (`Kanban.Plans.free_board_member_cap/0`), but an
import's boards are always in an Organization workspace when plans are
enforced, and an Organization workspace has no cap ([§19](#19-permissions-and-plans)).
While plans are not enforced there is no cap either. The preview still shows
how many people each board will gain. The report therefore has no member-cap
section.

---

## 16. Architecture

### 16.1 Modules

```text
lib/kanban/imports.ex                      Public context: runs, connections, presets
lib/kanban/imports/
  policy.ex                                Who may act: enabled org-admins, read at call time (§19)
  queries.ex                               Named-column queries; the credential is loaded only here (§5.3)
  connection.ex                            Schema: import_connections
  run.ex                                   Schema + state machine: import_runs (§4)
  run_board.ex                             Schema: import_run_boards, one row per board a run writes (§16.4)
  staged_item.ex                           Schema: import_staged_items
  task_link.ex                             Schema: import_task_links
  mapping_preset.ex                        Schema: import_mapping_presets
  item.ex                                  The common item struct (§8)
  mapping.ex                               Embedded schema, versioned mapping JSON (§11.5)
  mapping/defaults.ex                      Default mapping from the fetched issues (§9, §10)
  mapping/apply.ex                         Item + mapping → task attrs, labels, links, warnings
  mapping/graph.ex                         Dependency cycles, duplicates and goal columns, in memory (§10)
  planner.ex                               Builds the preview: counts, samples, warnings (§18)
  writer.ex                                Writes one destination board in one transaction
  people.ex                                Person collection and matching (§15)
  resync.ex                                Re-sync and conflict detection (§13.5)
  undo.ex                                  Undo (§13.7)
  rewrite.ex                               Schema + state machine: import_rewrites (§6A)
  source_link.ex                           Schema: import_source_links (§12)
  attachment_link.ex                       Schema: import_attachment_links (§14.3)
  rewrite_file.ex                          Schema: import_rewrite_files (§6A.5)
  attachments.ex                           Which files to copy, and why the rest stay links (§14.3)
  rewrite/recommend.ex                     Per-epic path and quality signals (§6A.2)
  rewrite/bundle.ex                        Builds, serialises and hashes the epic bundle (§6A.5)
  rewrite/source_ids.ex                    Content-derived source ids for lines and paragraphs (§6A.5)
  rewrite/draft.ex                         Validates a submitted draft without inserting, dependencies included (§6A.5)
  rewrite/coverage.ex                      The computed half of the coverage report and its warnings (§6A.6)
  rewrite/writer.ex                        Writes a signed-off draft in one transaction (§6A.7)
  report.ex                                The run report (§21)
  text/adf.ex                              Atlassian document format → text (Appendix B)
  text/links.ex                            Rewrites links to imported issues (§14.1)
  source.ex                                The adapter behaviour (§16.2)
  sources/jira_cloud.ex                    Jira Cloud adapter
  sources/jira_cloud/client.ex             REST over Req: UrlGuard and a pinned connection on every request, no redirects
  sources/jira_cloud/fields.ex             Field catalogue, story points, custom field discovery
  sources/jira_cloud/normalize.ex          Jira issue JSON → Kanban.Imports.Item
  workers/fetch_worker.ex                  Oban: fetch into staging
  workers/import_worker.ex                 Oban: write boards
  workers/attachment_worker.ex             Oban: copy files from Jira or from rewrite storage (§14.3)
  workers/resync_worker.ex                 Oban: re-sync
  workers/cleanup_worker.ex                Oban cron: staging purge, credential expiry (§5.3)

lib/kanban/boards/creation.ex              Gains the non-broadcasting AI-optimized board builder (§7.2)
lib/kanban/pinned_http.ex                  The address pinning from Kanban.SSO.pinned_request/1, shared (§20)

lib/kanban_web/live/import_live/
  index.ex                                 /imports — runs list
  new.ex                                   /imports/new — Jira connection
  scope.ex                                 /imports/:id/scope
  paths.ex                                 /imports/:id/paths — rewrite or import, per epic
  mapping.ex                               /imports/:id/mapping (tabbed)
  preview.ex                               /imports/:id/preview
  show.ex                                  /imports/:id — progress, rewrites, report, re-sync, finish, undo
  rewrite.ex                               /imports/:id/rewrites/:rewrite_id — draft, coverage, sign-off
lib/kanban_web/controllers/api/import_rewrite_controller.ex   Bundle and draft endpoints (§16.6)
lib/kanban_web/components/import_components.ex
lib/kanban_web/live/task_live/imported_from_component.ex   The "Imported from" and "Written from" panels (§12)
```

One more module, `lib/kanban/imports/agent_commands.ex`, holds the command
text the run page shows for each runtime ([§16A.3](#16a3-the-variants)), so
the page and the plugins' READMEs are kept in step in one place.

Existing code changes too, without changing any table: `Kanban.Attachments`
gains `import_attachment/4` and `store_rewrite_file`, the blob cleanup
worker's `key_in_use?/1` and `Kanban.Attachments.Usage` learn about
`import_rewrite_files`, the file checks in `TaskAttachment.create_changeset/3`
move into a function both changesets call, `Kanban.Tasks.CredentialShapes`
gains Atlassian token shapes, `Kanban.Plans` gains `:imports` and
`check_workspace/3`, archiving a workspace deletes its import connections, and
the catalog and audit lists gain the events in [§21](#21-telemetry-audit-log-and-the-import-report).

The agent side is not in this repository. It is the `stride-import` plugin
family, with a variant for every agent runtime: a `rewrite-epic` entry point
that fetches the bundle, downloads the source files, dispatches the drafter
and coverage-reviewer agents and submits the result
([§16A](#16a-the-agent-side-plugin-stride-import)).

`Kanban.Imports` is the only module LiveViews call (project rule: no queries in
LiveViews). Every public function takes `current_scope` first.

### 16.2 The source adapter behaviour

Jira is the only adapter this design builds. The behaviour exists so the
pipeline never depends on Jira's raw shape, and so a Trello or CSV adapter
can be added later without touching mapping, preview or writing.

```elixir
defmodule Kanban.Imports.Source do
  @type conn :: Kanban.Imports.Connection.t()
  @type scope :: map()

  @callback test_connection(conn) :: {:ok, %{site: String.t(), account: String.t()}} | {:error, term()}
  @callback list_containers(conn) :: {:ok, [map()]} | {:error, term()}
  @callback list_groupings(conn, container_refs :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback count(conn, scope) :: {:ok, %{total: non_neg_integer(), by_category: map()}} | {:error, term()}
  @callback fetch_page(conn, scope, cursor :: term() | nil) ::
              {:ok, [Kanban.Imports.Item.t()], next_cursor :: term() | nil} | {:error, term()}
  @callback fetch_comments(conn, external_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback field_catalog(conn, scope) :: {:ok, [map()]} | {:error, term()}
  @callback board_layout(conn, container_ref :: String.t()) :: {:ok, [map()]} | {:error, :not_a_board}
end
```

For Jira, `list_containers` returns projects and boards, `list_groupings`
returns epics, and `fetch_page` returns already-normalised items.

### 16.3 Pipeline

**Fetch** (`FetchWorker`, queue `imports`):

- builds one JQL query from the scope ([§6.1](#61-containers-epics-and-filters)),
  then pages through `/rest/api/3/search/jql` with `nextPageToken`, then
  comments and changelog for each issue whose embedded lists were cut short,
- writes each issue to `import_staged_items` as normalised JSON, upserting on
  `(run_id, external_id)` so a retried page never duplicates, with the item's
  `byte_size`, and checks the run's total against the staging limit in the
  same transaction ([§6.3](#63-size-limits)),
- stores the page token on the run after every page, so a crashed or retried
  job resumes where it stopped,
- records `last_fetched_at` as the time the fetch started,
- honours `429` and `Retry-After` by snoozing the job (`{:snooze, seconds}`),
  never by sleeping in the worker,
- updates `import_runs.progress` (`fetched`, `total`) for the progress bar,
  broadcast on `"import_run:#{id}"`.

**Map and preview** (in the LiveView process, reading staging):

- `Mapping.Defaults` proposes a mapping from the staged issues,
- `Mapping.Apply` runs every staged issue through the mapping and the task
  changeset **without inserting**, collecting warnings per issue,
- `Mapping.Graph` finds dependency cycles and the links that will be dropped,
  checks each duplicate's original by its key, and computes each goal's
  column from its children, all in memory, so the preview shows exactly what
  the write will do,
- `Planner` totals the counts and picks samples. For a large run the preview
  is computed in a `Task.Supervisor` child and shown with `assign_async`.

**Import** (`ImportWorker`):

- one Oban job per destination board, each in **one transaction**
  (`timeout: :infinity`, as the workspace importer's): the board lands whole
  or not at all,
- **a retry never writes a second board.** The job is unique on
  `[:run_id, :container_key]` over the waiting states, and its first write in
  the transaction is the `import_run_boards` row, unique on
  `(run_id, container_key)`. A job that finds the row already there (its
  earlier attempt committed, and Oban never heard) does nothing. The job sets
  `max_attempts: 3` and a `timeout/1` well under Lifeline's 60-minute
  `rescue_after`, so Lifeline never starts a second copy of a long write,
- order inside the transaction: the `import_run_boards` row → the board, its
  owner and its five columns (the builder in [§7.2](#72-ai-optimized-board-or-custom-board)) →
  labels → goals (with pre-generated `G` identifiers, in the column computed
  from their children, with their own `status` and `completed_at`) → tasks
  (pre-generated `W`/`D` identifiers, Jira times on the struct
  ([§14.6](#146-how-jira-times-are-written)), inserted with `Repo.insert_all`
  in chunks of 500 after changeset validation) → dependencies (second pass,
  now that every identifier exists) → blocked status ([§10.7](#107-dependencies-and-other-relations))
  → duplicates archived with `duplicate_of_id` (second pass, through the
  archive changeset) → comments → history → board memberships (each through
  `OrgBoardMembers.lock_and_check/3`) → import links, with the field snapshot
  of what was written. `GoalPlacement` is not called,
- no `Broadcaster`, notification, webhook or WIP-limit code runs; one board
  reload broadcast per board after commit, and the board and column
  telemetry after commit,
- after commit, one `AttachmentWorker` job per batch of 50 files copies the
  board's attachments ([§14.3](#143-attachments)). Files are outside the
  transaction because they are network and storage calls; a file that fails
  never rolls back the board,
- a board that fails rolls back alone. The run ends `imported` with the failed
  board listed and a **Retry this board** action, or `failed` if every board
  failed. **Retry this board** reads the staged items, which are kept while
  any board of the run is failed ([§17](#17-database-changes)).

The import writes only the directly imported issues, including the started
work and goals of split epics. In the same transaction it creates one
`import_rewrites` row per epic chosen for rewrite, in `preparing`. After
commit, `AttachmentWorker` copies the rewritten issues' files into
`import_rewrite_files`. Once every file is copied or has failed, the bundle is
serialised, frozen and hashed, so the hash covers the file list too, and the
rewrite becomes `pending`. A rewrite can be started only after that. A later
**Retry** of a failed source file changes nothing in a frozen bundle; the
file is offered at sign-off instead.

**Rewrite** (per epic, outside any job):

- the agent fetches the bundle and submits a draft through the API
  ([§16.6](#166-the-rewrite-api)); `Rewrite.Draft` validates it and
  `Rewrite.Coverage` computes the computed half of the report and its
  warnings, in the request,
- **Sign off** runs `Rewrite.Writer` in one transaction on the destination
  board. It first takes the column locks of every column on the board, then
  the board's identifier lock, the order `GoalCreation` uses
  ([§6A.7](#6a7-sign-off)). Then: the goal (or the existing goal of a split
  epic) → tasks with pre-generated identifiers → the draft's own dependencies
  → dependencies from Jira links ([§10.7](#107-dependencies-and-other-relations))
  → source links → goal placement, under the locks already held, with the same
  "no broadcast, no notification" rules as the import and one board reload
  after commit; then `AttachmentWorker` copies the source files onto the tasks.
  **Import directly instead** takes the same locks in the same order.

**Re-sync** (`ResyncWorker`, Phase 3) fetches into staging with an `updated >=`
clause, then applies [§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)
in short transactions, one issue or small chunk at a time.

**One thing at a time per run.** Import, **Retry this board**, re-sync and
undo never run at the same time for one run. Each moves the run's status with
a compare-and-set update first ([§4](#4-the-import-at-a-glance)), so a second
request finds the run already moving and is refused. `ResyncWorker` is unique
on `[:run_id]` over the waiting states, as the workspace export worker is.
Undo cancels the run's jobs before it deletes anything. The `imports` queue's
concurrency of 2 is per node, so the database guard, not the queue, is what
keeps runs apart.

### 16.4 Idempotency

A board is written once per run and container: the first write in a board's
transaction is its `import_run_boards` row, unique on `(run_id, container_key)`,
and a job that finds the row does nothing ([§16.3](#163-pipeline)). Without it
a retry after a commit Oban never heard about would create a new board, and
the index below, which includes `board_id`, would not see the first one.

`import_task_links` has a unique index on
`(board_id, source, source_site, external_id)`. A re-sync finds the link and
updates the task. A second run of the same project into the same board
(Phase 3) cannot duplicate an issue. A link whose task was deleted in Stride
keeps its row, with `task_id` nil, so the issue is never created again.

A rewrite is written once: sign-off locks the `import_rewrites` row and
moves it to `signed_off` in the same transaction as the tasks, so a double
click or a retried request finds it signed off and writes nothing. A
re-submitted draft replaces the previous one while the rewrite is `drafted`,
and is refused once the rewrite is `signed_off` or `imported_directly`. Files
are idempotent through `import_attachment_links`, unique on
`(board_id, source_site, external_id, task_id)` and written in the same
transaction as the attachment: a retried `AttachmentWorker` job, a re-sync or
a retried sign-off copy finds the row and skips the file.

### 16.5 Long transactions

A 5,000-issue board with comments is tens of thousands of rows, and with
**One board for everything** one board can receive the whole run: 20,000
issues, each with up to 500 comments and its full changelog. A single
transaction of that size is expected to take minutes, which is acceptable for
a one-off write to a board nobody else can see yet. It runs with
`timeout: :infinity`, and the job's own timeout stays under Lifeline's
60-minute `rescue_after` ([§16.3](#163-pipeline)). Phase 1 measures it at
20,000 issues on one board with the most comments allowed. If measurement
shows otherwise, either a per-board issue cap is set below the run cap
([§6.3](#63-size-limits)), or the fallback is built: write the board in chunks
with `board.import_state = :importing` hiding it from every list until the
last chunk commits. That fallback would add a column to `boards`, an existing
table, so it is listed under [§24](#24-decisions-needed) and not built up
front.

### 16.6 The rewrite API

Four endpoints, for the agent running the rewrite. All four take the usual
Bearer token.

**Which token.** The endpoints find the destination board from the rewrite
id, so a workspace token needs no `X-Stride-Board` header, and the new boards
an import creates are reached without minting a token on each. The token must
be a workspace token for the destination workspace or a board token for the
destination board (`rewrite.board_id` equal to the token's board), and the
person who created it must still be an enabled org-admin of the Organization
([§19](#19-permissions-and-plans)), checked on every request. Workspace tokens
are made only by org-admins, so an org-admin's workspace token is the usual
choice. A token that fails any of this gets the same `404` as a rewrite that
does not exist. The endpoints need no capability scope: capabilities decide
which tasks a token is offered, not which endpoints it may call. The plugin
reads the token from the `**API Token:**` line of `.stride_auth.md`, never the
`**Local API Token:**` line, as stride-ideation's `lib/read_auth.py` does.

With plans enforced, all four first check the destination board against the
`:imports` plan feature and return `403 plan_required` when it is not in an
Organization workspace ([§19](#19-permissions-and-plans)), before any lookup,
as the attachment download does. All four are rate-limited per token, as the
task attachment download is.

| Endpoint | What it does |
|---|---|
| `GET /api/import_rewrites/:id` | Returns the rewrite's status, the bundle's SHA-256, the destination board, the goal of a split epic and any note from **Send back** |
| `GET /api/import_rewrites/:id/bundle` | Returns the stored bundle bytes exactly as they were hashed, as `application/json`, with the SHA-256 in an `X-Stride-Bundle-SHA256` header. The client hashes the body it received |
| `GET /api/import_rewrites/:id/files/:file_id` | Streams one source file, with the same headers, uniform 404s, plan check and per-token rate limit as the task attachment download (`GET /api/tasks/:id/attachments/:attachment_id`). The server side matches; the plugin still needs its own download script, because the rewrite download rules differ ([§6A.5](#6a5-how-a-rewrite-runs)) |
| `POST /api/import_rewrites/:id/draft` | Takes the draft, the coverage map, the reviewer's findings, the bundle hash, the per-file download results, the agent name and the plugin variant and version that drafted it (`stride-copilot-import 0.1.0`). Validates without writing, returns the coverage report, and moves the rewrite to `drafted`. Every submission is audited with the token's id ([§21.2](#212-audit-log)) |

**The draft's shape** is the goal-and-tasks shape of
[`POST /api/tasks/batch`](../api/post_tasks_batch.md) for one goal, with named
extensions: the coverage map beside it (and the source files only there), and
the per-file download results. For a split epic the goal already exists, so
the draft's goal fields are ignored and only its tasks are taken. The draft is
capped at 2 MiB of JSON and 200 tasks.

**Refusals.** Each has its own status and reason, so the plugin can act on it
([§16A.5](#16a5-the-rewrite-epic-procedure)):

| Status | Reason | When | The plugin |
|---|---|---|---|
| `404` | (none) | No such rewrite, or the token may not use it | Stops this id |
| `403` | `plan_required` | The destination is not in an Organization workspace, with plans enforced | Stops this id, with one line saying so |
| `409` | `not_ready` | The rewrite is `preparing` | Stops this id and says to run it again later |
| `409` | `rewrite_closed` | The rewrite is `signed_off` or `imported_directly` | Stops this id |
| `409` | `run_not_imported` | The run is `resyncing`, `importing`, `finished` or `undone` | Stops this id and says why |
| `409` | `stale_bundle` | The draft names a hash that is not the current bundle's | Fetches again and redrafts, once |
| `413` | `draft_too_large` | Over the size or task cap | Stops this id |
| `422` | `invalid_draft` | A task fails its changeset, a dependency does not resolve or forms a cycle | Prints the errors and stops this id |
| `429` | (none) | The rate limit | Waits for `Retry-After` |

Sign-off is a person's action in the app and has no API endpoint, so an agent
can draft but never write a rewrite to the board. Each endpoint gets an API
reference page under `docs/api/` when they are built.

---

## 16A. The agent-side plugin: stride-import

### 16A.1 Why a new plugin

The rewrite needs an agent-side procedure: fetch a bundle, download its files,
draft a goal and tasks against the team's repository, review the draft, and
submit it. That procedure goes in a new plugin family, `stride-import`, and
not in the Stride workflow plugin, for five reasons:

- **A team uses it once.** The rewrite runs while a team moves off Jira and
  then is never needed again. The Stride workflow plugin is loaded in every
  session, and its size is measured and kept down because every task pays
  for it. An import procedure, two agents and a field-rule reference would
  cost every session for a feature most sessions never use.
- **It reads untrusted input that the workflow plugin never sees.** Jira text
  and files written by people outside the team reach the agent. Keeping that
  procedure in its own plugin keeps its rules, tests and security review in
  one place, and a team that does not import never installs it.
- **It does not claim tasks.** The rewrite has no claim, no hooks, no
  `after_doing` gate and no completion. It must not set off the workflow
  plugin's orchestrator marker, its Stop gate or its sub-skill gate, and in
  its own plugin it cannot.
- **It works next to any Stride plugin.** A team may run the full workflow
  plugin, a lite one (`stride-lite`, `stride-copilot-lite`,
  `stride-opencode-lite`) or neither. The import plugin needs only the
  `**API URL:**` and `**API Token:**` lines of `.stride_auth.md`. On Pi, the
  independent review also needs `stride-pi` with its dispatch extension
  ([§16A.8](#16a8-pi-the-first-companion-package)).
- **It is released on its own.** The drafter and reviewer rules will change
  as Phase 1's hand checks find missed requirements ([§22](#22-testing-strategy)).
  Those changes ship without a workflow plugin release. The one exception is
  a single `stride-pi` release, before the first `stride-pi-import`, that lets
  other packages register agents ([§16A.8](#16a8-pi-the-first-companion-package)).

### 16A.2 What it does and does not do

| It does | It does not |
|---|---|
| Fetch a bundle and check its SHA-256 | Call Jira. Every Jira call is Stride's, on the server |
| Download source files under the attachment download contract | Run, unpack or follow a link in any file |
| Draft one goal and its tasks per epic, with a coverage map | Write anything to a board. There is no sign-off endpoint ([§16.6](#166-the-rewrite-api)) |
| Dispatch an independent coverage review | Edit the draft from the review. The findings go to the person signing |
| Submit the draft, and print the coverage report Stride returns | Claim, complete or enrich tasks, or run Stride hooks |
| Write the draft to a local file first | Commit the draft file, or anything else, to the team's repository |

### 16A.3 The variants

**Every agent runtime Stride supports gets a variant, and all six are part of
Phase 1** ([§23](#23-phased-delivery)). A team cannot pick its agent around
the import, and the run page offers the rewrite to every team, so a runtime
without a variant would leave its teams only the direct import that Stride
advises against for not-started work.

`stride-import` (Claude Code) is the source. The other five are ports of it.
Four are built the way the ideation and security-review families' ports for
the same runtimes are: each follows the source's procedure and agent rules,
and uses its runtime's own file layout, manifest and tool names. **Pi has no
precedent**: there is no Pi port of either family and no Pi marketplace, so
`stride-pi-import` is the first Pi companion package, and its install and
agent dispatch are designed in [§16A.8](#16a8-pi-the-first-companion-package).

Each port carries contract scripts that pin its own rules offline. The
existing families' contract scripts pin a port's own text and never compare
it with the upstream plugin, so they cannot detect drift, and nothing offline
can: the source lives in another repository. Drift is therefore checked at
release time, by a script that fetches the source ([§16A.7](#16a7-testing-and-release)).

| Variant | Runtime | Manifest | Entry point | Agents | Distribution |
|---|---|---|---|---|---|
| `stride-import` | Claude Code | `.claude-plugin/plugin.json` | `/stride-import:rewrite-epic` command | `agents/*.md` | `stride-marketplace` catalog |
| `stride-codex-import` | Codex CLI | `.codex-plugin/plugin.json`, with `AGENTS.md` | `stride-import-rewrite-epic` skill | `agents/*.md` | `stride-codex-marketplace`, vendored |
| `stride-copilot-import` | GitHub Copilot CLI | `plugin.json` at the repository root | `stride-import-rewrite-epic` skill | `agents/*.agent.md` | `stride-copilot-marketplace`, vendored |
| `stride-gemini-import` | Gemini CLI | `gemini-extension.json`, with `GEMINI.md` | `/rewrite-epic` command (`commands/rewrite-epic.toml`) | `agents/*.md` | `stride-gemini-marketplace` catalog |
| `stride-opencode-import` | OpenCode | None: the version is in the CHANGELOG, with `AGENTS.md` | `/rewrite-epic` command | `agents/*.md` | Its own repository, through `install.sh` and `install.ps1` |
| `stride-pi-import` | Pi | `package.json` | `stride-import-rewrite-epic` skill | Agent files it registers with the `stride-pi` subagent-dispatch extension, once that extension's registry accepts other packages' agents, with an inline fallback ([§16A.8](#16a8-pi-the-first-companion-package)) | Its own repository, through `install.sh` |

**The lite variants do not get their own.** `stride-lite`,
`stride-copilot-lite` and `stride-opencode-lite` are lighter builds of the
workflow plugin. The import plugin does not depend on the workflow plugin, so
each runtime's one import variant works next to its full or its lite workflow
plugin.

The run page shows the command for each runtime, with a runtime picker that is
remembered per user. Its text comes from `Kanban.Imports.AgentCommands`
([§16.1](#161-modules)). The plugin repositories are not part of this
repository's checkout (they are gitignored here), so no test here can read
their READMEs. Instead the entry points are pinned in a checked-in fixture in
this repository, a test compares `AgentCommands` with it, and each variant's
`scripts/test-all.sh` compares its README with a copy of the same fixture. A
renamed entry point therefore fails on one side or the other.

### 16A.4 What each variant contains

The Claude Code source's layout. Each port has the same parts in its
runtime's layout (the table above).

```text
stride-import/
  .claude-plugin/plugin.json
  commands/rewrite-epic.md            Entry point: arguments, then hands off to the skill
  skills/rewrite-epic/SKILL.md        The procedure (§16A.5)
  skills/rewrite-epic/draft-contract.md
                                      The goal and task field rules, pinned from the
                                      create-goals skill, and the coverage map schema
  agents/rewrite-drafter.md           Writes the goal, tasks and coverage map for one chunk
  agents/coverage-reviewer.md         Reports on a draft; read-only, never edits
  lib/download-files.sh               Source file download (the contract's rewrite section)
  lib/download-files.ps1              The same, for Windows
  lib/check-draft.sh                  Local shape and size check of a draft before it is sent
  fixtures/                           Bundles, expected coverage and the entry-point fixture
  scripts/check_contract.sh           Pins the procedure's and agents' rules, offline (as the
                                      security-review ports' check_agent_contract.sh does)
  scripts/check_draft_contract.sh     Offline: draft-contract.md still matches the copy and
                                      source commit it records
  scripts/drift-check.sh              At release: fetches create-goals and the source plugin
                                      and fails if the pinned copies are behind
  scripts/test-all.sh                 Runs every offline check
  README.md  CHANGELOG.md  SECURITY.md  LICENSE
```

**The field rules are pinned, not borrowed.** The drafter needs the
`create-goals` field rules: the `"goals"` root key, index dependencies, the
five fields the review queue scores, `verification_steps` as objects, and the
seven-category `behaviour_test_matrix`. It cannot rely on the workflow
plugin's skill. A lite plugin may not carry it, the skill's gate refuses a
call from outside the workflow orchestrator, and its name differs by runtime.
So each variant carries `draft-contract.md`, a copy of those rules with the
source commit it was taken from. `check_draft_contract.sh` checks the copy
offline, and `drift-check.sh` fails at release time when the source has moved
on. The server applies the same rules again when the draft arrives
([§6A.5](#6a5-how-a-rewrite-runs)), so a stale copy can produce a refused
draft but never a bad task.

**The coverage map schema** lives in `draft-contract.md` and matches what
`Rewrite.Coverage` reads:

```json
{
  "tasks": [
    {
      "task_index": 0,
      "covers": [
        {"key": "PAY-88", "ids": ["ac:3f9a1c2b7d0e", "para:91c04e5a2b17", "comment:10231:7be2d4c0a913"]}
      ],
      "files": [17]
    }
  ],
  "dropped": [
    {"key": "PAY-90", "reason": "Duplicate of PAY-88, closed in a comment on 3 Oct"},
    {"key": "PAY-88", "id": "para:0d5e8f1a6c22", "reason": "Background only, no requirement"}
  ],
  "files_not_needed": [{"file_id": 19, "reason": "Earlier version of the design in file 17"}]
}
```

The ids (`ac:…`, `checklist:…`, `para:…`, `comment:<id>:…`) are the source
ids the bundle gives each acceptance-criteria line, checklist item,
description paragraph and comment paragraph, derived from their content
([§6A.5](#6a5-how-a-rewrite-runs)), so the coverage check compares ids, not
text. A sub-task is covered by its own key and ids. `files` lives here and
nowhere else in the draft. When chunks are merged, each `task_index` is
renumbered with the tasks it points to; file ids are Stride's and stay as
they are.

### 16A.5 The rewrite-epic procedure

Arguments: one or more rewrite ids, as the run page lists them. Options:
`--no-files`, which skips the download even when the run allows files, and
`--dry-run`, which stops after writing the local draft file.

1. **Preflight.** Read the `**API URL:**` and `**API Token:**` lines of
   `.stride_auth.md` (never `**Local API Token:**`), with the same parsing as
   stride-ideation's `lib/read_auth.py`. Stop if the file or either line is
   missing. The token is never echoed,
   put on a command line or written to a file: requests send it from an
   environment variable or a header file, as the attachment contract does.
   Say once if `.stride/` is not in `.gitignore`, because draft files quote
   Jira text.
2. **Fetch the bundle.** `GET /api/import_rewrites/:id` gives the status, the
   hash, the board and any send-back note; then
   `GET /api/import_rewrites/:id/bundle` gives the bytes. Hash the body as
   received and compare it with the `X-Stride-Bundle-SHA256` header and the
   status response; stop this id on a mismatch. Every refusal is handled as
   the table in [§16.6](#166-the-rewrite-api) says: a `404`, `409 not_ready`,
   `409 rewrite_closed` or `409 run_not_imported` stops this id and moves to
   the next, and a `403 plan_required` stops it with one line saying the
   destination workspace is not in an Organization. A send-back note goes to
   the drafter.
3. **Download the source files** into `.stride/attachments/rewrite-<id>/`
   with the plugin's own `lib/download-files.sh` (or `.ps1`), under the
   attachment download contract's rewrite section: a manifest, the
   rewrite caps (25 MiB per file, 20 files per Jira issue, 500 MiB per
   rewrite within 600 s), a sha256 check on every file, uniform handling of `404`s, and `Retry-After`
   on `429`. Skipped when the run chose **Rewrite without files** or
   `--no-files` is set; the manifest still lists every file, so the coverage
   map accounts for each one, and records each file's result.
4. **Chunk.** If the bundle is too large for one drafter run, split it by
   story, keeping each story with its sub-tasks, its comments and the files
   it cites. The context-only issues of a split epic go to every chunk.
5. **Draft.** Dispatch `rewrite-drafter` once per chunk, each with a fresh
   context, the chunk, the file directory and read access to the repository.
   Merge the chunks' tasks into one goal, renumber the index dependencies and
   every `task_index` in the coverage maps, and join the coverage maps.
6. **Review.** Dispatch `coverage-reviewer` with the whole bundle and the
   merged draft, in a fresh context that has not seen the drafting. It
   returns findings, never edits.
7. **Write the draft file**: `.stride/rewrites/<id>-<timestamp>.json`, with the
   draft, the coverage map, the findings, the per-file download results, the
   bundle hash and the variant and version. Run `check-draft.sh` on it, which
   also enforces the size cap. Check that no field of the draft contains the
   token. Print a summary: tasks, keys covered, anything uncovered, the
   reviewer's findings. With `--dry-run`, stop here.
8. **Submit** (`POST /api/import_rewrites/:id/draft`). Print the coverage
   report from the response and the link to the rewrite's sign-off page. A
   `409 stale_bundle` means the bundle was rebuilt: fetch it again and go
   back to step 2, once. Every other refusal is handled as the table in
   [§16.6](#166-the-rewrite-api) says.
9. **Clean up.** Remove `.stride/attachments/rewrite-<id>/`. The draft file
   stays, as the record of what was sent, until the team deletes it.

The procedure never asks the user anything between steps: sign-off in the app
is the human gate, and submitting only stores a draft. Each id is handled on
its own, so one failed epic does not stop the rest, and the run ends with one
line per id.

### 16A.6 The agents

| Agent | Tools | Reads | Writes |
|---|---|---|---|
| `rewrite-drafter` | Read, search and list files only: no shell, no network, no file writes | One chunk of the bundle, the downloaded files and the repository | One JSON document: the goal, its tasks and the coverage map, returned to the procedure |
| `coverage-reviewer` | Read and search only | The whole bundle, the merged draft and the files | One JSON document of findings, each with the task index, the Jira key and one of four kinds: *citation not covered*, *unsupported claim*, *later comment not honoured*, *instruction aimed at an agent* ([§6A.6](#6a6-the-second-pass-a-coverage-report)) |

Neither agent calls the Stride API. The procedure makes every request, so the
token is never handed to an agent. The drafter does read the repository,
though, and `.stride_auth.md` sits at its root. So both agents' rules forbid
reading `.stride_auth.md`, `.env` and other credential files, the contract
script pins that rule, the procedure checks the draft for the token before it
submits, and Stride's credential scan on receipt is the last check. Tool
limits are advisory on runtimes that do not enforce them (Codex CLI documents
no tools key for custom agents).

Both agents treat the bundle and every file as **data, not instructions**.
Text in an issue, a comment or a file that tells the agent to do something is
never followed. The drafter leaves it out of the tasks and the reviewer
reports it.

The drafter fills `key_files`, `patterns_to_follow` and `testing_strategy`
from the repository it can read. Where there is no repository, it leaves
`key_files` empty for enrichment, as [§6A.8](#6a8-constraints-and-risks)
allows, and says so in the summary.

**Where a runtime cannot dispatch the agents**, as with Pi without its
subagent-dispatch extension ([§16A.8](#16a8-pi-the-first-companion-package)),
the procedure runs the drafter's instructions
inline. It then runs the reviewer's instructions on the saved draft file and
the bundle only. The findings carry `"independent": false`, and the sign-off
page shows that the review was not done in a separate context. The flag is
the procedure's own statement in every case: Stride shows it, true or false,
as the agent's claim and never relies on it ([§6A.6](#6a6-the-second-pass-a-coverage-report)).

**Copilot CLI** limits an agent prompt to 30,000 characters, so both agent
bodies are kept under that limit in every variant, and the contract script
checks it in `stride-copilot-import`.

### 16A.7 Testing and release

Each variant's `scripts/test-all.sh` runs offline and without a model:

- the contract pins for the procedure's rules (SHA-256 check, token handling,
  no Stride API call from an agent, no agent reading credential files,
  data-not-instructions, the refusal handling of [§16.6](#166-the-rewrite-api));
- `check-draft.sh` against fixture drafts that are valid, missing a field,
  using the wrong root key, carrying an uncovered key, over the size cap, or
  merged from two chunks (every `task_index` renumbered);
- the download script against fixture manifests, with a size cap, a bad
  sha256 and a `404`;
- `check_draft_contract.sh` against the pinned copy and its recorded commit;
- the README's entry point against the variant's copy of the entry-point
  fixture ([§16A.3](#16a3-the-variants)).

None of these can see the source move on, because they never fetch it.
`scripts/drift-check.sh` does: it fetches the source plugin and the
`create-goals` skill at their current commit and fails if the pinned copies
are behind. It runs at release time, and in the source repository's CI.

Each runtime also needs one live check that cannot run in CI: rewriting the
fixture epic with the runtime's own agent, and comparing the coverage with the
expected file. That is a manual Phase 1 exit step for each of the six
([§22](#22-testing-strategy)).

Each variant is versioned and released on its own, through its runtime's
distribution channel as the table in [§16A.3](#16a3-the-variants) shows: a
marketplace catalog for Claude Code, Codex CLI, GitHub Copilot CLI and Gemini
CLI, and its own repository and install script for OpenCode and Pi, which have
no catalog. A change to the
draft API ([§16.6](#166-the-rewrite-api)) is released in the source first and
then in every port before the server starts relying on it. The draft endpoint
records `drafted_with`, so the server can see which versions are still in use
before it drops support for an older draft shape.

### 16A.8 Pi: the first companion package

Pi has no ideation, security-review or exploratory-testing port and no
marketplace. The only Stride package for Pi is the workflow port `stride-pi`.
So `stride-pi-import` is the first Pi package meant to be installed beside
`stride-pi`, and nothing exists to copy for how it installs, how its agents
are dispatched, or what its contract script pins.

**Agent dispatch.** `stride-pi`'s subagent-dispatch extension resolves only
the agents in its registry, `stride-pi/extensions/subagent-dispatch/agents-registry.ts`,
a closed list of five today (`stride-task-explorer`, `stride-task-reviewer`,
`stride-task-decomposer`, `stride-hook-diagnostician`,
`stride-task-enricher`). Its `dispatch_agent` parameter is a union of those
names, and it loads `agents/<name>.md` from its own directory. So it cannot
dispatch `rewrite-drafter` or `coverage-reviewer` as it stands. A
`stride-pi` task, part of Phase 1, makes the registry extensible: another
package can register agent names and the directory their files are in, and
`dispatch_agent` accepts them. That `stride-pi` release ships **before** the
first `stride-pi-import`. `stride-pi-import` registers its two agents with it
when it is present.

**Without it.** A Pi user with no `stride-pi`, with a `stride-pi` older than
that release, or installed with `--no-extensions`, has no dispatch, and the
procedure runs the agents inline with `"independent": false`
([§16A.6](#16a6-the-agents)). On Pi, a review in a separate context exists
only when the extension is present.

**Install.** `stride-pi`'s `install.sh` copies only `SKILL.md` out of each
skill directory. `stride-pi-import` needs more than that: `draft-contract.md`
beside its skill, `lib/` and its agent files. Its own `install.sh` copies the
whole skill directory, `lib/` and `agents/`, and registers the agents.
`stride-pi` has no `install.ps1`, so Pi on Windows is not supported by
`stride-pi-import` in Phase 1 either, and `download-files.ps1` is not shipped
in the Pi variant.

**Contract script.** Besides the pins every variant has
([§16A.7](#16a7-testing-and-release)), the Pi contract script pins that the
two agents are registered under the names the procedure dispatches, and that
the inline fallback sets `"independent": false`.

---

## 17. Database changes

All tables are new. No existing table changes in Phases 1 and 2. That still
holds after the 2026-11-10 review:

- History rows are written with no actor (decision 20), so `task_history`
  gains no column. The Jira actor goes in the import link's unmapped data.
- `claimed_at` (decision 23), `archived_at`, `completed_at` and `inserted_at`
  already exist on `tasks`, and the import only fills them.
- **Exclude imported history** (Phase 2) works through `import_task_links`,
  so nothing marks history rows.
- The `import_rewrite_files` trigger inserts rows into the existing
  `attachment_blob_deletions` table without changing it.
- Only the chunked-write fallback of [§16.5](#165-long-transactions), which is
  not built, would add a column to an existing table (`boards.import_state`).

The existing **code** that changes is listed in [§16.1](#161-modules).

**`import_connections`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `workspace_id` | references `workspaces`, on delete cascade | |
| `created_by_id` | references `users`, on delete nilify | Recorded for the report and audit; it grants nothing ([§19](#19-permissions-and-plans)) |
| `source` | string | `jira_cloud` (later `jira_dc`) |
| `site_url` | string | The Jira site; a single-label `*.atlassian.net` host in Phase 1 |
| `site_name` | string | From test connection |
| `account_label` | string | "Ana Lopez (ana@acme.com)" as Jira reported it |
| `auth_method` | string | `basic_token`, `oauth`, `pat` |
| `credential` | binary (`Kanban.Encryption.EncryptedBinary`, `redact: true`) | Loaded only by the credential query in `Kanban.Imports.Queries`; list queries select named columns |
| `account_email` | string | Basic-auth username |
| `last_verified_at` | utc_datetime | |
| `last_used_at` | utc_datetime | Last fetch, re-sync, board retry or sign-off by any run using it; the 30-day expiry counts from here |
| `credential_deleted_at`, `credential_deleted_reason` | utc_datetime, string | Set when the credential is deleted: `by_user`, `expired`, `last_run_finished` |
| timestamps | | |

**`import_runs`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `workspace_id` | references `workspaces` | |
| `connection_id` | references `import_connections`, on delete nilify | Nil after **Finish migration** |
| `created_by_id` | references `users`, on delete nilify | Recorded only; rights are read from the current role ([§19](#19-permissions-and-plans)) |
| `source` | string | |
| `status` | string | [§4](#4-the-import-at-a-glance) states, moved only by compare-and-set |
| `scope` | jsonb | Projects or boards, epics, filters, JQL, closed-work choice, with relative dates frozen to absolute ones at the first fetch |
| `mapping` | jsonb | `Kanban.Imports.Mapping`, versioned |
| `options` | jsonb | One-board-or-many, Ready opt-in, the path chosen per epic ([§6A.2](#6a2-the-choice-and-the-recommendation)) |
| `cursor` | jsonb | Fetch resume point (`nextPageToken`) |
| `progress` | jsonb | `%{phase, done, total}` |
| `counts` | jsonb | Final counts by category |
| `report` | jsonb | [§21](#21-telemetry-audit-log-and-the-import-report) |
| `last_fetched_at` | utc_datetime | When the last fetch **started** ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)) |
| `imported_at`, `finished_at` | utc_datetime | |
| `error` | string | Short, redacted |
| timestamps | | |

The boards a run wrote are in `import_run_boards`, not in a column here.

**`import_run_boards`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `run_id` | references `import_runs`, on delete cascade | |
| `container_key` | string | The Jira project or board it came from, or `all` for **One board for everything** |
| `board_id` | references `boards`, on delete cascade | |
| `created` | boolean | `true` for a board the run created; `false` for an existing board it wrote into (Phase 3), which undo never deletes ([§13.7](#137-undo)) |
| `status` | string | `written` or `failed` |
| `error` | string | Short, redacted, for a failed board |
| timestamps | | |

Index: unique `(run_id, container_key)`. It is the first row written in a
board's transaction, so a retried job finds it and writes nothing
([§16.4](#164-idempotency)). A failed board's row is written in its own
transaction after the rollback.

**`import_staged_items`** (purged 14 days after the run is imported, but never
while any board of the run is failed or any rewrite is `preparing`, `pending`
or `drafted`; always purged at finish, cancel or failure)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `run_id` | references `import_runs`, on delete cascade | |
| `external_id` | string | Unique with `run_id` |
| `item` | jsonb | The normalised `Kanban.Imports.Item` |
| `byte_size` | integer | Length of the encoded item, set on every upsert; the staging limit sums it ([§6.3](#63-size-limits)) |
| `source_updated_at` | utc_datetime | |
| `fetched_at` | utc_datetime | |

**Retry this board** and **Import directly instead** read these rows, never a
capped bundle item. If the rows are ever gone, the issues are fetched again
from Jira, which needs the stored credential.

**`import_task_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_id` | references `tasks`, on delete nilify | Unique; nil once the task is deleted in Stride |
| `deleted_in_stride_at` | utc_datetime | Set by a trigger when `task_id` is nilified, so re-sync lists the issue under **Deleted in Stride** and never creates it again ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)) |
| `board_id` | references `boards`, on delete cascade | Part of the idempotency index |
| `run_id` | references `import_runs`, on delete nilify | |
| `source`, `source_site` | string | |
| `external_id`, `external_key`, `external_url` | string | |
| `source_updated_at` | utc_datetime | |
| `synced_at` | utc_datetime | Last time Stride wrote the task from Jira |
| `written` | jsonb | Per-field hashes of what Stride last wrote from Jira (title, description, column, priority, assignee, label set, each mapped field); re-sync compares against it ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)) |
| `unmapped` | jsonb | [§12](#12-data-that-does-not-map): valid JSON of at most 64 KB, cut by whole entries, with the changelog and its Jira actors |

Index: unique `(board_id, source, source_site, external_id)`; index on
`external_key` for Jira-key search (Phase 2). **Exclude imported history**
(Phase 2) excludes every task with a row here ([§14.4](#144-history)).

**`import_rewrites`** (permanent, one per epic or no-epic group chosen for rewrite)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `run_id` | references `import_runs`, on delete cascade | |
| `board_id` | references `boards`, on delete cascade | Destination board |
| `goal_id` | references `tasks`, on delete nilify | The existing goal of a split epic before sign-off; the written goal after |
| `group_key` | string, not null | The epic's Jira id, or `noepic:<project>` / `noepic:<project>/<component>` for a no-epic group ([§6A.4](#6a4-issues-with-no-epic)) |
| `round` | integer | 1 for the first rewrite of a group, 2 for the one re-sync adds after sign-off, and so on |
| `epic_external_id`, `epic_external_key` | string | Nil for a no-epic group |
| `status` | string | `preparing`, `pending`, `drafted`, `signed_off`, `imported_directly` ([§4](#4-the-import-at-a-glance)), moved only by compare-and-set |
| `bundle_json` | text | The bundle's exact bytes: the items being rewritten, the context-only items (each capped at 64 KB) and the held-out keys. Stored as text, not jsonb, because jsonb does not keep the bytes that were hashed |
| `bundle_sha256` | string | Of `bundle_json`; a draft must name it |
| `bundle_ready_at` | utc_datetime | When the bundle was frozen and the rewrite left `preparing` |
| `stale` | boolean | Set when re-sync rebuilt the bundle after the draft was submitted |
| `draft` | jsonb | The submitted goal and tasks, with the per-file download results |
| `draft_sha256` | string | Of the draft as submitted; the sign-off form must name it ([§6A.7](#6a7-sign-off)) |
| `coverage` | jsonb | Coverage map, computed report and warnings, reviewer findings as reported, the keys, ids and files marked dropped or confirmed by the person signing, and the issues ticked as reviewed |
| `send_back_note` | string | Shown to the agent on the next bundle fetch |
| `drafted_by_agent` | string | The agent name sent with the draft |
| `drafted_with` | string | The import plugin variant and version that drafted it ([§16A](#16a-the-agent-side-plugin-stride-import)), so an audit can tell which drafter and reviewer rules applied |
| `signed_off_by_id` | references `users`, on delete nilify | |
| `drafted_at`, `signed_off_at` | utc_datetime | |
| timestamps | | |

Indexes: unique `(run_id, group_key, round)`, and a partial unique index on
`(run_id, group_key)` where `status` is `preparing`, `pending` or `drafted`,
so a group has at most one open rewrite but can get a new one after sign-off
([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)). `group_key` is
never null, so no-epic groups are kept unique too.

**`import_source_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_id` | references `tasks`, on delete cascade | A rewritten task |
| `rewrite_id` | references `import_rewrites`, on delete cascade | Its bundle holds the issue's data |
| `external_id`, `external_key`, `external_url` | string | |
| `covered_lines` | jsonb | Which source ids of the issue this task covers |

Index: unique `(task_id, external_id)`; index on `external_key` for Jira-key
search.

**`import_attachment_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_attachment_id` | references `task_attachments`, on delete nilify | Unique; nil once the file is removed in Stride |
| `deleted_in_stride_at` | utc_datetime | Set when `task_attachment_id` is nilified, so re-sync never copies the file again |
| `task_id` | references `tasks`, on delete cascade | Part of the idempotency index |
| `comment_id` | references `task_comments`, on delete nilify | The comment it is attached to, if any |
| `board_id` | references `boards`, on delete cascade | Part of the idempotency index |
| `run_id` | references `import_runs`, on delete nilify | |
| `source_site`, `external_id` | string | The Jira attachment id |

Index: unique `(board_id, source_site, external_id, task_id)`, so one Jira
file is copied once per task it belongs to. (An index that includes
`task_attachment_id`, itself unique, would prevent nothing.) The row is
written in the same transaction as the `task_attachments` row, inside
`import_attachment/4`, and is checked before each download. A Jira file left
as a link has no row here; it is in the import link's unmapped data, or in the
rewrite's bundle, with its reason.

**`import_rewrite_files`** (deleted once its rewrite's files are copied after
sign-off, at finish, or with the run)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | Used in the file's `download_url` |
| `rewrite_id` | references `import_rewrites`, on delete cascade | |
| `external_id`, `external_key` | string | The Jira attachment id, and the key of the issue it is on |
| `comment_external_id` | string | The comment that embeds it, when there is exactly one |
| `filename`, `content_type`, `byte_size`, `sha256` | as `task_attachments` | Validated by the same file checks. `TaskAttachment.create_changeset/3` requires a `task_id`, so its file checks (name sanitising, content type and sniff, size range, sha256 format) move into one function that both changesets call |
| `storage_key` | string | Unique; `boards/<board_id>/<uuid>`, as attachment keys are |
| `uploaded_by_id` | references `users`, on delete nilify | The matched Jira author |
| `uploaded_at` | utc_datetime | The Jira upload time |

An `AFTER DELETE` trigger queues each row's blob in `attachment_blob_deletions`,
exactly as the `task_attachments` trigger does, so every path that removes a
rewrite file (after its copy, finish, undo, deleting the board) removes its
blob. Three more rules keep the files safe and counted:

- **Stored with the pending-tombstone steps.** `store_rewrite_file` goes
  through the same steps as a task upload in `Kanban.Attachments.Pipeline`: a
  pending tombstone is parked before the blob is stored, and the row's insert
  releases it in one transaction.
- **Protected from the cleanup worker.** The blob cleanup worker skips a due
  tombstone only when `key_in_use?/1` finds a row naming the key, and today it
  looks only in `task_attachments`. It must look in `import_rewrite_files`
  too, or it could delete a live source file.
- **Counted in the quota.** Source files count against the Organization's
  quota while they are held, so `Kanban.Attachments.Usage` must count this
  table as well as `task_attachments` (open point 7 in [Task Attachments](ATTACHMENTS-DESIGN.md#12-open-points)).

**`import_mapping_presets`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `organization_id` | references `organizations`, on delete cascade | Nil for a personal preset |
| `user_id` | references `users` | Owner for a personal preset |
| `source`, `source_site` | string | |
| `name` | string | |
| `mapping` | jsonb | Includes people matches by Jira account id |
| timestamps | | |

**Workspace export.** Export and `mix kanban.import_workspace` must carry
`import_task_links` (it holds no credentials), so an exported workspace keeps
its **Imported from** panels. It must also carry `import_source_links` and,
for signed-off rewrites only, the bundle items they point to, so the
**Written from** panels survive too. The other import tables are operational
and stay out of the archive, like webhook endpoints today.

---

## 18. Screens

All pages are LiveViews in the existing `live_session :require_authenticated_user`
block, because every one of them needs a signed-in user and the current
workspace. The entry points are **Import** in the workspace sidebar and
**Import from Jira** on the new-board page. Every string is translated
through gettext in all locales. Every page follows the
[dark-mode contract](../dark-mode-contract.md) and uses the existing
`<.input>`, `<.button>` and form components. All import pages are in that
block because they need a signed-in user, and each event checks the org-admin
rule of [§19](#19-permissions-and-plans) itself, because a `live_session`
cannot tell an org-admin from a member.

| Page | What is on it |
|---|---|
| **Imports** `/imports` | Runs in this workspace: Jira site, scope summary, status, boards, who ran it, when. **New import**. Every import page is for the Organization's org-admins; a workspace member sees only a note that imports are run by an org-admin, with the org-admins' names. In a workspace outside an Organization, with plans enforced, the LockedFeature prompt for *Import* instead, and the sidebar entry shows the lock |
| **Connect** `/imports/new` | Site URL (an `*.atlassian.net` address), email, API token, a short "where to create an API token" help with a link to Atlassian's page, **Test connection**, the result. Or pick a connection already saved in this workspace, with the runs that use it |
| **Scope** `/imports/:id/scope` | [§6](#6-choosing-what-to-import): projects or boards with counts, epics with counts, filters, the JQL box, closed-work choice, running total, limit warnings, restricted-issue count and opt-in. **Fetch** |
| **Fetching** (on `/imports/:id`) | Progress bar by phase (issues, comments, changelog), live; **Cancel** |
| **Rewrite or import** `/imports/:id/paths` | [§6A.2](#6a2-the-choice-and-the-recommendation): one row per epic and per no-epic group, with not-started / started / done counts, file counts, the quality signals, the recommended path and the choice; **Rewrite all recommended**, **Import all directly**, **Rewrite without files**; the note that rewritten text and files go to the team's agent and its model provider |
| **Mapping** `/imports/:id/mapping` | Tabs: *Boards* (one or many, names; every board is AI-optimized), *Status* (each Jira status to one of the five columns, with the column each status ends in), *Issue types and hierarchy*, *Priority*, *Size*, *People* (with the note beside each **Invite** that accepting gives an Organization seat), *Labels*, *Fields* ([§11](#11-mapping-additional-fields)), *Sections*. Every tab shows only values that occur, with counts. **Save as preset** |
| **Preview** `/imports/:id/preview` | Per destination board: task counts by column and type, goals, comments, labels, people added, attachments to copy and to leave as links (with the reasons and the quota they use), dependency links that will be dropped to break cycles, and the epics and issue counts that will be rewritten; **sample cards** (ten issues chosen to cover each type and status) rendered with the real task card component; warnings grouped by kind with the issues they affect; blocking errors that must be fixed before **Import** is enabled |
| **Run** `/imports/:id` | During import: progress per board, then file-copy progress, with **Retry failed files**. After: the rewrites, each with its state and destination board, and the command to run them in the importer's agent, for the runtime chosen in a picker remembered per user, with a link to that runtime's import plugin ([§16A.3](#16a3-the-variants)); **Rebuild bundle** after a mapping change; the report ([§21](#21-telemetry-audit-log-and-the-import-report)), **Open board**, **Retry this board**, **Download all Jira data**, **Undo import**, **Delete stored credential**. Phase 3 adds **Re-sync changes**, conflicts, **Changed after rewrite**, **Deleted in Stride** and **Finish migration** |
| **Rewrite** `/imports/:id/rewrites/:rewrite_id` | [§6A.7](#6a7-sign-off): the draft as task cards with every agent-facing field in full, the coverage report with its warnings and the files the model never saw, the reviewer's findings under *Reported by the agent*, each Jira issue with its text, the tasks citing it and a **Reviewed** tick, each source file with the tasks it goes to, the people assigned in Jira; **Sign off**, **Send back**, **Leave out**, **Mark dropped**, **Confirm**, **Import directly instead**, **Import this issue directly** |
| **Task view** | The **Imported from PAY-88** or **Written from PAY-88, PAY-91** line under the title, and the collapsed panel of the same name ([§12](#12-data-that-does-not-map)) |

---

## 19. Permissions and plans

| Action | Who |
|---|---|
| Create or delete a connection, start an import, choose paths, re-sync, retry a board, undo or finish, in an Organization workspace | The Organization's **enabled org-admins** (`Kanban.Workspaces.Policy.can_manage_workspace?/2`). Members ask an org-admin |
| The same, in a personal workspace | Nobody when plans are enforced. While they are not, the workspace's owner, as for every paid feature |
| See a run, its report, its staged data and **Download all Jira data** | The Organization's enabled org-admins (in a personal workspace, its owner) |
| Use a stored connection | The Organization's enabled org-admins. Creating it gives no right of its own |
| Choose rewrite or import, send back, sign off a rewrite, import directly instead | The Organization's enabled org-admins |
| Fetch a bundle, download its files and submit a draft | An API token for the destination workspace or board whose creator is still an enabled org-admin ([§16.6](#166-the-rewrite-api)) |
| See the **Imported from** and **Written from** panels on a task, and their unmapped data | Anyone who can see the task, with Jira email addresses and account ids removed ([§12](#12-data-that-does-not-map)) |

**Rights are read at the moment of use.** Every check reads the person's
current role in the Organization, on every call: in the LiveView events, in
`Kanban.Imports` and in the workers when they start. `created_by_id` on a
connection or a run is kept for the report and the audit log, and grants
nothing. Someone who has left the Organization, been disabled, or stopped
being an org-admin can no longer use the Jira token, read the report or undo,
even for a run they started. No import table needs to be added to
`Kanban.Workspaces.MembershipCascade` for this: nothing in them is a grant to
a person, and the cascade already revokes the API tokens an agent drafting a
rewrite would hold. A refused call writes the `import_action_refused` audit
event ([§21.2](#212-audit-log)).

**Why org-admins only.** In an Organization workspace there are only
org-admins and the workspace's `:member` and `:guest` rows; there are no
workspace owners. Members can create boards (`Policy.can_create_board_in?/2`),
but only org-admins invite people onto an Organization board. An import does
more than create boards: it adds people to them, sends invitations that give
outsiders an Organization seat, attributes work to people, and holds a Jira
token that can read everything its Jira account can. Those are org-admin
decisions ([§24](#24-decisions-needed), decision 19).

**Plans.** Import, and with it the rewrite, re-sync, mapping presets and
everything else in this design, is an **Organization plan feature**
([§24](#24-decisions-needed), decisions 3 and 13).

- **The feature.** `:imports` is added to `Kanban.Plans` `@features`, with a
  `parse_feature("imports")` clause, a translated *Import* label in
  `KanbanWeb.LockedFeature`, and a row in the "What a free board cannot do"
  table in [Organizations and Workspaces](../organizations.md#what-a-free-board-cannot-do).
- **What is checked.** An import has no board until it writes one, so the
  check is on the **destination workspace**: it is paid when it belongs to an
  Organization (`workspaces.organization_id` is set), the same rule
  `Kanban.Plans` uses for boards. This needs a `Kanban.Plans.check_workspace/3`
  beside `check_board/3`, so `Kanban.Plans` stays the only place that decides
  paid versus free. Who is asking does not matter: an Organization member's
  personal workspace is free.
- **Where it is checked.** Every `Kanban.Imports` function that starts or
  advances a run (create, fetch, import, re-sync, choosing paths, sign-off),
  every LiveView event on the import pages, and all four rewrite API endpoints
  ([§16.6](#166-the-rewrite-api)), which check the destination board with
  `check_board/3` and surface `:rest`. A refusal is `{:error, {:plan_required, :imports}}`
  and emits the existing `[:kanban, :plan, :feature_refused]` event.
- **While plans are not enforced** (the self-hosted default), the check
  passes everywhere, as for every other paid feature, so imports work in any
  workspace. The hosted service at stridelikeaboss.com has enforced plans
  since 1 November 2026, so there an import always needs an Organization.
- **What can change during a run.** An Organization workspace never becomes
  free: Stride has no way to delete an Organization or move it back to the
  free plan, and boards move only into Organization workspaces
  ([Organizations and Workspaces](../organizations.md)). The changes that can
  happen are these:
  - **Plans become enforced** (a self-hosted operator turns
    `:plans_enforced` on) while a run into a personal workspace is open. Every
    further step is refused with the LockedFeature prompt; **Undo import** and
    **Delete stored credential** stay available, so the team can remove what
    it brought.
  - **The destination workspace is archived.** Archiving refuses a workspace
    that still has boards, so this reaches only a run that has not written
    one. The run is refused from then on, and archiving deletes the
    workspace's import connections.
  - **A destination board is deleted** by its owner mid-run (boards cannot
    be archived). Steps that would write to it (sign-off, re-sync, file
    copies) are refused for that board and listed in the report, and the rest
    of the run goes on. A board moved from a personal workspace into an
    Organization workspace (`Kanban.Workspaces.BoardMoves`) is followed,
    because every check reads the board's current workspace.
  - **The importer stops being an org-admin.** Covered above: rights are read
    at the moment of use.

Because every destination is an Organization board when plans are enforced,
the free-board rules never reach an import: no member cap
([§15.3](#153-free-board-member-cap)), no locked task fields
([§11.2](#112-what-a-field-can-be-mapped-to)), and attachments are always
copied where their own limits allow ([§14.3](#143-attachments)).

---

## 20. Security and privacy

| Risk | Rule |
|---|---|
| **The token leaks** | `Kanban.Encryption.EncryptedBinary` at rest, with `redact: true` so it never shows in an inspected struct; never logged, never in telemetry metadata, the report, an error message, an export or an Oban job argument (jobs carry the run id and load the credential inside the worker); deleted when the last run using the connection finishes, or after 30 idle days ([§5.3](#53-where-credentials-live-and-for-how-long)) |
| **SSRF through the Jira site URL** | In Phase 1 the host must be a single-label `*.atlassian.net` name. Every Jira request, each page and each file, runs `Kanban.Webhooks.UrlGuard.check(url, allow_http: false)`, so private, loopback and link-local addresses are refused, a host resolving to both public and private addresses is refused, and `http` is refused in every environment (by default `UrlGuard` allows it wherever the endpoint does not set `force_ssl`, as in dev and test). The request then connects to the address `UrlGuard` approved, not to the host name again, through the pinning in `Kanban.SSO.pinned_request/1`, moved into a shared helper. Without the pinning a host could resolve to a public address for the check and to an internal one for the request. `Webhooks.Transport` pins too, but only for small POST bodies, so it cannot carry paged GETs or 25 MiB downloads. Req runs with `redirect: false`, and any redirect is an error. For Jira Data Center (Phase 4) a self-hosted operator can allow private addresses with `config :kanban, Kanban.Imports, allow_private_hosts: true`, like `Kanban.SSO`'s `allow_private_issuers`; it is new `UrlGuard` work, and `config/prod.exs` must never set it on the hosted service |
| **Restricted issues become visible to the whole board** | Issues with a security level are **skipped by default**. The scope page shows how many there are and an opt-in, with the warning that everyone on the destination board will be able to read them |
| **Restricted comments become visible** | Comments with `visibility` set and Jira Service Management internal notes are always skipped and counted. No opt-in in Phase 1. A file referenced only from skipped comments is skipped too, reason *restricted*, for direct imports and bundles alike, so a screenshot pasted into an internal note never reaches the board or a model |
| **Imported text carries secrets** | Descriptions, comments and mapped custom fields are scanned with `Kanban.Tasks.CredentialShapes`. It has no pattern for Atlassian API tokens, the secret Jira text most often leaks, so the import adds Atlassian token shapes to it; that changes what its existing callers detect too, and their tests are updated with it. Matches are listed in the preview as warnings (issue and field, never the value), so the importer can fix them in Jira first. Text is not altered automatically. A credential-shaped value mapped to `security_considerations` is a blocking preview error instead, because that field's changeset refuses it ([§11.4](#114-validation)) |
| **Jira emails are used to find people** | In a personal workspace only the importer is matched automatically, and nobody outside the destination's members is ever given a row ([§15.1](#151-matching)), so a crafted site cannot enumerate accounts, add people to a board or forge authorship |
| **Imported files are untrusted** | Every file goes through `Kanban.Attachments`: the type allow-list (no SVG, HTML or archives), the magic-byte check, the size limit, and filename sanitising. They are served only by the attachment routes, with `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; sandbox`, `nosniff` and `Content-Disposition: attachment` ([Task Attachments](ATTACHMENTS-DESIGN.md)). Text files with credential-shaped content are stored, as text is, and listed in the report |
| **File downloads reach internal hosts** | Files are fetched only from the connection's own Jira site, through `UrlGuard` and the pinned request, with `?redirect=false` and Req's `redirect: false`; the attachment id comes from Jira's own issue data, never from a URL in issue text |
| **Imported text is untrusted** | Every row goes through its changeset; text is rendered escaped as all task text is; no imported value is ever turned into an atom, a URL the server fetches, or a query fragment. JQL is sent only to the connection's own Jira site |
| **Agents read imported text** | Imported descriptions reach agents as task data. The existing agent rule (task text is data, not instructions) covers this. Landing in Backlog means a human sees the task before an agent can claim it, but only in Backlog, so the rest is closed off too: the Ready opt-in warns that its text is unread Jira text ([§13.4](#134-agents-on-the-new-board)), re-sync never puts work in Ready and never changes the text of a task outside Backlog without a person accepting it ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)), and sign-off shows every agent-facing field of a rewritten task in full ([§6A.7](#6a7-sign-off)) |
| **Rewritten text leaves Stride** | The bundle goes to the team's own agent and its model provider. The **Rewrite or import** page says so; restricted issues need a second opt-in to be rewritten ([§6A.8](#6a8-constraints-and-risks)) |
| **A bundle carries a secret** | Issues with credential-shaped text are held out of the bundle, listed as uncovered and block sign-off until dropped or imported directly; drafts are scanned again on receipt |
| **A draft is hostile or wrong** | Validated by the task changesets and the dependency checks without inserting, capped in size, checked against the current bundle hash, and written only when an org-admin signs off the exact draft they saw. No API call can write a rewrite to a board |
| **The rewrite API is used by the wrong token** | Only a token for the destination workspace or board, whose creator is still an enabled org-admin, can read a bundle or submit a draft; any other gets a uniform `404`. Every bundle fetch and draft submission is audited with the token's id, and every endpoint is rate-limited per token ([§16.6](#166-the-rewrite-api)) |
| **Who sees what** | [§19](#19-permissions-and-plans). Unmapped data follows the task's visibility, with Jira email addresses and account ids removed ([§12](#12-data-that-does-not-map)); the run, its report and its staged data are visible only to org-admins, through the run page |
| **Retention** | Staging purged 14 days after import, but kept while a board has failed or a rewrite is open, and always purged at finish ([§17](#17-database-changes)); the report kept with the run; import links kept with their tasks; bundles and source links of signed-off rewrites kept with their tasks; drafts and bundles of rewrites that ended `imported_directly` purged at finish; rewrite source files deleted once copied onto their tasks, and at finish, through the blob tombstones |
| **Load on Stride and on Jira** | One running fetch per workspace; a second is queued. Only one of import, retry, re-sync and undo runs per run ([§16.3](#163-pipeline)). The adapter keeps to Jira's limits by snoozing on `429` |

---

## 21. Telemetry, audit log and the import report

### 21.1 Telemetry

New events, declared in a new `Kanban.Telemetry.Catalog.ImportEvents` with
their `metrics`, `persist` and `tags` fields, emitted through
`Kanban.Telemetry.emit/3` or `span/3`, with the event reference in
[Telemetry](../telemetry.md) refreshed in the same change.

The catalog's rules decide the names. A new event is exactly three segments,
`[:kanban, domain, past_tense_action]` (`test/kanban/telemetry_test.exs`), so
an event about a run or a rewrite puts the noun in the action
(`:run_finished`). A span is named by its prefix, `[:kanban, :import, :fetch]`,
and `:telemetry` adds `:start`, `:stop` and `:exception`; its measurements
list only the extra stop measurements. Tags must be low-cardinality keys from
the test's allowed list (`source` and `outcome` here), never an id; `decision`
is not on that list, so the rewrite decision is carried as `outcome`.

| Event | Kind | Measurements | Metadata (allow-listed) | Metrics, persist, tags |
|---|---|---|---|---|
| `[:kanban, :import, :fetch]` | span | `items`, `comments`, `api_calls`, `rate_limited` | `source`, `run_id`, `outcome` | `summary: :duration`; not persisted; `source`, `outcome` |
| `[:kanban, :import, :write]` | span | `tasks`, `comments`, `warnings` | `source`, `run_id`, `board_id`, `outcome` | `summary: :duration`; not persisted; `source`, `outcome` |
| `[:kanban, :import, :attachments]` | span | `copied`, `linked`, `failed`, `bytes` | `source`, `run_id`, `board_id`, `outcome` | `summary: :duration`; not persisted; `source`, `outcome` |
| `[:kanban, :import, :resync]` (Phase 3) | span | `created`, `updated`, `conflicts` | `source`, `run_id`, `outcome` | `summary: :duration`; not persisted; `source`, `outcome` |
| `[:kanban, :import, :run_finished]` (Phase 3) | event | `count`, `days_open`, `resyncs` | `source`, `run_id` | `counter: :count`; persisted; `source` |
| `[:kanban, :import, :run_undone]` | event | `count`, `boards`, `tasks` | `source`, `run_id` | `counter: :count`; persisted; `source` |
| `[:kanban, :import, :rewrite_drafted]` | event | `count`, `tasks`, `issues`, `uncovered`, `warnings`, `attempt` | `source`, `run_id`, `rewrite_id`, `outcome` (`accepted`, `refused`) | `counter: :count`; persisted; `outcome` |
| `[:kanban, :import, :rewrite_decided]` | event | `count`, `tasks`, `dropped`, `left_out`, `hours_since_draft` | `source`, `run_id`, `rewrite_id`, `outcome` (`signed_off`, `sent_back`, `imported_directly`) | `counter: :count`; persisted; `outcome` |

The decision events are persisted because they are rare and need a signed-in
org-admin or a valid token; the spans are not. No site URL, account, issue
key, title, field name or value appears in metadata, and none of the keys is
one `Kanban.Telemetry` forbids (`email`, `ip`, `title`, `description`, `body`,
`token`, or a name containing `email`, `password`, `secret`, `token`,
`authorization` or `api_key`, other than an `_id`).

### 21.2 Audit log

These are the actions an Organization's security team will ask about. Each is
a `Kanban.AuditLog.event/2` action, declared with its keys in `@audit_actions`
(`Kanban.Telemetry.Catalog.Families`); every key passed must be declared
there. Every event carries `organization_id` (so the row is listed in the
Organization's audit log) and `workspace_id`, and `user_id` for the person who
acted, or no user for the automatic credential expiry.

| Action | Keys besides `organization_id` and `workspace_id` | When |
|---|---|---|
| `import_connection_created` | `user_id`, `connection_id` | A connection is saved |
| `import_connection_deleted` | `user_id`, `connection_id`, `reason` (`by_user`, `expired`, `last_run_finished`, `workspace_archived`) | Its credential or the connection is deleted, by a person or automatically |
| `import_run_started` | `user_id`, `run_id` | **Fetch** on a new run |
| `import_run_imported` | `user_id`, `run_id`, `board_count`, `task_count` | The run reaches `imported` |
| `import_restricted_opted_in` | `user_id`, `run_id`, `issue_count`, `rewrite_allowed` | The restricted-issue opt-ins |
| `import_run_resynced` (Phase 3) | `user_id`, `run_id`, `created_count`, `updated_count`, `conflict_count` | A re-sync ends |
| `import_run_finished` (Phase 3) | `user_id`, `run_id` | **Finish migration** |
| `import_run_undone` | `user_id`, `run_id`, `board_count`, `task_count` | **Undo import** |
| `import_bundle_fetched` | `user_id`, `run_id`, `rewrite_id`, `token_id` | A bundle is served |
| `import_draft_submitted` | `user_id`, `run_id`, `rewrite_id`, `token_id`, `task_count` | A draft is accepted |
| `import_rewrite_signed_off`, `import_rewrite_sent_back`, `import_rewrite_imported_directly` | `user_id`, `run_id`, `rewrite_id`, `dropped_count`, `dropped_issues` | The person's decision on a rewrite |
| `import_action_refused` | `user_id`, `run_id`, `reason` | An import action refused because the person is not, or is no longer, an org-admin |

**Jira keys never reach telemetry.** `AuditLog.event/2` also emits every event
as `[:kanban, :audit, action]` with its declared keys. So the Jira keys of the
issues marked dropped go in `dropped_issues`, which is added to
`@telemetry_omitted_keys` in `Kanban.AuditLog` (beside `email`, `ip` and
`filters`) and to `@audit_omitted_keys` in the telemetry test, so it is kept in
the stored row and the log line only. The name must not contain `key`:
`AuditLog` drops any metadata key whose name contains `key` (or `token`,
`secret`, `password`, `authorization`, `otp`), unless it ends in `_id`, from
the stored row as well. Stored values are cut at 2,000 characters, so the list
is complete in `import_rewrites.coverage`, which the row points to by
`rewrite_id`. The bundle and draft events record the token's row id
(`token_id`), never the token.

The rewrite API calls are also counted in the API family
(`[:kanban, :api, action]`, declared in `@api_actions` with its common
`board_id`, `user_id`, `path` and `method` keys): `import_bundle_fetched`
(`rewrite_id`, `api_token_id`), `import_draft_submitted` (`rewrite_id`,
`api_token_id`) and `import_rewrite_file_downloaded` (`rewrite_id`,
`file_id`), as `attachment_downloaded` is for task files.

### 21.3 The report

Kept as `import_runs.report` and downloadable as JSON and CSV:

- **Created:** boards, goals, tasks by type and column, comments, labels, history entries, people added to boards.
- **Rewritten:** per epic, its state, the issues it covers, the tasks written, the keys, source ids and files dropped with their reasons, the files the model never saw, and the warnings the person signed off past. An epic that is not yet signed off is listed as *pending*.
- **Attachments:** files copied, bytes used against the quota, and every file left as a link to Jira with its reason (*plan*, *type not stored*, *type mismatch*, *empty*, *bad name*, *too large*, *too many files*, *quota*, *restricted*, *failed*), by Jira key.
- **Repaired:** shortened label names and comments; labels merged by case or after shortening; `completed_at` taken from a fallback; mapped values a changeset refused, kept as unmapped data; unknown document nodes and unmatched media nodes.
- **People:** matched (by email or by hand), invited, invitations still queued behind the hourly limit, left unassigned, **not added** because the membership check failed at write time.
- **Needs attention:** in-progress work with nobody on it; dependencies dropped (cycles, cross-board); children separated from their goal; credential-shaped text found; boards that failed, with **Retry this board**; Jira issues the "moved to Stride" marker could not mark (Phase 3).
- **Skipped:** restricted issues, restricted comments and files referenced only from them, issues over the limits, comments blank after conversion, each with its Jira key and the reason.
- **Counted, not kept:** votes, watchers.
- **Re-sync history** (Phase 3): each re-sync's created, updated, conflicts, issues no longer in Jira and issues deleted in Stride.

---

## 22. Testing strategy

| Layer | What | How |
|---|---|---|
| Jira adapter | Every endpoint in Appendix A, `nextPageToken` paging, `429` with `Retry-After`, auth failure, a site that is not Cloud, a host that is not `*.atlassian.net`, a JQL error, lists cut short on an issue (comments, changelog) | `Req.Test` stubs through configured `req_options`, as `Webhooks.Transport` is tested, fed by recorded fixtures (scrubbed of real data) in `test/support/fixtures/imports/jira/` |
| Text conversion | Every Atlassian document node type in Appendix B, a code block holding a run of backticks, a media node with no file name | Table-driven unit tests, plus property tests that output is valid UTF-8 without NUL bytes |
| Mapping | Every default in §9–§10, every transform in §11.2, section extraction, sub-task flattening, story-points field detection; the Review name rule only on *In Progress* statuses; complexity at 6, 7 and 2.5 points; *Major* and an unlisted priority; labels differing only by case or spaces merged; type mappings that would break the two levels refused; a value the changeset refuses kept as unmapped data | Unit tests on `Mapping.Apply` with hand-built `Item` structs |
| Dependency graph | A cycle broken the same way in the preview and the write; blocked status set on open tasks with incomplete dependencies; a duplicate whose original is on another board archived `:wontdo` | Unit tests on `Mapping.Graph` |
| Status edge cases | Each row of [§13.2](#132-what-happens-to-each-kind-of-item); a Done issue with no resolution date; a closed epic with an open child not archived; `claimed_at` from the first *In Progress* move and none when there was none, `claim_expires_at` always empty; the assignee completing and unclaiming an imported Doing task; an imported Review task in the review queue with `review_requested_at` at the import time | One test per row, asserting column, status, claim fields, archive reason and note |
| Jira times | `inserted_at` from Jira on tasks, comments, history rows and attachments | DataCase, one assertion per table ([§14.6](#146-how-jira-times-are-written)) |
| Writer | One transaction per board; a bad row rolls back that board only; identifiers sequential; dependencies and duplicates resolved in the second pass; goals written with their own `completed_at` and status, not the import time; history rows with no actor, and priority changes that map to one Stride priority not written; no broadcast, notification, webhook or Oban notification job; board and column telemetry only after commit; every membership through `lock_and_check/3`, and a person removed from the Organization after mapping not added | `Kanban.DataCase`; telemetry attached with `Kanban.TelemetryHelpers.attach_telemetry/2`; `refute_enqueued` for notification and webhook workers |
| Idempotency | Retried import job, including one whose transaction already committed (no second board); retried fetch page; retried file copy (one attachment per task) | Run the worker twice, assert counts unchanged |
| Exclusivity | A second re-sync, a retry during the import, and undo during a file copy are refused or wait | DataCase with Oban testing |
| Re-sync (Phase 3) | New, updated, conflicting, agent-claimed, deleted-in-Jira and deleted-in-Stride issues; a sibling moved in Stride raises no conflict; a label changed in Stride is kept; a key-only check that does not report aged-out issues; a signed-off epic gets a second rewrite; new issues land in Backlog with the Ready option on | DataCase, one test per case |
| Lock order | Sign-off and **Import directly instead** while a task is created on the same board finish without a deadlock | DataCase, two processes |
| Undo | Boards created by the run deleted; nothing else touched; copied attachments' blobs queued for deletion; the confirmation lists Stride-side changes; an org-admin who does not own the board can undo; (Phase 3) an existing board keeps everything the run did not write | DataCase |
| Attachments | Each rule of [§14.3](#143-attachments): plan gate, allow-list, magic bytes, size, the per-task limit, quota; a body larger than Jira reported; `redirect: false`, a redirect treated as an error, and `UrlGuard` with pinning on every download; uploader from people matching; comment matching by file name; a file referenced only from a restricted comment skipped; a retried job copies nothing twice; a failed file leaves a link | DataCase with `Req.Test` Jira stubs and the local storage adapter in `tmp/test_attachments` |
| Rewrite files | Copied into `import_rewrite_files` with the same rules and the pending-tombstone steps; counted in `Usage`; a due tombstone for a live source file not deleted by the cleanup worker; the eight-key bundle entries; the file download endpoint's headers, 404s and rate limit; copied onto every task the coverage map names after sign-off; blobs tombstoned after copy, at finish and on undo | DataCase, ConnCase |
| Rewrite recommendation | Each row of [§6A.2](#6a2-the-choice-and-the-recommendation) and [§6A.3](#6a3-epics-already-in-progress), each quality signal, the rewrite preselected for every epic with not-started work | Unit tests on `Rewrite.Recommend` with hand-built items |
| Bundle | Rewritten and context-only items, restricted issues left out, credential-shaped issues listed as held out, the 64 KB cap, the stored bytes hashing to the stored hash, `409 not_ready` while `preparing` | Unit tests on `Rewrite.Bundle` |
| Source ids | An id unchanged when another line is added before it, changed when its own text changes, repeated text numbered; paragraph ids for description and comment prose | Unit tests on `Rewrite.SourceIds` |
| Draft and coverage | A valid draft, an invalid task, an out-of-range and a self dependency, a cycle within the draft and one formed with Jira links, an uncovered key, an uncovered id, a dropped key without a reason, a merge and a split, each computed warning, a file cited but never downloaded, a held-out issue uncovered, a stale hash, a draft after sign-off or after **Import directly instead** | Unit tests on `Rewrite.Draft` and `Rewrite.Coverage`; controller tests for each refusal in [§16.6](#166-the-rewrite-api) |
| Sign-off writer | One transaction; tasks under a new goal, and under the existing goal of a split epic; dependencies from the draft and from Jira links; source links; no broadcast or notification; a double sign-off writes once; sign-off refused while anything is uncovered or unticked, when the draft changed since the page loaded, and for a stale draft until new ids are covered; a failed transaction leaves the rewrite `drafted` | DataCase, `refute_enqueued` |
| Rewrite API | Token reach (board, workspace, another board), the token's creator no longer an org-admin, a workspace token with no board header, run state, size cap, rate limits, an audit event per bundle fetch and draft | `KanbanWeb.ConnCase` |
| People | Email match, case, hidden email, disabled user, user outside the Organization, app accounts; in a personal workspace only the importer matched; Invite sending a workspace invitation, and queuing past the hourly limit | Mirrors the workspace importer's user tests |
| Permissions | Every import action refused for a workspace member and allowed for an org-admin; a run's creator refused after losing org-admin or leaving the Organization | DataCase and `Phoenix.LiveViewTest` |
| Security | URL guard and pinning on every Jira request, `http` refused, redirects refused, token never in logs, job args, an inspected connection or the report, Atlassian token shapes found, restricted issues and comments skipped | `ExUnit.CaptureLog` scans, Oban job arg assertions, `inspect/1` on a connection |
| Telemetry and audit | Every event in [§21](#21-telemetry-audit-log-and-the-import-report) in the catalog with valid metrics, persist and tags; every audit action declared with its keys; `dropped_issues` in the stored row and absent from the telemetry copy | `Kanban.TelemetryHelpers.attach_telemetry/2`; the catalog and audit tests |
| Plan gate | `:imports` refused in a workspace outside an Organization with plans enforced, allowed with them off; refused on every run-advancing function, LiveView event and rewrite endpoint; `feature_refused` emitted; plans turned on while a personal-workspace run is open keeps Undo and credential deletion; an archived destination workspace refused | DataCase and ConnCase with `:plans_enforced` set per test |
| LiveViews | Each wizard page, permissions per role, translations rendered | `Phoenix.LiveViewTest`; locale tests with the session set |
| Dark mode | Every new page and the task panel | `mix dark_mode.scan` and the contrast check (run by `mix precommit`), and a check of every page and form control in both themes, per the [dark-mode contract](../dark-mode-contract.md)'s verification steps |
| End to end | A real Jira Cloud site made for the purpose, with epics, sub-tasks, custom fields, a security level and restricted comments, imported into the dev app, with one epic rewritten, one split epic and one imported directly | Manual / exploratory, Phase 1 and Phase 2 exit |
| Rewrite quality | A set of real, messy epics rewritten by the import plugin, checked by hand for missed requirements the coverage report did not flag | Manual, Phase 1 exit; the misses found become reviewer rules |
| Agent commands | `Kanban.Imports.AgentCommands` has an entry for each of the six variants, and each entry matches the checked-in entry-point fixture | Unit test against the fixture; each variant's `test-all.sh` checks its README against its copy ([§16A.3](#16a3-the-variants)) |
| Import plugin, offline | In each of the six variants: contract pins, the draft shape check, the download script, and the pinned field rules against their recorded copy ([§16A.7](#16a7-testing-and-release)) | Each variant's `scripts/test-all.sh`, in its own CI |
| Import plugin, drift | Each variant's pinned copies against the current source plugin and `create-goals` | `scripts/drift-check.sh`, at release time and in the source repository's CI |
| Pi dispatch | `stride-pi`'s registry accepts the import agents; with it absent, the inline fallback sets `"independent": false` | `stride-pi`'s `node --test` suite and `stride-pi-import`'s contract script ([§16A.8](#16a8-pi-the-first-companion-package)) |
| Import plugin, live | The fixture epic rewritten through each of the six variants with that runtime's own agent; the coverage matches the expected file, and the draft is accepted by a dev server | Manual, Phase 1 exit, once per runtime |

---

## 23. Phased delivery

Each phase ships on its own and is useful on its own.

| Phase | Scope | Exit criteria |
|---|---|---|
| **1. Core Jira Cloud import** | Task Attachments (G488–G491) shipped in Stride 3.1.0, so nothing waits on it. Connections (API token, `EncryptedBinary`, `*.atlassian.net` only), runs and their state table, staging with its byte limit, the adapter behaviour, the Jira Cloud adapter with the shared pinned-request helper, document-format conversion, epics and sub-task flattening, default mapping, status/type/priority/complexity/people/label mapping tables, `claimed_at` and the other Jira times, restricted issues and comments, preview, writer with the non-broadcasting board builder in `Kanban.Boards.Creation`, `import_run_boards`, attachment copying, report, **Imported from** panel, undo, the org-admin permission checks, Invite through workspace invitations, `lock_and_check/3` on every membership, the credential-expiry job in `CleanupWorker`, the Atlassian token shapes in `CredentialShapes`, telemetry, audit. **The rewrite** ([§6A](#6a-rewrite-or-import-epic-by-epic)): the **Rewrite or import** page and its recommendation, split epics, bundles (stored as exact bytes, with content-derived source ids for lines and paragraphs) and source files (with `store_rewrite_file`, the cleanup-worker and `Usage` changes), the rewrite API with its refusals, drafts, the coverage report with its computed warnings and the per-issue tick, sign-off, the **Written from** panel, and the new `stride-import` plugin in all six variants: Claude Code, Codex CLI, GitHub Copilot CLI, Gemini CLI, OpenCode and Pi ([§16A](#16a-the-agent-side-plugin-stride-import)). Before `stride-pi-import`: the `stride-pi` task that makes its dispatch registry extensible, released first ([§16A.8](#16a8-pi-the-first-companion-package)). A Phase 1 spike first answers the Jira questions in [Appendix A](#appendix-a-jira-api-reference) | A Jira project of ~2,000 issues with epics, sub-tasks and comments imports with no silent loss; the report accounts for every issue and every file. A 20,000-issue board is measured ([§16.5](#165-long-transactions)). Every not-started epic in it can be rewritten and signed off, and a hand check of the rewritten epics finds no requirement missing that the coverage report did not flag. The fixture epic rewrites and is accepted through every one of the six variants, each released through its runtime's distribution channel ([§16A.7](#16a7-testing-and-release)) |
| **2. Custom fields and polish** | Custom field discovery and mapping ([§11](#11-mapping-additional-fields)), section extraction, mapping presets, Jira-key search, *Exclude imported history* on metrics, which excludes by the task's import link ([§14.4](#144-history)) | A project whose acceptance criteria and team data live in custom fields imports them into Stride fields |
| **3. Moving while working** | Re-sync with the per-field snapshot and conflicts (including stale drafts, **Changed after rewrite** and **Deleted in Stride**), Finish migration, the optional "moved to Stride" marker, import into an existing board with its own undo ([§13.7](#137-undo)), OAuth 2.0 (3LO) | A team can import, keep working in Jira for two weeks, re-sync, and finish with no lost changes |
| **4. Jira Data Center** | `jira_dc` adapter, PAT auth, REST v2, wiki markup, self-hosted private-address switch | A Data Center instance imports through the same pipeline |

---

## 24. Decisions needed

These were the choices the design could not make on its own. Decisions 1–18
were settled on 2026-10-30: decisions 3 and 13 were changed to
Organization-only, and every other recommendation was accepted as written.
Decisions 19–23 were settled on 2026-11-10, after an exploratory review of
this design found questions the corrections could not answer alone.

| # | Question | Decision |
|---|---|---|
| 1 | Where should To Do work land: Backlog or Ready? | **Backlog**, with an opt-in for Ready ([§10.3](#103-status-to-column)). It is the only default that cannot hand an agent a context-free task |
| 2 | Should the import offer custom boards as well as AI-optimized ones? | **No**: AI-optimized boards only ([§7.2](#72-ai-optimized-board-or-custom-board)). The fixed five columns are what agents and the rewrite rely on, and they remove the column-stage guessing a custom layout would need. An explicit stage per column is no longer needed for imports |
| 3 | Is import available on every plan? | **No: Organization only.** Import, re-sync and mapping presets are the `:imports` plan feature; when plans are enforced only a workspace in an Organization can start an import ([§19](#19-permissions-and-plans)) |
| 4 | Where does unmapped data live? | **On the import link**, shown in a collapsed panel ([§12](#12-data-that-does-not-map)), not in the description or `technical_details` |
| 5 | Should stories with sub-tasks become goals? | **No by default** (flatten under the epic), with the option on the mapping page ([§10.2](#102-hierarchy)) |
| 6 | One transaction per board, or chunked writes with a hidden board? | **One transaction**, measured in Phase 1; chunked only if measurement demands it ([§16.5](#165-long-transactions)) |
| 7 | Should imported history count in metrics? | **Yes by default**, with *Exclude imported history* on the metrics pages in Phase 2 ([§14.4](#144-history)). Decision 23 says how imported work counts on AI-optimized boards |
| 8 | Should Stride ever write to Jira? | **Only** the opt-in "moved to Stride" marker at finish, Phase 3 ([§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)) |
| 9 | How long is closed work imported by default? | **Last 90 days** to Done ([§6.2](#62-completed-and-cancelled-work)) |
| 10 | Should the roadmap item be renamed now that Linear is out of scope? | **Yes**: *Import from Jira*, so the roadmap does not promise Linear |
| 11 | Should Stride recommend the rewrite for not-started work, or the direct import? | **The rewrite**, always, for every epic with not-started work, including the not-started part of an epic in progress ([§6A.2](#6a2-the-choice-and-the-recommendation)). There is no setting to turn it off. The direct import stays a per-epic choice on the page and is always used for started and done work |
| 12 | Where does the rewrite's model run: in the team's agent, or on Stride's servers? | **In the team's agent** ([§6A.5](#6a5-how-a-rewrite-runs)). It has the repository the agent-facing fields need, and Stride never holds a model provider's credentials or decides where Jira text is sent |
| 13 | Should the rewrite be on every plan? | **No: Organization only**, under the same `:imports` feature as the import ([§19](#19-permissions-and-plans)). The rewrite API endpoints check it too, so a board that has left its Organization cannot be rewritten into |
| 14 | Should rewritten tasks inherit assignees from Jira? | **No**: written unassigned, with the Jira assignees on the sign-off page to assign by hand ([§6A.7](#6a7-sign-off)). One task often covers issues held by different people |
| 15 | Should attachments be copied, or only linked? | **Copied** by default, where the board's plan allows it ([§14.3](#143-attachments)), with **Link to Jira only** as the choice. A link needs a Jira login, and stops working when the team leaves Jira |
| 16 | Should files Stride cannot store (archives, office documents, video) be converted or bundled? | **No**: they stay links, listed by reason. Widening the allow-list is a change to [Task Attachments](ATTACHMENTS-DESIGN.md), not to the import |
| 17 | Should the rewrite's agent side go in the Stride workflow plugin or in a plugin of its own? | **Its own plugin, `stride-import`** ([§16A.1](#16a1-why-a-new-plugin)). A team uses it once; the workflow plugin is paid for by every session; the rewrite reads untrusted Jira input and claims no tasks; and it must work next to the lite plugins too |
| 18 | Which runtimes get a variant, and when? | **All six** (Claude Code, Codex CLI, GitHub Copilot CLI, Gemini CLI, OpenCode and Pi), **in Phase 1** ([§16A.3](#16a3-the-variants)). The lite plugins share their runtime's variant. Shipping some runtimes later would leave their teams with only the direct import that Stride advises against |
| 19 | Who can run an import in an Organization workspace: org-admins only, or org-admins and workspace members? | **Settled on 2026-11-10: enabled org-admins of the Organization only.** They alone create connections and start, re-sync, retry, undo or finish an import, and choose paths and sign off rewrites. Members ask an org-admin. An Organization workspace has no owner role, and an import invites people, adds them to boards and holds a Jira token, which are org-admin decisions. The creator of a run or connection has no right of their own: every right is read from the person's current role at call time ([§19](#19-permissions-and-plans)) |
| 20 | Where does the actor of an imported history row go: the import link's changelog, or a new column on `task_history`? | **Settled on 2026-11-10: the import link's changelog.** History rows are written as Stride writes them today, with no actor, and the Jira actor of each change is kept in the import link's unmapped changelog ([§14.4](#144-history)). No existing table changes ([§17](#17-database-changes)) |
| 21 | How does Pi load the import plugin's agents: a dispatch extension inside `stride-pi-import`, or an extensible `stride-pi` registry? | **Settled on 2026-11-10: an extensible `stride-pi` registry.** A `stride-pi` task first makes `extensions/subagent-dispatch/agents-registry.ts`, a closed list of five agents today, accept agents registered by other packages, and that `stride-pi` release ships before `stride-pi-import`. Pi has no ideation or security-review family to follow, so `stride-pi-import` is the first Pi companion package ([§16A.8](#16a8-pi-the-first-companion-package)) |
| 22 | How much of the coverage check to build beyond the id check? | **Settled on 2026-11-10: all three parts.** Stride computes paragraph-level source ids for description prose and comments, so prose can be cited; Stride computes the warnings it can check (prose cited only by key, one task citing many keys, a task sharing no terms with what it cites); and the person signing ticks each Jira issue as reviewed. Reviewer findings and the `independent` flag are shown as the agent's claim and never trusted. The id check proves citation, not delivery. Source ids are content-derived (a hash of the normalised line), and coverage is recomputed against the current bundle at sign-off ([§6A.5](#6a5-how-a-rewrite-runs), [§6A.6](#6a6-the-second-pass-a-coverage-report), [§6A.7](#6a7-sign-off)) |
| 23 | Should imported work count in the AI board's cycle and wait times, which read `claimed_at`? | **Settled on 2026-11-10: yes.** Imported done and in-progress tasks get `claimed_at` from the issue's first move into an *In Progress* status in the Jira changelog, and none if it never moved. *Exclude imported history* (Phase 2) excludes by the task's import link. Decision 7 stays true ([§14.4](#144-history)) |

---

## Appendix A: Jira API reference

The calls the Jira Cloud adapter makes. Rate limits and page sizes change, so
the adapter reacts to `429` and `Retry-After` rather than hard-coding a rate,
and these should be re-checked against Atlassian's documentation when Phase 1
starts.

| Purpose | Endpoint |
|---|---|
| Test connection | `GET /rest/api/3/myself`, `GET /rest/api/3/serverInfo` |
| Projects | `GET /rest/api/3/project/search` |
| Boards and their layout | `GET /rest/agile/1.0/board`, `GET /rest/agile/1.0/board/{id}/configuration` (columns → statuses, filter id) |
| Board filter | `GET /rest/api/3/filter/{id}` (the board's JQL) |
| Field catalogue | `GET /rest/api/3/field` |
| Priorities, statuses, issue types, link types | `GET /rest/api/3/priority` (or `GET /rest/api/3/priority/search`, see below), `GET /rest/api/3/status`, `GET /rest/api/3/issuetype`, `GET /rest/api/3/issueLinkType` |
| Counts | `POST /rest/api/3/search/approximate-count` |
| Issues | `POST /rest/api/3/search/jql` with `nextPageToken` pagination, `fields=*all`, `expand=changelog` |
| Comments (when the embedded list is cut short) | `GET /rest/api/3/issue/{id}/comment` (paged) |
| Attachment files | Listed in each issue's `attachment` field; content from `GET /rest/api/3/attachment/content/{id}?redirect=false`, so the file comes from the site itself rather than a redirect to another host |
| Changelog (when the embedded list is cut short) | `GET /rest/api/3/issue/{id}/changelog` (paged) |
| Sprints | Read from the sprint custom field on each issue; `GET /rest/agile/1.0/board/{id}/sprint` for sprint states |
| Write-back marker (Phase 3, opt-in) | `POST /rest/api/3/issue/{id}/comment`, `PUT /rest/api/3/issue/{id}` (labels) |

The older `GET /rest/api/3/search` endpoint is being retired by Atlassian in
favour of `/search/jql`, so the adapter uses `/search/jql` only.

**To check against Jira before Phase 1.** No part of this design was checked
against a live Jira site. The design is written so that each of these works
either way, but the Phase 1 spike answers them before the code that depends on
them is built:

| Question | Where it matters | If the answer is no |
|---|---|---|
| How does an ADF media node name its attachment? It may carry only a Media Services id and collection, with no file name | [§14.3](#143-attachments), Appendix B | Fall back to the `alt` text, then to *[image] (attached)* with the file on the task, and count the unmatched nodes |
| Does an issue that reaches Done with no resolution have a null `resolutiondate`? | [§9.1](#91-standard-jira-fields) | The fallback chain is harmless when Jira always sets it |
| Are JQL date literals read to the minute, in the account's profile time zone? | [§13.5](#135-re-sync-when-the-team-keeps-working-in-jira) | The one-day overlap still covers a UTC reading |
| Is `GET /rest/api/3/priority` deprecated in favour of `/priority/search`, and does a per-project priority scheme change "the site's own order"? | [§10.4](#104-priority) | Use the endpoint that still works, and order by the first scheme that lists the value |
| When is `emailAddress` returned? | [§15.1](#151-matching) | Manual matching is already the main path |
| Are labels case-sensitive in Jira? | [§10.6](#106-labels-and-colours) | Merging ignoring case is then a no-op |
| Does `attachment/content/{id}?redirect=false` always return the bytes from the site itself? | [§14.3](#143-attachments) | Any redirect is already an error, so the file stays a link |
| What does the site's time-tracking setting say a day is? | [§10.5](#105-complexity) | 8 hours |

---

## Appendix B: rich text conversion rules

Output is plain text with Markdown conventions, kept readable as plain text
because that is how Stride shows it today. Text is not escaped: a line that
starts with `#`, `-` or `>`, or link text holding `]`, is written as it is,
because Stride shows plain text. If Stride later renders Markdown, escaping is
added then. The node list is checked against Atlassian's ADF reference in the
Phase 1 spike ([Appendix A](#appendix-a-jira-api-reference)).

| Atlassian document node | Output |
|---|---|
| `paragraph` | Text, blank line after |
| `heading` (level n) | `#` × n, space, text |
| `bulletList` / `orderedList` / `listItem` | `- ` / `1. `, nested lists indented two spaces per level |
| `taskList` / `taskItem` | `- [ ] ` / `- [x] ` |
| `codeBlock` | Fenced block with the language if given. The fence is one backtick longer than the longest run of backticks inside the code, and at least three |
| `blockquote` | `> ` on each line |
| `panel` (info, note, warning, error, success, custom) | `> **Note:** ` + content; a custom panel's colour is dropped |
| `decisionList` / `decisionItem` | `- Decision: ` + text |
| `layoutSection` / `layoutColumn` | Each column's content in order, separated by a blank line |
| `extension`, `bodiedExtension`, `inlineExtension` (macros) | A bodied extension's content; otherwise `[macro: <extensionKey>]`, counted in the report under *repaired* |
| `placeholder` | Dropped |
| `rule` | `---` |
| `table` | Markdown table; merged cells repeated; tables wider than 10 columns become one line per row |
| `text` with marks | `strong` → `**…**`, `em` → `_…_`, `code` → `` `…` ``, `strike` → `~~…~~`, `link` → `[text](href)`; `underline`, `textColor`, `backgroundColor` and `subsup` dropped |
| `mention` | `@Display Name` |
| `emoji` | Its Unicode character, else `:shortName:` |
| `inlineCard` / `blockCard` / `embedCard` | The URL, rewritten if it points to an imported issue ([§14.1](#141-descriptions)) |
| `mediaSingle` / `mediaGroup` / `media` / `mediaInline` | `[image: <name>] (attached)` or `[file: <name>] (attached)` when the file was copied ([§14.3](#143-attachments)); otherwise `[image: <name>](<Jira URL>)` or `[file: <name>](<Jira URL>)`. With no name to match, `[image] (attached)` or `[file] (attached)` |
| `status` (lozenge) | `[<text>]` |
| `date` | ISO date |
| `expand` / `nestedExpand` | Its title in bold, then its content |
| `hardBreak` | Newline |
| Unknown node | Its text content, and a count in the report under *repaired* |

NUL bytes and invalid UTF-8 are removed from all converted text, because the
database columns cannot hold them.

