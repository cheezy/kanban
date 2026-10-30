# Import from Jira — Implementation Design

**Roadmap item:** Import from other tools → *Import from Linear and Jira* ([ROADMAP](../../ROADMAP.md)). This design covers **Jira only**; Linear is out of scope.
**Status:** Proposed design, not yet decomposed into tasks
**Date:** 2026-10-28

This document describes how a team brings its existing work from Jira into
Stride: how Stride connects to Jira, how the team chooses what to bring
across, how every field is mapped, how the team maps extra fields of its own,
what happens to data Stride has no place for, and how work that is already in
progress survives the move. It ends with the architecture, the database
changes, the screens, the security rules, the tests and a phased delivery
plan.

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
27. [Appendix C: AI-assisted rewrite of work not yet started](#appendix-c-ai-assisted-rewrite-of-work-not-yet-started)

---

## 1. Goals and non-goals

### Goals

- A team can move a Jira project or board into Stride without losing titles,
  descriptions, comments, labels, status, assignees, hierarchy or blocking
  links.
- The person importing sees **exactly** what will happen before anything is
  written: counts, a sample of tasks as Stride will show them, every field that
  will not come across, and every person who could not be matched.
- Standard fields map automatically with sensible defaults; the importer can
  override every default and can map the team's own custom fields onto Stride
  fields.
- Nothing from Jira is silently thrown away. Data Stride has no field for is
  kept with the task and can be read and downloaded.
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
- **Attachment files.** Stride has no attachments yet (it is its own roadmap
  item). Imported tasks link to the files in Jira; see [§14.3](#143-attachments).
- **Creating Stride accounts.** People are matched to existing accounts or
  invited; the import never creates a user.

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

---

## 3. What already exists that the import builds on

The import is new code, but most of its hard parts already have a pattern in
the app. Each new module below names the one it follows.

| Need | Existing code | How the import uses it |
|---|---|---|
| Writing many untrusted rows in one go | `Kanban.Workspaces.Export.Importer` ([Workspace Export](../workspace-export.md)) | Same rules: every row goes through its schema changeset, context functions that broadcast, notify, emit telemetry or enforce WIP limits are skipped, users are matched by email and never created, one transaction per board, a report lists everything skipped or repaired |
| Repairing rows that break a current rule | `Kanban.Workspaces.Export.Importer.Repairs` | Same idea for over-long label names and comments |
| Storing a credential that must be read back | `Kanban.Integrations.SecretBox`, `Kanban.Integrations.EncryptedString` | The Jira API token is an `EncryptedString` column |
| Calling a URL a user typed without reaching internal hosts | `Kanban.Webhooks.UrlGuard` | Every request to a Jira site goes through it |
| Background jobs | Oban, with queues in `config/config.exs` | New `imports` queue, concurrency 2 |
| HTTP | `Req` (project rule), injectable client as in `Kanban.GitHub` | The Jira client uses `Req` and `Req.Test` stubs |
| Task identifiers | `Kanban.Tasks.Identifiers.pregenerate_task_identifiers/2` | Identifiers are generated per board under the board's advisory lock |
| Two-level hierarchy | `Kanban.Tasks.Task.HierarchyValidations` | Goals contain only work and defect tasks; Jira sub-tasks are flattened ([§10.2](#102-hierarchy)) |
| Column stage | `Kanban.Columns.Stage` | Decides whether a custom column means not started, in progress or done ([§7.2](#72-ai-optimized-board-or-custom-board)) |
| Labels | `Kanban.Labels`, `Kanban.Labels.Label` (nine colour tokens, 40-character names) | Jira labels and components become board labels ([§10.6](#106-labels-and-colours)) |
| Archiving with a reason | `Kanban.Tasks.Archiving` (`:completed`, `:duplicate`, `:wontdo`, `:deferred`, `:cancelled`) | Won't-do, cancelled and duplicate issues ([§13.2](#132-what-happens-to-each-kind-of-item)) |
| Feature gating | `Kanban.Plans` | Member caps on free boards ([§19](#19-permissions-and-plans)) |
| Credential detection | `Kanban.Tasks.CredentialShapes` | Warns when imported text looks like it carries a secret ([§20](#20-security-and-privacy)) |
| Telemetry | `Kanban.Telemetry.emit/3`, `Kanban.Telemetry.Catalog` ([Telemetry](../telemetry.md)) | New `import` events ([§21](#21-telemetry-audit-log-and-the-import-report)) |

---

## 4. The import at a glance

```text
 Connect ──► Choose scope ──► Fetch ──► Map ──► Preview ──► Import ──► Report
   │             │              │        │         │          │          │
 site,        projects,      pull     statuses,  counts,    write in   links to
 email,       boards,        issues   types,     sample     one        boards,
 token,       epics,         into     people,    cards,     transaction unmatched
 test it      filters, JQL   staging  labels,    warnings   per board   people,
                                      fields                            downloads
                                                                         │
                                       Re-sync changes ◄─────────────────┤
                                       Finish migration ◄────────────────┘
```

The run is a state machine stored in `import_runs.status`:

```text
draft → fetching → fetched → importing → imported → finished
            │          │          │          │
            └──────────┴──────────┴──► failed / cancelled
imported → resyncing → imported      (any number of times until finished)
imported → undone                    (deletes what the run created)
```

Fetching and importing are separate steps on purpose. Fetching copies the
Jira issues into a staging table once, so the importer can change the
mapping, preview it and fix warnings any number of times without calling Jira
again. Only **Import** writes tasks.

---

## 5. Connecting to Jira

### 5.1 Jira Cloud

| | Phase 1 | Phase 3 |
|---|---|---|
| Method | Site URL + account email + API token (HTTP basic auth) | OAuth 2.0 (3LO) app ("Stride Import") |
| Site | `https://<name>.atlassian.net`, typed by the importer | Chosen from `accessible-resources` after consent |
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
through config (see [§20](#20-security-and-privacy)).

### 5.3 Where credentials live and for how long

- Stored in `import_connections.credential` as an `EncryptedString`
  (`SecretBox` ciphertext). Never logged, never in telemetry metadata, never in
  the report, never in a workspace export, never shown again after it is saved
  (the form shows only "a token is saved, added by Ana on 3 Oct").
- A connection belongs to a **workspace** and can be used only by the person
  who created it and by the Organization's org-admins.
- **Deleted when the run is finished** ([§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)).
  An unfinished run's credential is deleted automatically after 30 days without
  a re-sync, and the run is marked finished. The importer can delete it at any
  time from the run page.
- If `secret_key_base` is rotated, the credential loads as `nil` and the run
  page asks for it again. This is the existing `EncryptedString` behaviour.

---

## 6. Choosing what to import

Scope is chosen in three layers: containers, then (optionally) epics inside
them, then filters. The page shows live counts as each choice changes. Counts
come from Jira's approximate-count endpoint, not a full fetch.

### 6.1 Containers, epics and filters

| Layer | Choices | Notes |
|---|---|---|
| Projects or boards | Either **projects** (everything in them) or **boards** (everything matching the board's saved filter), each with its issue count | Choosing a board also offers its column layout as the Stride column layout ([§7.2](#72-ai-optimized-board-or-custom-board)). A board whose filter reaches into several projects shows which ones |
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
whatever the choice, so no open work loses its goal.

### 6.3 Size limits

| Limit | Value | When it is reached |
|---|---|---|
| Issues per run | 20,000 | The scope page refuses to continue and suggests splitting by project, epic or date |
| Comments per issue | 500 (newest kept) | Older comments are counted in the report and stay in Jira |
| Text per comment | 10,000 characters (the existing comment cap) | Shortened, with a note, and listed under *repaired* |
| Staged data per run | 500 MB | The fetch stops and fails with a clear message |

The limits are config values (`config :kanban, Kanban.Imports, ...`), so a
self-hosted operator can raise them.

---

## 7. Where imported work lands

### 7.1 New boards, by default

Each run creates **new boards** in the current workspace. The importer chooses
one of:

- **One board per container** (default): one Stride board per Jira project or
  board, named after it ("Payments (from Jira)"), editable.
- **One board for everything**: all chosen containers on one board, with a
  label per project so they can be told apart.

Importing **into an existing board** comes in Phase 3. It needs collision rules
(existing labels, existing columns, identifier ranges) that new boards do not,
and new boards make undo trivial.

### 7.2 AI-optimized board or custom board

| | AI-optimized board (default) | Custom board |
|---|---|---|
| Columns | The fixed five: Backlog, Ready, Doing, Review, Done | One column per Jira board column, in the board's order (or one per status category when projects were chosen) |
| Agents | Agents can claim from Ready once a human moves work there | Agents only claim from a column named exactly "Ready" |
| Status mapping | Every Jira status maps to one of the five ([§10.3](#103-status-to-column)) | Each Jira status maps to the column the Jira board puts it in, editable |
| Good for | Teams moving to Stride to work with agents | Teams that want their board to look the way it did |

**Custom boards need a stage check.** `Kanban.Columns.Stage` decides from
column names whether a column means *not started*, *in progress* or *done*.
Names it does not know are classified by position: before the first
Doing/Review column they are not started, after it they are in progress, and
on a board with neither only the first column is not started. A Jira layout
of `Backlog | Selected for Development | In Progress | Done` would therefore
treat *Selected for Development* as **in progress**, and a task dropped there
would be marked started.

The mapping page runs `Stage.classify/1` over the proposed columns and shows the
stage each one will get next to the Jira status category of the statuses it
holds. Where they disagree, the page shows a warning and offers one fix:
rename the column to a known name (`Ready`, `Doing`), or reorder it. A
schema change that stores an explicit stage on each column would remove this
problem for good. It is listed under [§24](#24-decisions-needed) rather than
assumed here.

### 7.3 Identifiers

Imported tasks get normal Stride identifiers (`W12`, `D3`, `G2`). They are not
named after the Jira keys, because agents, hooks, dependencies and the API
all rely on the `W`/`D`/`G` prefixes. The Jira key (`PAY-88`) is kept on the
import link and is shown on the task as **Imported from PAY-88**, linking to
the issue. Searching for a Jira key on the board finds the task (Phase 2).

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
| `status` | `%{id, name, category}` | `category` is `:todo`, `:in_progress`, `:review` or `:done`, where `:review` comes from the name rule in [§10.3](#103-status-to-column) |
| `resolution` | string or nil | |
| `priority` | `%{id, name, rank}` | `rank` 0 (none) to 4 (highest), from the site's priority order |
| `estimate` | number or nil | Story points, from whichever custom field the site uses ([§10.5](#105-complexity)) |
| `time_estimate_seconds` | integer or nil | `timeoriginalestimate` |
| `labels` | `[String.t()]` | |
| `components`, `fix_versions` | `[%{name, release_date}]` | |
| `assignee`, `reporter`, `creator` | `%{account_id, name, email}` or nil | `email` is often nil ([§15](#15-people-and-board-membership)) |
| `parent_external_id` | string or nil | The epic or the parent of a sub-task |
| `links` | `[%{type, direction, external_id}]` | `type` is `:blocks`, `:duplicates`, `:relates`, `:clones` or the custom link name |
| `created_at`, `updated_at`, `resolved_at` | datetimes | |
| `due_date` | date | |
| `sprint` | `%{name, state, start_date, end_date}` or nil | The issue's current or latest sprint |
| `comments` | `[%{external_id, author, body, created_at, restricted?}]` | |
| `attachments` | `[%{filename, url, size, mime_type}]` | |
| `transitions` | `[%{field, from, to, at, actor}]` | From the changelog |
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
| `issuelinks` of type *Duplicate*, resolution *Duplicate* | archived `:duplicate` + `duplicate_of_id` | [§13.2](#132-what-happens-to-each-kind-of-item) |
| `comment` | task comments | [§14.2](#142-comments) |
| `created` | `inserted_at` | Kept, so ages and cycle times stay true |
| `resolutiondate` | `completed_at` | Required when status is completed (existing rule) |
| `updated` | stored on the import link | Used by re-sync; the task's own `updated_at` is the import time |
| Browse URL | import link | Shown as **Imported from** |

### 9.2 Other Jira fields and their defaults

| Jira field | Default | Can be mapped to |
|---|---|---|
| `components` | Label `component: <name>` | label |
| `fixVersions` | Label `release: <name>` | label, delivery target (on goals) |
| `versions` (affects versions) | Unmapped data | label, description section |
| Sprint (custom field) | Label `sprint: <name>` for active and future sprints; closed sprints kept as unmapped data | label |
| `duedate` | Unmapped data | description section, label |
| `environment` | Description section **Environment** for bugs, otherwise unmapped data | `where_context`, description section |
| Story points | `complexity` and kept as unmapped data | `complexity` |
| `timeoriginalestimate`, `timeestimate`, `timespent`, `worklog` | Unmapped data | — ([§12](#12-data-that-does-not-map)) |
| `resolution` | Drives Done vs archived ([§13.2](#132-what-happens-to-each-kind-of-item)) | — |
| `attachment` | Links on the import link ([§14.3](#143-attachments)) | description section |
| Development info (linked branches, commits, pull requests) | Links on the import link, where the site exposes them | description section |
| `watches`, `votes` | Dropped and counted | — |
| `security` (issue security level) | Issue skipped unless the importer opts in ([§20](#20-security-and-privacy)) | — |
| `rank` | Used to order tasks inside each column | position |
| Every other custom field | Unmapped data, unless the importer maps it ([§11](#11-mapping-additional-fields)) | see [§11.2](#112-what-a-field-can-be-mapped-to) |

### 9.3 Stride fields Jira does not fill

Stride's agent-facing fields have no equivalent in Jira: `key_files`,
`verification_steps`, `testing_strategy`, `patterns_to_follow`, `pitfalls`,
`why`, `what`, `where_context`, `security_considerations`,
`required_capabilities`, `behaviour_test_matrix` and the rest. They are left
empty unless the importer maps a custom field to them ([§11](#11-mapping-additional-fields)).

That is why imported work lands in **Backlog**, not Ready ([§10.3](#103-status-to-column)):
a task an agent can claim needs this context. After the import the report
offers **Enrich these tasks**. This is a link to the existing task-enrichment
flow (`stride:task-enricher`), run task by task by a human or an agent before
the work is promoted to Ready. The import does not run enrichment itself.

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
| A custom type | Chosen on the mapping page; `work` until chosen |
| A type above epic (Jira Premium levels such as *Initiative*) | Not imported as a task. Its name becomes a label `initiative: <name>` on each goal under it |

### 10.2 Hierarchy

Stride has exactly two levels: a goal contains work and defect tasks, and a task
inside a goal has no children (`HierarchyValidations`). Jira goes deeper, so it
is flattened:

| Jira shape | Stride result |
|---|---|
| Epic → story/task/bug | goal → work/defect |
| Epic → story → sub-task | goal → work (story) and work (sub-task), side by side under the goal. The sub-task's description starts with *Part of W14: <story title>*, and the import link records the original parent |
| Story → sub-task, with no epic | Default: story and sub-task are both top-level tasks, and the sub-task starts with *Part of W14*. Option **Stories with sub-tasks become goals**: the story becomes a goal holding its sub-tasks |
| Initiative (Premium) → epics | Initiatives are not imported; each epic becomes its own goal with an `initiative:` label |
| Epic whose children land on different destination boards (one board per container, and an epic with children in several projects) | The goal is created on the board holding most of its children; children on other boards lose their parent link, and the report lists them |

### 10.3 Status to column

Default for an **AI-optimized board**:

| Jira status | Stride column | Stride `status` | Notes |
|---|---|---|---|
| *To Do* category, status named *Backlog* or in the board's backlog | Backlog | `open` | |
| Any other *To Do* category status (*To Do*, *Selected for Development*, *Open*) | **Backlog** | `open` | Not Ready: see below. Option **Put To Do work in Ready** |
| *In Progress* category | Doing | `in_progress` | [§13](#13-work-already-in-progress) |
| Any status whose name contains *review*, *QA*, *testing* or *verify* | Review | `in_progress` | Name rule is editable; `needs_review: true`, `review_status: :pending` |
| *Done* category with a "done" resolution (*Done*, *Fixed*, *Resolved*, or none) | Done | `completed` | |
| *Done* category with *Won't Do*, *Won't Fix*, *Cannot Reproduce*, *Declined*, *Cancelled* | archived | `completed` | [§13.2](#132-what-happens-to-each-kind-of-item) |
| Resolution *Duplicate*, or a *duplicates* link | archived `:duplicate` | `completed` | |

**Why To Do work goes to Backlog.** Agents claim the next task from the
column named Ready (`Kanban.Tasks.AgentQueries`). If imported work landed in
Ready, any agent connected to the board could claim a task whose description
was written for a human and that has none of the context in [§9.3](#93-stride-fields-jira-does-not-fill),
the moment the import finished. Backlog matches how Stride already treats new
work: a human reviews it and promotes it.

Goal columns are not mapped. A goal's column follows its children
(`Kanban.Tasks.GoalTargetColumn`), so after the children are written the
import asks the existing goal-placement code where each goal belongs. An epic
with no imported children is placed by its own status, using the table above.

For a **custom board** the default is the column the Jira board configuration
puts the status in, when a board was chosen, or the column for the status's
category otherwise.

### 10.4 Priority

| Jira (default priority scheme) | Stride |
|---|---|
| Highest, Blocker | `critical` |
| High, Critical | `high` |
| Medium | `medium` |
| Low, Lowest, Minor, Trivial | `low` |
| No priority | `medium` (Stride's default); the report counts them |

Jira sites can rename and add priorities, so the list is built from
`GET /rest/api/3/priority` and every value found is listed for mapping, in the
site's own order.

### 10.5 Complexity

Stride's `complexity` is `small`, `medium` or `large`. Story points live in a
custom field whose id differs per site (often named *Story Points* or *Story
point estimate*); the adapter proposes it from the field catalogue and the
importer confirms it. The default thresholds are editable:

| Jira value | Stride |
|---|---|
| Points 0–2, or original estimate under 4 hours | `small` |
| Points 3–5, or 4 hours to 2 days | `medium` |
| Points 8 or more, or over 2 days | `large` |
| No estimate | `small` (the schema default), counted in the report |
| Epics | `large`, whatever the estimate |

The raw estimate is always kept as unmapped data, so nothing is lost when the
thresholds are wrong.

### 10.6 Labels and colours

- Labels are board-scoped, so each destination board gets its own copy of the
  labels its tasks use.
- Names longer than 40 characters are shortened. Names that become identical
  after shortening are merged and listed under *repaired*.
- **Colour.** Jira labels and components have no colour, so they get gray.
  Labels added by mapping rules get one colour per prefix (`release:` blue,
  `sprint:` teal, `component:` purple), so they are easy to tell apart. The
  importer can change any colour on the mapping page.
- Labels added by mapping rules (`release:`, `sprint:`, `component:`,
  `initiative:`, `blocked`, the per-project label) are listed on the mapping
  page with a checkbox each, so a team that does not want them can switch
  them off.

### 10.7 Dependencies and other relations

| Jira link | Stride result |
|---|---|
| A *blocks* B (both imported, both work/defect, same destination board) | `B.dependencies` gains A's identifier |
| Either end is an epic, the other end is not imported, or the ends are on different boards | Not a dependency; kept in unmapped data on both import links as *Blocked by PAY-12 (not imported)* |
| A cycle of *blocks* links | Stride refuses circular dependencies. The import drops the link that closes the cycle, and the report names it |
| *Duplicate* | [§13.2](#132-what-happens-to-each-kind-of-item) |
| *Relates*, *Cloners*, and any custom link type | Unmapped data on both ends, with a link to the other issue (or its Stride identifier, if imported) |

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
| `pitfalls`, `out_of_scope`, `technology_requirements`, `security_considerations` | text, rich text, multi select, checkbox | Split into list items by line, list item or selected option. `security_considerations` entries are capped at 255 characters each (existing column limit) |
| `complexity` | number, single select | Thresholds (numbers) or value table (selects) |
| `priority` | single select | Value table |
| `type` | single select | Value table |
| `required_capabilities` | multi select | Value table into the allowed capability list; unknown values dropped and counted |
| Labels | single select, multi select, cascading select, checkbox, version, user | One label per value, with an optional prefix (`customer: Acme`) |
| Description section | anything | Appended to the description under a heading named after the field |
| `technical_details` key | anything | Stored as a key in the task's `technical_details` JSON object, value kept as typed JSON |
| Delivery target (goals only) | version, date | A version with a release date, or a date field on the epic, becomes a target named after it |
| Do not import | anything | Not copied to the task, still kept as unmapped data ([§12](#12-data-that-does-not-map)) |

Some fields are paid-only on a paid plan (`telemetry_event`,
`metrics_to_track`, per `Kanban.Plans.locked_task_fields/0`). They are offered
as targets only when the destination board will be in an Organization
workspace.

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
| **Kept as unmapped data** on the import link | Every remaining field value, link, attachment link, worklog total, sprint history and original parent | The **Imported from** panel on the task: collapsed by default, a readable list, plus **Download Jira data** (JSON) |
| **Counted, not kept** | Votes, watchers, rank values | The report shows how many of each were left out |
| **Skipped**, with a reason | Restricted issues and restricted comments ([§20](#20-security-and-privacy)), issues beyond the limits ([§6.3](#63-size-limits)) | The report, issue by issue |

**Why not put unmapped data in the description or in `technical_details`?**
The description is what people and agents read first, so a long tail of
*Customer: Acme / Sprint 12 / Story points: 5* lines would push the actual
description down. `technical_details` is handed to agents as implementation
context, so Jira metadata there would be noise in every agent's prompt. The
import link keeps the data next to the task without putting it in front of
anyone. An importer who wants a field in the description maps it to a
**description section** explicitly.

Unmapped data per issue is capped at 64 KB. Anything above that is cut at the
cap, flagged as *truncated* in the panel, and still available in Jira.

---

## 13. Work already in progress

### 13.1 The principles

1. **Work keeps its place.** Something being worked on stays on the board in a
   column that means "in progress", with the same person on it.
2. **Imported work is never claimable by surprise.** Agents claim only from
   Ready, and nothing is imported into Ready unless the importer asks for it.
   Imported in-progress work has an owner, not an agent claim.
3. **Nobody is notified by the import.** No assignment emails, no mention
   notifications, no review requests, no webhooks, no Slack messages. The
   board reloads once when the import finishes.
4. **Jira keeps working until the team switches.** Re-sync brings changes
   across; the team chooses when to stop.

### 13.2 What happens to each kind of item

| Jira state | Column | Task fields | Notes |
|---|---|---|---|
| To Do | Backlog (Ready if the importer opts in) | `status: :open` | |
| In Progress, assignee matched | Doing | `status: :in_progress`, `assigned_to_id` set, **no** `claimed_at` / `claim_expires_at` | A claim is an agent's 60-minute lease; a person working on something holds an assignment, not a claim. No expiry job will move it |
| In Progress, assignee not matched | Doing | `status: :in_progress`, unassigned | Listed in the report under **In progress with nobody on it**, so someone picks it up |
| In Progress, unassigned in Jira | Doing | as above | Same report section |
| In review | Review | `status: :in_progress`, `needs_review: true`, `review_status: :pending`, `review_requested_at` = when it entered the status (from the changelog), else import time | No review-requested notification is sent |
| Done with a "done" resolution | Done (or archived, per [§6.2](#62-completed-and-cancelled-work)) | `status: :completed`, `completed_at` = `resolutiondate`, `completed_by_id` = matched assignee | |
| Won't Do, Won't Fix, Declined, Cannot Reproduce | archived `:wontdo` | `archive_note` = *Imported: <resolution>* | `archive_note` is required for `:wontdo` (existing rule) |
| Cancelled | archived `:cancelled` | `archive_note` as above | |
| Duplicate of an imported issue | archived `:duplicate` | `duplicate_of_id` = the imported original | |
| Duplicate of an issue not imported | archived `:wontdo` | `archive_note` = *Imported: duplicate of PAY-12* | `:duplicate` requires a `duplicate_of_id`, which does not exist here |
| A status named *Blocked*, or a *Flagged* issue | the column of its category | `status` per category | Stride's `:blocked` status is not used, because Stride sets it from dependencies. The blocking issue becomes a dependency where possible ([§10.7](#107-dependencies-and-other-relations)), and the label `blocked` is added |

### 13.3 Sprints in flight

Stride has no sprints. The active sprint becomes a label (`sprint: Sprint 14`)
on the issues in it, so the team can filter the board to "what we committed
to" during the move. Future sprints get labels too; closed sprints are kept as
unmapped data only. Teams that plan by release can map a fix version with a
release date to a **delivery target** on the goals instead ([§11.2](#112-what-a-field-can-be-mapped-to)).

### 13.4 Agents on the new board

- A board-scoped agent token cannot reach a board created by the import, but
  a **workspace-scoped** token can (API tokens belong to a board or a
  workspace). Nothing can be claimed during the import anyway, because the
  board does not exist until its transaction commits and nothing is written to
  Ready by default.
- After the import, an agent can claim only what a human moves into Ready.
  The run report links to the board's Backlog filtered to the imported tasks,
  with a reminder to add the context agents need before moving work to Ready
  ([§9.3](#93-stride-fields-jira-does-not-fill)).
- If the importer turned on **Put To Do work in Ready**, the preview shows a
  warning naming the number of tasks agents will be able to claim the moment
  the import finishes.

### 13.5 Re-sync: when the team keeps working in Jira

Most teams cannot stop work for a migration. Re-sync lets them import, try
Stride, and bring Jira's changes across again until they are ready to switch.

**Re-sync changes** on an `imported` run:

1. Fetches issues in the run's scope **updated since the last fetch**
   (`updated >= "<last fetch>"` added to the run's JQL), using the stored
   credential.
2. For each fetched issue:
   - **New in Jira** → created, exactly as in the first import.
   - **Already imported, and the Stride task not changed since** (task
     `updated_at` ≤ the import link's `synced_at`) → updated from Jira:
     title, description, status/column, priority, assignee, labels, mapped
     fields. New comments are added; existing comments are not edited.
   - **Already imported, and the Stride task changed in Stride as well** →
     **not touched**. Listed under **Conflicts**, showing both versions side by
     side, with **Take the Jira version** and **Keep Stride's** per issue. The
     rule is simple and safe: Stride's edits are never overwritten without a
     person choosing it.
   - **Claimed by an agent in Stride** → never touched, whatever changed.
   - **Moved out of scope or deleted in Jira** → not deleted in Stride;
     listed under **No longer in Jira**. Deleted issues are found by comparing
     the run's imported ids with a key-only search of the scope.
3. Updates the run's counts and report.

Re-sync uses the mapping saved with the run. Changing the mapping between
re-syncs applies only to issues created or updated from then on, and the page
says so.

### 13.6 Cutover and the optional "moved to Stride" marker

**Finish migration** closes the run: one last re-sync, then the stored
credential is deleted, re-sync and undo are disabled, and the run becomes
read-only history.

Optionally (off by default, needs a token that can edit issues, Phase 3),
Finish migration can mark Jira: add a comment *Moved to Stride: <link>* and the
label `moved-to-stride` to every imported open issue. This is the only write
Stride ever makes to Jira. It is a separate checkbox with its own
explanation, because it needs write access and it changes the team's other
tool.

### 13.7 Undo

**Undo import** is offered while the run is `imported` and no re-sync
conflict is pending. Because a run creates new boards, undo deletes those
boards and everything on them, after a confirmation that names the boards and
the number of tasks. If anyone has added a task, comment or agent completion
to one of those boards since, the confirmation says so and asks the importer
to type the board name. After **Finish migration**, undo is no longer
offered; the boards are ordinary boards.

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
- Inline images become a link line: *[image: screenshot.png](Jira URL)*.
  The link needs a Jira login to open.
- Links to other imported issues (a smart link, a browse URL, or a bare
  `PAY-123` key) are rewritten to the Stride identifier with the original key
  in brackets: `W42 (PAY-123)`.

### 14.2 Comments

| Rule | Detail |
|---|---|
| Order | Oldest first, with the Jira `created` time kept as the comment's time |
| Author matched | Comment authored by that Stride user |
| Author not matched | No author; the comment starts with *Originally by Jane Doe on 3 Mar 2026:* |
| Automation and apps (Jira Automation, the GitHub app) | Kept with *Originally by <app name>*; option **Skip automated comments** |
| Restricted comments (visible only to a group or project role) and Jira Service Management internal notes | **Skipped** and counted ([§20](#20-security-and-privacy)) |
| Over 10,000 characters | Shortened to the cap with *(shortened on import, full text in Jira)*; listed under *repaired* |
| Edited in Jira | The current text; `edited_at` not set |
| `mentioned_user_ids` | Left empty, so no mention notification is ever sent |

### 14.3 Attachments

Stride has no attachments yet. Each Jira attachment becomes a line in the
import panel: file name, size, type and a link to it in Jira. Linked branches
and pull requests from Jira's development panel, where the site exposes them,
are listed the same way under **Linked pull requests**. When the
*Attachments* roadmap item ships, a follow-up can copy files across using the
links kept here.

### 14.4 History

Stride's task history records creation, moves between columns, priority
changes and assignment changes. The import reads the Jira changelog and writes:

- a `:creation` entry at the Jira creation time,
- a `:move` entry for each status change **that crosses a Stride column**,
  using the mapped columns, with the Jira time and the matched actor,
- `:priority_change` and `:assignment` entries from the changelog.

This keeps cycle time and the board metrics meaningful for imported work.
Status changes inside one Stride column (two Jira statuses that both map to
Doing) are not written. The full changelog is kept as unmapped data.

Imported history is distinguishable from history made in Stride: the history
rows are linked to the run through the task's import link. Metrics can
therefore offer **Exclude imported history**, a checkbox on the metrics pages
(Phase 2), so a team can measure its Stride period alone.

### 14.5 Dates and time zones

Jira timestamps are stored in UTC as Stride does everywhere. Jira dates
without a time (`duedate`, version release dates) are kept as dates.

Stride tasks have **no due date**. Due dates are unmapped data by default, and
can be mapped to a label or a description section. On epics they can become a
delivery target. Delivery targets are the closest Stride concept, but they
belong to goals only (`validate_target_requires_goal_type`).

---

## 15. People and board membership

### 15.1 Matching

1. Collect every person the issues refer to (assignee, reporter, comment
   author, changelog actor), with their Jira account id, display name and email
   if Jira returns one.
2. Match by email, case-insensitive, to a Stride user who is **enabled** and,
   in an Organization workspace, **a member of the Organization**. This is the
   workspace importer's rule (`Kanban.Workspaces.Export.Importer.Users`).
3. The mapping page lists every person with their match, and lets the importer:
   - pick a Stride user by hand (search limited to the Organization or, for a
     personal workspace, the importer),
   - choose **Invite** for an unmatched email (sends a normal board invitation
     **after** the import, so the invitation is about a board that exists),
   - choose **Leave unassigned**.
4. Every matched person who appears as an assignee is added to the destination
   board with **modify** access. People who appear only as comment authors or
   changelog actors are not added; their names show on the issues.

**Jira often hides email addresses.** Atlassian returns `emailAddress` only
when the user's profile visibility allows it, so many Jira imports will have
few email matches. The mapping page makes manual matching quick:

- it lists the people by how many issues they are on, most first,
- it suggests a match by display name,
- it applies a saved preset's people matches (by Jira account id) to later
  runs from the same site.

Jira app and automation accounts (`accountType` other than `atlassian`) are
never matched to people.

### 15.2 The importer

The importer becomes the owner of every board the run creates. An issue with
no matched reporter gets no `created_by_id`, not the importer's: the task
history should not claim the importer wrote work they did not write.

### 15.3 Free-board member cap

On a free board, with plans enforced, a board holds at most three human
members (`Kanban.Plans.free_board_member_cap/0`). The preview shows how many
people would be added; beyond the cap the rest are left as unassigned
references, listed in the report, and the preview explains that an
Organization workspace has no cap ([§19](#19-permissions-and-plans)).

---

## 16. Architecture

### 16.1 Modules

```text
lib/kanban/imports.ex                      Public context: runs, connections, presets
lib/kanban/imports/
  connection.ex                            Schema: import_connections
  run.ex                                   Schema + state machine: import_runs
  staged_item.ex                           Schema: import_staged_items
  task_link.ex                             Schema: import_task_links
  mapping_preset.ex                        Schema: import_mapping_presets
  item.ex                                  The common item struct (§8)
  mapping.ex                               Embedded schema, versioned mapping JSON (§11.5)
  mapping/defaults.ex                      Default mapping from the fetched issues (§9, §10)
  mapping/apply.ex                         Item + mapping → task attrs, labels, links, warnings
  planner.ex                               Builds the preview: counts, samples, warnings (§18)
  writer.ex                                Writes one destination board in one transaction
  people.ex                                Person collection and matching (§15)
  resync.ex                                Re-sync and conflict detection (§13.5)
  undo.ex                                  Undo (§13.7)
  report.ex                                The run report (§21)
  text/adf.ex                              Atlassian document format → text (Appendix B)
  text/links.ex                            Rewrites links to imported issues (§14.1)
  source.ex                                The adapter behaviour (§16.2)
  sources/jira_cloud.ex                    Jira Cloud adapter
  sources/jira_cloud/client.ex             REST over Req, UrlGuard on every request
  sources/jira_cloud/fields.ex             Field catalogue, story points, custom field discovery
  sources/jira_cloud/normalize.ex          Jira issue JSON → Kanban.Imports.Item
  workers/fetch_worker.ex                  Oban: fetch into staging
  workers/import_worker.ex                 Oban: write boards
  workers/resync_worker.ex                 Oban: re-sync
  workers/cleanup_worker.ex                Oban cron: staging purge, stale credentials

lib/kanban_web/live/import_live/
  index.ex                                 /imports — runs list
  new.ex                                   /imports/new — Jira connection
  scope.ex                                 /imports/:id/scope
  mapping.ex                               /imports/:id/mapping (tabbed)
  preview.ex                               /imports/:id/preview
  show.ex                                  /imports/:id — progress, report, re-sync, finish, undo
lib/kanban_web/components/import_components.ex
lib/kanban_web/live/task_live/imported_from_component.ex   The "Imported from" panel (§12)
```

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
  `(run_id, external_id)` so a retried page never duplicates,
- stores the page token on the run after every page, so a crashed or retried
  job resumes where it stopped,
- honours `429` and `Retry-After` by snoozing the job (`{:snooze, seconds}`),
  never by sleeping in the worker,
- updates `import_runs.progress` (`fetched`, `total`) for the progress bar,
  broadcast on `"import_run:#{id}"`.

**Map and preview** (in the LiveView process, reading staging):

- `Mapping.Defaults` proposes a mapping from the staged issues,
- `Mapping.Apply` runs every staged issue through the mapping and the task
  changeset **without inserting**, collecting warnings per issue,
- `Planner` totals the counts and picks samples. For a large run the preview
  is computed in a `Task.Supervisor` child and shown with `assign_async`.

**Import** (`ImportWorker`):

- one Oban job per destination board, each in **one transaction**, as the
  workspace importer does: the board lands whole or not at all,
- order inside the transaction: board and columns → labels → goals (with
  pre-generated `G` identifiers) → tasks (pre-generated `W`/`D` identifiers,
  inserted with `Repo.insert_all` in chunks of 500 after changeset validation)
  → dependencies (second pass, now that every identifier exists) →
  `duplicate_of_id` (second pass) → comments → history → board memberships →
  import links → goal placement,
- no `Broadcaster`, notification, webhook or WIP-limit code runs; one board
  reload broadcast per board after commit,
- a board that fails rolls back alone. The run ends `imported` with the failed
  board listed and a **Retry this board** action, or `failed` if every board
  failed.

**Re-sync** (`ResyncWorker`) fetches into staging with an `updated >=` clause,
then applies [§13.5](#135-re-sync-when-the-team-keeps-working-in-jira) in one
transaction per board.

### 16.4 Idempotency

`import_task_links` has a unique index on
`(board_id, source, source_site, external_id)`. A retried import job finds the
link and skips the issue. A re-sync finds it and updates the task. A second
run of the same project into the same board (Phase 3) cannot duplicate an
issue.

### 16.5 Long transactions

A 5,000-issue board with comments is tens of thousands of rows. A single
transaction of that size is expected to take tens of seconds, which is
acceptable for a one-off write to a board nobody else can see yet. Phase 1
measures it. If measurement shows otherwise, the fallback is to write the
board in chunks with `board.import_state = :importing` hiding it from every
list until the last chunk commits. That fallback is listed under
[§24](#24-decisions-needed) and not built up front.

---

## 17. Database changes

All tables are new. No existing table changes in Phases 1 and 2.

**`import_connections`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `workspace_id` | references `workspaces`, on delete cascade | |
| `created_by_id` | references `users`, on delete nilify | |
| `source` | string | `jira_cloud` (later `jira_dc`) |
| `site_url` | string | The Jira site |
| `site_name` | string | From test connection |
| `account_label` | string | "Ana Lopez (ana@acme.com)" as Jira reported it |
| `auth_method` | string | `basic_token`, `oauth`, `pat` |
| `credential` | binary (`EncryptedString`) | Never selected into a list query |
| `account_email` | string | Basic-auth username |
| `last_verified_at` | utc_datetime | |
| timestamps | | |

**`import_runs`**

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `workspace_id` | references `workspaces` | |
| `connection_id` | references `import_connections`, on delete nilify | Nil after **Finish migration** |
| `created_by_id` | references `users` | |
| `source` | string | |
| `status` | string | [§4](#4-the-import-at-a-glance) states |
| `scope` | jsonb | Projects or boards, epics, filters, JQL, closed-work choice |
| `mapping` | jsonb | `Kanban.Imports.Mapping`, versioned |
| `options` | jsonb | Board layout, one-board-or-many, Ready opt-in |
| `cursor` | jsonb | Fetch resume point (`nextPageToken`) |
| `progress` | jsonb | `%{phase, done, total}` |
| `counts` | jsonb | Final counts by category |
| `report` | jsonb | [§21](#21-telemetry-audit-log-and-the-import-report) |
| `board_ids` | bigint[] | Boards this run created |
| `last_fetched_at`, `imported_at`, `finished_at` | utc_datetime | |
| `error` | string | Short, redacted |
| timestamps | | |

**`import_staged_items`** (purged 14 days after the run is imported, and at finish)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `run_id` | references `import_runs`, on delete cascade | |
| `external_id` | string | Unique with `run_id` |
| `item` | jsonb | The normalised `Kanban.Imports.Item` |
| `source_updated_at` | utc_datetime | |
| `fetched_at` | utc_datetime | |

**`import_task_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_id` | references `tasks`, on delete cascade | Unique |
| `board_id` | references `boards`, on delete cascade | Part of the idempotency index |
| `run_id` | references `import_runs`, on delete nilify | |
| `source`, `source_site` | string | |
| `external_id`, `external_key`, `external_url` | string | |
| `source_updated_at` | utc_datetime | |
| `synced_at` | utc_datetime | Last time Stride wrote the task from Jira |
| `unmapped` | jsonb | [§12](#12-data-that-does-not-map), capped at 64 KB |

Index: unique `(board_id, source, source_site, external_id)`; index on
`external_key` for Jira-key search (Phase 2).

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
its **Imported from** panels. The other import tables are operational and stay
out of the archive, like webhook endpoints today.

---

## 18. Screens

All pages are LiveViews in the existing `live_session :require_authenticated_user`
block, because every one of them needs a signed-in user and the current
workspace. The entry points are **Import** in the workspace sidebar and
**Import from Jira** on the new-board page. Every string is translated
through gettext in all locales. Every page follows the
[dark-mode contract](../dark-mode-contract.md) and uses the existing
`<.input>`, `<.button>` and form components.

| Page | What is on it |
|---|---|
| **Imports** `/imports` | Runs in this workspace: Jira site, scope summary, status, boards, who ran it, when. **New import** |
| **Connect** `/imports/new` | Site URL, email, API token, a short "where to create an API token" help with a link to Atlassian's page, **Test connection**, the result. Or pick a connection already saved in this workspace |
| **Scope** `/imports/:id/scope` | [§6](#6-choosing-what-to-import): projects or boards with counts, epics with counts, filters, the JQL box, closed-work choice, running total, limit warnings, restricted-issue count and opt-in. **Fetch** |
| **Fetching** (on `/imports/:id`) | Progress bar by phase (issues, comments, changelog), live; **Cancel** |
| **Mapping** `/imports/:id/mapping` | Tabs: *Board layout* (one or many, AI-optimized or custom, column stages with warnings), *Status*, *Issue types and hierarchy*, *Priority*, *Size*, *People*, *Labels*, *Fields* ([§11](#11-mapping-additional-fields)), *Sections*. Every tab shows only values that occur, with counts. **Save as preset** |
| **Preview** `/imports/:id/preview` | Per destination board: task counts by column and type, goals, comments, labels, people added; **sample cards** (ten issues chosen to cover each type and status) rendered with the real task card component; warnings grouped by kind with the issues they affect; blocking errors that must be fixed before **Import** is enabled |
| **Run** `/imports/:id` | During import: progress per board. After: the report ([§21](#21-telemetry-audit-log-and-the-import-report)), **Open board**, **Re-sync changes**, conflicts, **Finish migration**, **Undo import**, **Delete stored credential** |
| **Task view** | The **Imported from PAY-88** line under the title, and the collapsed **Imported from** panel ([§12](#12-data-that-does-not-map)) |

---

## 19. Permissions and plans

| Action | Who |
|---|---|
| Start an import into a personal workspace | The workspace's owner |
| Start an import into an Organization workspace | Org-admins, and workspace owners of that workspace |
| See a run, its report and its unmapped data | The run's creator, the Organization's org-admins, and owners of the boards it created |
| Use a stored connection | Its creator and the Organization's org-admins |
| Re-sync, finish, undo | The run's creator and the Organization's org-admins |
| See the **Imported from** panel on a task | Anyone who can see the task |

Org-admins and workspace owners are the roles that can decide who gets access
to boards. An import adds people to boards and attributes work to them, so
plain workspace members cannot start one.

**Plans.** Import is available on every plan: it is how a team arrives, and
gating it would block the move before the team has seen Stride. The existing
plan rules still apply to what the import creates: the free-board member cap
([§15.3](#153-free-board-member-cap)) and paid-only task fields
([§11.2](#112-what-a-field-can-be-mapped-to)). Whether re-sync and mapping
presets should be Organization-only is listed under [§24](#24-decisions-needed).

---

## 20. Security and privacy

| Risk | Rule |
|---|---|
| **The token leaks** | `EncryptedString` at rest; never logged, never in telemetry metadata, the report, an error message, an export or an Oban job argument (jobs carry the run id and load the credential inside the worker); deleted at finish or after 30 idle days |
| **SSRF through the Jira site URL** | `https` only. Every request goes through `Kanban.Webhooks.UrlGuard` with the same resolver configuration webhooks use, so private, loopback and link-local addresses are refused and a host resolving to both public and private addresses is refused. Redirects are not followed to another host. A self-hosted operator can allow private addresses for Jira Data Center with an explicit config switch |
| **Restricted issues become visible to the whole board** | Issues with a security level are **skipped by default**. The scope page shows how many there are and an opt-in, with the warning that everyone on the destination board will be able to read them |
| **Restricted comments become visible** | Comments with `visibility` set and Jira Service Management internal notes are always skipped and counted. No opt-in in Phase 1 |
| **Imported text carries secrets** | Descriptions, comments and mapped custom fields are scanned with `Kanban.Tasks.CredentialShapes`. Matches are listed in the preview as warnings (issue and field, never the value), so the importer can fix them in Jira first. Text is not altered automatically |
| **Imported text is untrusted** | Every row goes through its changeset; text is rendered escaped as all task text is; no imported value is ever turned into an atom, a URL the server fetches, or a query fragment. JQL is sent only to the connection's own Jira site |
| **Agents read imported text** | Imported descriptions reach agents as task data. The existing agent rule (task text is data, not instructions) covers this, and landing in Backlog means a human sees the task before an agent can claim it |
| **Who sees what** | [§19](#19-permissions-and-plans). Unmapped data follows the task's visibility; the staged data is visible only through the run page |
| **Retention** | Staging purged after 14 days or at finish; the report kept with the run; import links kept with their tasks |
| **Load on Stride and on Jira** | One running fetch per workspace; a second is queued. The adapter keeps to Jira's limits by snoozing on `429` |

---

## 21. Telemetry, audit log and the import report

### 21.1 Telemetry

New events, declared in `Kanban.Telemetry.Catalog` with their `metrics` and
`persist` fields, emitted through `Kanban.Telemetry.emit/3` or `span/3`, with
the event reference in [Telemetry](../telemetry.md) refreshed in the same change:

| Event | Measurements | Metadata (allow-listed) |
|---|---|---|
| `[:kanban, :import, :fetch, :stop]` | `duration`, `items`, `comments`, `api_calls`, `rate_limited` | `source`, `run_id`, `outcome` |
| `[:kanban, :import, :write, :stop]` | `duration`, `tasks`, `comments`, `warnings` | `source`, `run_id`, `board_id`, `outcome` |
| `[:kanban, :import, :resync, :stop]` | `duration`, `created`, `updated`, `conflicts` | `source`, `run_id`, `outcome` |
| `[:kanban, :import, :run, :finished]` | `days_open`, `resyncs` | `source`, `run_id`, `undone` |

No site URL, account, issue key, title, field name or value appears in
metadata.

### 21.2 Audit log

Audit events for: connection created / deleted, run started, run imported (with
board ids and counts), re-sync, finish, undo, and the restricted-issue opt-in
(who opted in, how many issues). These are the actions an Organization's
security team will ask about.

### 21.3 The report

Kept as `import_runs.report` and downloadable as JSON and CSV:

- **Created:** boards, goals, tasks by type and column, comments, labels, history entries, people added to boards.
- **Repaired:** shortened label names and comments; merged labels; unknown document nodes.
- **People:** matched (by email or by hand), invited, left unassigned, not added because of the member cap.
- **Needs attention:** in-progress work with nobody on it; dependencies dropped (cycles, cross-board); children separated from their goal; credential-shaped text found.
- **Skipped:** restricted issues, restricted comments, issues over the limits, each with its Jira key and the reason.
- **Counted, not kept:** votes, watchers.
- **Re-sync history:** each re-sync's created, updated, conflicts and issues no longer in Jira.

---

## 22. Testing strategy

| Layer | What | How |
|---|---|---|
| Jira adapter | Every endpoint in Appendix A, `nextPageToken` paging, `429` with `Retry-After`, auth failure, a site that is not Cloud, a JQL error, lists cut short on an issue (comments, changelog) | `Req.Test` stubs fed by recorded fixtures (scrubbed of real data) in `test/support/fixtures/imports/jira/` |
| Text conversion | Every Atlassian document node type in Appendix B | Table-driven unit tests, plus property tests that output is valid UTF-8 without NUL bytes |
| Mapping | Every default in §9–§10, every transform in §11.2, section extraction, sub-task flattening, story-points field detection | Unit tests on `Mapping.Apply` with hand-built `Item` structs |
| Status edge cases | Each row of [§13.2](#132-what-happens-to-each-kind-of-item) | One test per row, asserting column, status, claim fields empty, archive reason and note |
| Writer | One transaction per board; a bad row rolls back that board only; identifiers sequential; dependencies and duplicates resolved in the second pass; no broadcast, notification, webhook or Oban notification job | `Kanban.DataCase`; telemetry attached with `Kanban.TelemetryHelpers.attach_telemetry/2`; `refute_enqueued` for notification and webhook workers |
| Idempotency | Retried import job, retried fetch page | Run the worker twice, assert counts unchanged |
| Re-sync | New, updated, conflicting, agent-claimed, deleted-in-Jira issues | DataCase, one test per case |
| Undo | Boards created by the run deleted; nothing else touched | DataCase |
| People | Email match, case, hidden email, disabled user, user outside the Organization, app accounts, member cap | Mirrors the workspace importer's user tests |
| Security | URL guard on every Jira request, token never in logs or job args or the report, restricted issues and comments skipped | `ExUnit.CaptureLog` scans, Oban job arg assertions |
| LiveViews | Each wizard page, permissions per role, translations rendered | `Phoenix.LiveViewTest`; locale tests with the session set |
| Dark mode | Every new page and the task panel | `mix dark_mode.scan` and the contrast check (run by `mix precommit`) |
| End to end | A real Jira Cloud site made for the purpose, with epics, sub-tasks, custom fields, a security level and restricted comments, imported into the dev app | Manual / exploratory, Phase 1 and Phase 2 exit |

---

## 23. Phased delivery

Each phase ships on its own and is useful on its own.

| Phase | Scope | Exit criteria |
|---|---|---|
| **1. Core Jira Cloud import** | Connections (API token), runs, staging, the adapter behaviour, the Jira Cloud adapter, document-format conversion, epics and sub-task flattening, default mapping, status/type/priority/complexity/people/label mapping tables, restricted issues and comments, preview, writer, report, **Imported from** panel, undo, telemetry, audit | A Jira project of ~2,000 issues with epics, sub-tasks and comments imports with no silent loss; the report accounts for every issue |
| **2. Custom fields and polish** | Custom field discovery and mapping ([§11](#11-mapping-additional-fields)), section extraction, mapping presets, Jira-key search, *Exclude imported history* on metrics | A project whose acceptance criteria and team data live in custom fields imports them into Stride fields |
| **3. Moving while working** | Re-sync and conflicts, Finish migration, the optional "moved to Stride" marker, import into an existing board, OAuth 2.0 (3LO) | A team can import, keep working in Jira for two weeks, re-sync, and finish with no lost changes |
| **4. Jira Data Center** | `jira_dc` adapter, PAT auth, REST v2, wiki markup, self-hosted private-address switch | A Data Center instance imports through the same pipeline |

---

## 24. Decisions needed

These are choices this design does not make on its own. Each has a
recommendation.

| # | Question | Recommendation |
|---|---|---|
| 1 | Where should To Do work land: Backlog or Ready? | **Backlog**, with an opt-in for Ready ([§10.3](#103-status-to-column)). It is the only default that cannot hand an agent a context-free task |
| 2 | Should columns get an explicit stage, so custom boards do not depend on column names? | **Yes, but as its own task**, before Phase 2. It fixes the same problem for hand-made custom boards. Until then, the mapping page's stage warnings cover imports |
| 3 | Is import available on every plan? | **Yes**, with existing caps. Re-sync and presets could be Organization-only; recommend deciding after Phase 1 usage data |
| 4 | Where does unmapped data live? | **On the import link**, shown in a collapsed panel ([§12](#12-data-that-does-not-map)), not in the description or `technical_details` |
| 5 | Should stories with sub-tasks become goals? | **No by default** (flatten under the epic), with the option on the mapping page ([§10.2](#102-hierarchy)) |
| 6 | One transaction per board, or chunked writes with a hidden board? | **One transaction**, measured in Phase 1; chunked only if measurement demands it ([§16.5](#165-long-transactions)) |
| 7 | Should imported history count in metrics? | **Yes by default**, with *Exclude imported history* on the metrics pages in Phase 2 ([§14.4](#144-history)) |
| 8 | Should Stride ever write to Jira? | **Only** the opt-in "moved to Stride" marker at finish, Phase 3 ([§13.6](#136-cutover-and-the-optional-moved-to-stride-marker)) |
| 9 | How long is closed work imported by default? | **Last 90 days** to Done ([§6.2](#62-completed-and-cancelled-work)) |
| 10 | Should the roadmap item be renamed now that Linear is out of scope? | **Yes**: *Import from Jira*, so the roadmap does not promise Linear |
| 11 | Must in-progress and done work survive the move, or is the backlog enough? | **It must**, so the deterministic import is the base and the AI rewrite is an optional layer for not-started epics, shipped after Phase 1 ([Appendix C](#appendix-c-ai-assisted-rewrite-of-work-not-yet-started)) |

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
| Priorities, statuses, issue types, link types | `GET /rest/api/3/priority`, `GET /rest/api/3/status`, `GET /rest/api/3/issuetype`, `GET /rest/api/3/issueLinkType` |
| Counts | `POST /rest/api/3/search/approximate-count` |
| Issues | `POST /rest/api/3/search/jql` with `nextPageToken` pagination, `fields=*all`, `expand=changelog` |
| Comments (when the embedded list is cut short) | `GET /rest/api/3/issue/{id}/comment` (paged) |
| Changelog (when the embedded list is cut short) | `GET /rest/api/3/issue/{id}/changelog` (paged) |
| Sprints | Read from the sprint custom field on each issue; `GET /rest/agile/1.0/board/{id}/sprint` for sprint states |
| Write-back marker (Phase 3, opt-in) | `POST /rest/api/3/issue/{id}/comment`, `PUT /rest/api/3/issue/{id}` (labels) |

The older `GET /rest/api/3/search` endpoint is being retired by Atlassian in
favour of `/search/jql`, so the adapter uses `/search/jql` only.

---

## Appendix B: rich text conversion rules

Output is plain text with Markdown conventions, kept readable as plain text
because that is how Stride shows it today.

| Atlassian document node | Output |
|---|---|
| `paragraph` | Text, blank line after |
| `heading` (level n) | `#` × n, space, text |
| `bulletList` / `orderedList` / `listItem` | `- ` / `1. `, nested lists indented two spaces per level |
| `taskList` / `taskItem` | `- [ ] ` / `- [x] ` |
| `codeBlock` | Fenced block with the language if given |
| `blockquote` | `> ` on each line |
| `panel` (info, note, warning, error, success) | `> **Note:** ` + content |
| `rule` | `---` |
| `table` | Markdown table; merged cells repeated; tables wider than 10 columns become one line per row |
| `text` with marks | `strong` → `**…**`, `em` → `_…_`, `code` → `` `…` ``, `strike` → `~~…~~`, `link` → `[text](href)`; `underline`, `textColor` and `subsup` dropped |
| `mention` | `@Display Name` |
| `emoji` | Its Unicode character, else `:shortName:` |
| `inlineCard` / `blockCard` / `embedCard` | The URL, rewritten if it points to an imported issue ([§14.1](#141-descriptions)) |
| `mediaSingle` / `mediaGroup` / `media` | `[image: <name>](<Jira URL>)` or `[file: <name>](<Jira URL>)` |
| `status` (lozenge) | `[<text>]` |
| `date` | ISO date |
| `expand` / `nestedExpand` | Its title in bold, then its content |
| `hardBreak` | Newline |
| Unknown node | Its text content, and a count in the report under *repaired* |

NUL bytes and invalid UTF-8 are removed from all converted text, because the
database columns cannot hold them.

---

## Appendix C: AI-assisted rewrite of work not yet started

This appendix describes a second approach, raised after the design above was
written, and says where it fits. The concern behind it is the quality of the
Jira issues themselves. Issues are often thin, out of date, duplicated, or
written for people who already know the context. A faithful import carries all
of that across, and [§9.3](#93-stride-fields-jira-does-not-fill) leaves the
agent-facing fields empty.

The second approach: export each epic's stories, tasks and sub-tasks as JSON,
create one Stride goal per epic, and have an agent use the JSON as context with
the `create-goals` skill to write new Stride tasks that cover all of it. A
second pass then checks that everything in the JSON made it into a task.

The recommendation is to use **both**, split by the state of the work, with the
rewrite built on top of the import rather than in place of it.

### C.1 Where each approach fits

| Jira state | Approach | Why |
|---|---|---|
| In progress, in review | Deterministic import only | The column, the person on it and the review state must survive the move ([§13.2](#132-what-happens-to-each-kind-of-item)). A rewrite would turn work someone is doing into new, unowned tasks |
| Done, cancelled, won't do | Deterministic import only | It is history and metrics ([§6.2](#62-completed-and-cancelled-work), [§14.4](#144-history)). There is nothing to rewrite |
| Not started, in an epic | Import, then the AI rewrite per epic | This is where issue quality matters most, and there is no state to lose |
| Not started, with no epic | Import, then either enrichment per task ([§9.3](#93-stride-fields-jira-does-not-fill)) or the rewrite with one goal per project or component | The rewrite needs a container to turn into a goal |

The rewrite is chosen **per epic**. A team can rewrite the three epics it is
about to start and leave the rest as imported until it reaches them.

### C.2 The rewrite builds on the import

1. **The import runs as designed.** Raw tasks land in Backlog with their import
   links, unmapped data, comments and history ([§12](#12-data-that-does-not-map)).
   Undo still works ([§13.7](#137-undo)).
2. **The importer picks epics to rewrite** on the run page. For each epic,
   Stride builds an **epic bundle**: one JSON document with the epic and every
   issue under it, as normalised `Kanban.Imports.Item` values (mapped fields
   from the task, everything else from the import link). It is the same data as
   each task's **Download Jira data**, gathered per epic. Because the bundle is
   built from the import links, which are permanent, it does not depend on
   staging, which is purged after 14 days.
3. **An agent rewrites the epic** with `create-goals`, the bundle as its
   context, into the same board. It creates a **new** goal for the epic,
   because tasks cannot be added to an existing goal through the API, and the
   new tasks land in Backlog.
4. **Every generated task records what it covers.** The agent emits a
   coverage map with the batch: for each generated task, the Jira keys and the
   source lines (acceptance-criteria lines, checklist items, sub-tasks) it
   covers. Each task carries its keys in `technical_details.source_issues`, a
   short list, not the Jira metadata [§12](#12-data-that-does-not-map) keeps out
   of `technical_details`. As stride-ideation does with `source_spec` and
   `source_spec_sha256`, the rewrite records the SHA-256 of the bundle it was
   written from, so a later change in Jira can be detected.
5. **The second pass runs** ([C.3](#c3-the-second-pass-a-coverage-report-someone-signs)).
6. **A person signs off the epic.** Only then are the raw tasks it covers
   archived: as `:duplicate` of the generated task when one task covers the
   issue, else `:wontdo` with the note *Rewritten as W210, W211*. The import
   links stay, so the **Imported from** panel and the Jira data remain one click
   away. The original epic goal is archived the same way. Moving the new tasks
   to Ready stays a separate human step.

Building on the import keeps everything the import promises: nothing is dropped
silently, the Jira data stays reachable, undo and re-sync keep working, and a
rewrite can be thrown away and run again for one epic without importing again.
For the epics a team chooses, the rewrite takes the place of [§9.3](#93-stride-fields-jira-does-not-fill)'s
**Enrich these tasks**.

### C.3 The second pass: a coverage report someone signs

The second pass is not a second agent saying "looks complete". It produces a
report per epic, and part of it is computed by code.

| Check | Done by | Finds |
|---|---|---|
| **Every key is accounted for** | Code, from the coverage map | Jira keys in the bundle that no generated task cites, and keys the agent marked *dropped* (each needs a reason) |
| **Every source line is accounted for** | Code, from the coverage map | Acceptance-criteria lines, checklist items and sub-tasks no task cites |
| **Citations are real** | A reviewer agent that did not write the tasks, given the bundle and the batch | A task that cites PAY-88 but does not cover what PAY-88 asks for |
| **Nothing is invented** | The same reviewer | Requirements, limits or behaviour in a generated task that no source issue or comment supports |
| **Later comments are honoured** | The same reviewer | A task written from an issue's description when a later comment changed the scope |
| **Merges and splits are visible** | Code, from the coverage map | Where several issues became one task, or one issue became several, so the reviewer sees the change in shape |

The report has five lists: **Covered**, **Uncovered**, **Dropped with a
reason**, **Unsupported claims** and **Merges and splits**. An epic cannot be
signed off while anything is uncovered, unless the person signing marks it
dropped. Nothing generated reaches Ready, and no raw task is archived, before
sign-off. This is [§13.1](#131-the-principles)'s second principle applied to
generated work.

The reviewer follows the pattern of stride-ideation's requirements-reviewer:
it reports and never edits.

### C.4 Constraints and risks

| Risk | Rule |
|---|---|
| **Restricted issues reach the agent** | The bundle is built from imported tasks only, so issues skipped under [§20](#20-security-and-privacy) are never in it. If the importer opted in to restricted issues, the rewrite page repeats the warning, because the text now also goes to the agent's model provider |
| **Jira text goes to a model provider** | The rewrite runs in the customer's own agent against their checked-out repository, not on Stride's servers. Whatever provider that agent uses receives the bundle. The rewrite page says so, and an Organization can turn the rewrite off |
| **Imported text tries to steer the agent** | The bundle is untrusted data, not instructions: the existing agent rule applies, and the reviewer flags any generated task that carries instructions aimed at agents |
| **Imported text carries secrets** | The bundle export runs the same `Kanban.Tasks.CredentialShapes` scan as the preview and refuses to export an epic with a match until the issue is fixed in Jira or the field is excluded |
| **A bad generation is hard to remove** | The API has no delete and no reparenting. The agent writes the batch JSON to a file first, as `/stridify` does, so it can be read before it is posted. A rewrite that is posted and then rejected is archived by a person in the board UI, with the goal archived as a whole |
| **Two runs give different tasks** | The rewrite is not deterministic. The coverage report is what makes a result checkable; the bundle hash, the batch JSON and the report are kept with the run so the rewrite can be audited later |
| **The epic is too large for one context** | The bundle is split by story into chunks. Coverage is computed across all chunks, and the result is still one goal per epic. Dependencies between epics cannot be set in one batch, so they are added afterwards, or kept from the import |
| **Jira changes after the rewrite** | Re-sync ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)) never edits generated tasks. A change to an issue whose raw task was archived by a rewrite is listed under **Changed after rewrite**, naming the generated tasks, and the bundle hash shows which epics' sources have moved |
| **Two levels only** | Goals never contain goals ([§10.2](#102-hierarchy)). An epic's stories and sub-tasks all become tasks under the one goal |
| **Cost and time** | Each epic costs a model run and a review. The rewrite is offered per epic, never as one step across the whole import |

### C.5 What has to be built

- **Epic bundle export** on the run page: JSON per epic, built from the import
  links, with the credential scan.
- **A rewrite command in the Stride plugin** that takes a bundle, runs
  `create-goals` with it, writes the batch JSON and the coverage map, and posts
  the batch. It is modelled on stride-ideation's `/stridify`.
- **The coverage checker and the reviewer agent** that produce the report in
  [C.3](#c3-the-second-pass-a-coverage-report-someone-signs).
- **Sign-off on the run page**: the report per epic, **Sign off**, and the bulk
  archive of the raw tasks it covers.

It needs Phase 1 (the import links and the **Imported from** data) and nothing
from Phases 2 to 4, so it can ship directly after Phase 1 ([§23](#23-phased-delivery)).

### C.6 The decision this hinges on

**Must in-progress and done work survive the move?** If it must, with its
people, review state and history, the deterministic import stays the base and
the rewrite is a layer for not-started epics, as described above. If a team
only wants its backlog and is content to leave history in Jira, the rewrite on
its own (export, `create-goals`, coverage report) would be enough, and Phase 1
would shrink to the adapter, the export and the coverage report. This is
decision 11 in [§24](#24-decisions-needed).
