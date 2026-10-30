# Import from Jira — Implementation Design

**Roadmap item:** Import from other tools → *Import from Linear and Jira* ([ROADMAP](../../ROADMAP.md)). This design covers **Jira only**; Linear is out of scope.
**Status:** Proposed design, not yet decomposed into tasks. Every decision in [§24](#24-decisions-needed) was settled on 2026-10-30
**Date:** 2026-10-28, revised 2026-10-30 to make the epic rewrite part of the core import, and again on 2026-10-30 to move the agent side into a new plugin, `stride-import`, with a variant for every agent runtime

This document describes how a team brings its existing work from Jira into
Stride: how Stride connects to Jira, how the team chooses what to bring
across, how every field is mapped, how the team maps extra fields of its own,
what happens to data Stride has no place for, and how work that is already in
progress survives the move. It ends with the architecture, the database
changes, the screens, the security rules, the tests and a phased delivery
plan.

**Import is an Organization plan feature**, and so is the rewrite. When paid
plans are enforced, only a workspace that belongs to an Organization can start
an import ([§19](#19-permissions-and-plans)).

Every epic comes across one of two ways, chosen epic by epic. A **direct
import** copies the issues into Stride tasks field by field. A **rewrite**
hands the epic's not-started issues to an agent, which writes new Stride tasks
that cover everything in them, and a coverage check proves nothing was lost
before a person signs the result off. Jira issues are often thin, out of date
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
  shows that every issue and every requirement in it reached a task, and a
  person signs that off before anything is written ([§6A](#6a-rewrite-or-import-epic-by-epic)).
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
  Stride's own attachments, built before this work ([Task Attachments](ATTACHMENTS-DESIGN.md)).
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
| **Coverage map** | For each task in a draft, the Jira keys and the source lines it covers |
| **Source link** | The permanent record joining a rewritten task to the Jira issues it was written from |
| **Import plugin** | `stride-import` and its runtime variants: the agent-side plugin that fetches a bundle, drafts the tasks, reviews them and submits the draft ([§16A](#16a-the-agent-side-plugin-stride-import)) |
| **Variant** | One build of the import plugin for one agent runtime, such as `stride-copilot-import` for GitHub Copilot CLI |

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
| AI-optimized boards | `Kanban.Boards.create_ai_optimized_board/3` (`ai_optimized_board: true`, the fixed Backlog, Ready, Doing, Review, Done columns) | Every board the import writes to is AI-optimized ([§7.2](#72-ai-optimized-board-or-custom-board)) |
| Labels | `Kanban.Labels`, `Kanban.Labels.Label` (nine colour tokens, 40-character names) | Jira labels and components become board labels ([§10.6](#106-labels-and-colours)) |
| Archiving with a reason | `Kanban.Tasks.Archiving` (`:completed`, `:duplicate`, `:wontdo`, `:deferred`, `:cancelled`) | Won't-do, cancelled and duplicate issues ([§13.2](#132-what-happens-to-each-kind-of-item)) |
| Feature gating | `Kanban.Plans`, the only module that decides paid versus free | A new `:imports` feature makes the import and the rewrite Organization-only ([§19](#19-permissions-and-plans)) |
| Files on tasks and comments | `Kanban.Attachments`, its storage behaviour, limits, plan gate and blob tombstones ([Task Attachments](ATTACHMENTS-DESIGN.md)) | Jira attachments are copied through it ([§14.3](#143-attachments)); the rewrite's source files use the same storage and tombstones ([§6A.5](#6a5-how-a-rewrite-runs)) |
| Agents downloading task files | The plugins' attachment download contract (`stride/docs/porting-attachments.md`: `.stride/attachments/<STEM>/`, a manifest, sha256 checks) | The import plugin downloads an epic's files the same way ([§6A.5](#6a5-how-a-rewrite-runs), [§16A.5](#16a5-the-rewrite-epic-procedure)) |
| One plugin family across every runtime | The ideation and security-review families: a Claude Code source plugin (`stride-ideation`, `stride-security-review`) and a port per runtime, each with its own manifest, contract scripts and release | The import plugin is built the same way, as a new family with six variants ([§16A](#16a-the-agent-side-plugin-stride-import)) |
| Credential detection | `Kanban.Tasks.CredentialShapes` | Warns when imported text looks like it carries a secret ([§20](#20-security-and-privacy)) |
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
draft → fetching → fetched → importing → imported → finished
            │          │          │          │
            └──────────┴──────────┴──► failed / cancelled
imported → resyncing → imported      (any number of times until finished)
imported → undone                    (deletes what the run created)
```

Each epic chosen for rewrite has its own state, stored in
`import_rewrites.status`, while the run is `imported`:

```text
pending → drafted → signed_off        (the tasks are written at sign-off)
             │
             └──► pending              (draft discarded, or sent back with a note)
pending / drafted → imported_directly  (the importer changes their mind)
```

A run can be finished only when no rewrite is `pending` or `drafted`.

Fetching and importing are separate steps on purpose. Fetching copies the
Jira issues into a staging table once, so the importer can change the
mapping, preview it and fix warnings any number of times without calling Jira
again. Only **Import** and a rewrite's **Sign off** write tasks.

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
whatever the choice, so no open work loses its goal.

### 6.3 Size limits

| Limit | Value | When it is reached |
|---|---|---|
| Issues per run | 20,000 | The scope page refuses to continue and suggests splitting by project, epic or date |
| Comments per issue | 500 (newest kept) | Older comments are counted in the report and stay in Jira |
| Text per comment | 10,000 characters (the existing comment cap) | Shortened, with a note, and listed under *repaired* |
| Staged data per run | 500 MB | The fetch stops and fails with a clear message. Attachment files are not staged and do not count |
| Attachment files | The attachments limits: 25 MiB per file, 20 per task, the Organization's quota | Files over a limit stay links to Jira ([§14.3](#143-attachments)) |

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
proves that every issue and every requirement in them reached a task, and a
person signs the result off. Nothing is written to the board before that.

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

### 6A.5 How a rewrite runs

The rewrite runs in the team's own agent, against its own checked-out
repository, because filling `key_files` and `patterns_to_follow` needs the
code. Stride prepares the input, checks the output and writes the tasks.

1. **Stride builds the epic bundle** when the run is imported. It holds the
   epic and every issue being rewritten as normalised `Kanban.Imports.Item`
   values ([§8](#8-the-common-item-model)), with the mapped values (priority,
   labels, complexity) alongside as hints, and the context-only issues of a
   split epic. Each acceptance-criteria line, checklist item and sub-task in
   it gets a short id (`ac:2`, `checklist:1`, `subtask:PAY-93`), which the
   coverage map cites ([§16A.4](#16a4-what-each-variant-contains)).
   Restricted issues and comments skipped under
   [§20](#20-security-and-privacy) are never in it. The bundle is stored on
   `import_rewrites` with its SHA-256, so it does not depend on staging, which
   is purged after 14 days. The bundle lists each issue's attachments as
   metadata, and the files themselves are copied into Stride as **source
   files** (below).
2. **The importer starts the rewrite** from the run page. The page shows the
   command to run in the agent, for one epic or for every pending one, in the
   form the importer's runtime uses: `/stride-import:rewrite-epic 41 42` in
   Claude Code, for example, or the `stride-import-rewrite-epic` skill in Codex
   CLI ([§16A.3](#16a3-the-variants)). The agent needs the import plugin
   installed and a token that can reach the destination board.
3. **The agent fetches the bundle**
   (`GET /api/import_rewrites/:id/bundle`) and the import plugin's drafter
   agent writes the epic's goal and tasks, using the bundle and its source
   files as its context and the team's repository for the agent-facing fields.
   The output is the same goal-and-tasks shape as
   [`POST /api/tasks/batch`](../api/post_tasks_batch.md), and the plugin
   applies the same field rules as the `create-goals` skill. Beside it, the
   agent writes a **coverage map**: for each task, the Jira keys and the source
   lines (acceptance-criteria lines, checklist items, sub-tasks) and the source
   files it covers; for each key or file it chose not to cover, a reason.
4. **The plugin's coverage-reviewer agent**, which did not write the draft,
   reads the bundle and the draft and reports, without editing, what it finds
   ([§6A.6](#6a6-the-second-pass-a-coverage-report)).
5. **The agent submits the draft** (`POST /api/import_rewrites/:id/draft`),
   with the coverage map, the reviewer's findings and the bundle hash it worked
   from. The draft is written to the batch file first, as `/stridify` does, so
   it can be read before it is sent.
6. **Stride checks the draft** on receipt: every task through its changeset
   without inserting, as the preview does; the coverage map against the bundle
   (by code, [§6A.6](#6a6-the-second-pass-a-coverage-report)); the bundle hash
   against the stored one; and the credential scan. The rewrite becomes
   `drafted`.

A large epic is split by story into chunks that fit the agent's context. The
command handles the chunks; coverage is computed across all of them, and the
result is still one goal per epic.

**Source files.** Screenshots, designs, logs and specs are often where an
issue's real requirements are, so the agent needs the files, not just their
names.

- When the bundle is built, Stride copies each rewritten issue's attachments
  from Jira into attachment storage, as [§14.3](#143-attachments) does for
  directly imported tasks, with the same allow-list, magic-byte check, size
  limit. They are held by the rewrite (`import_rewrite_files`),
  not by a task, because the task they belong to does not exist yet. A file
  that cannot be copied is listed in the bundle as a Jira link with its
  reason.
- The bundle lists each file with the same eight keys as a task attachment
  (`id`, `filename`, `content_type`, `byte_size`, `sha256`, `comment_id`,
  `uploaded_at`, `download_url`; `comment_id` is always `null`, because no
  Stride comment exists yet), plus the Jira key it came from. The
  `download_url` is `/api/import_rewrites/<id>/files/<file id>`
  ([§16.6](#166-the-rewrite-api)).
- The import plugin downloads them exactly as the Stride plugins download a
  claimed task's files (`stride/docs/porting-attachments.md`): into
  `.stride/attachments/rewrite-<id>/`, with a manifest, the same caps, a sha256
  check on every file, and the token never on a command line. It hands the
  directory to the agents and removes it once the draft is submitted.
- The agent reads images and PDFs with its runtime's own tools and treats
  every file as untrusted data. A file the caps skipped is still listed in
  the manifest, so the agent knows it exists and the coverage map must still
  account for it.
- In the draft, each task names the source files it needs (`files`: file ids).
  A file can go to more than one task.

### 6A.6 The second pass: a coverage report

The second pass is not a second agent saying "looks complete". Part of it is
computed by Stride from the coverage map, and part comes from a reviewer agent
that did not write the tasks.

| Check | Done by | Finds |
|---|---|---|
| **Every key is accounted for** | Stride, from the coverage map | Jira keys in the bundle that no task cites, and keys the agent marked *dropped* (each needs a reason) |
| **Every source line is accounted for** | Stride, from the coverage map | Acceptance-criteria lines, checklist items and sub-tasks no task cites |
| **Every file is accounted for** | Stride, from the coverage map | Source files no task takes and the agent did not mark *not needed* with a reason |
| **Merges and splits are visible** | Stride, from the coverage map | Where several issues became one task, or one issue became several, so the person signing sees the change in shape |
| **Citations are real** | The reviewer agent | A task that cites PAY-88 but does not cover what PAY-88 asks for |
| **Nothing is invented** | The reviewer agent | Requirements, limits or behaviour in a task that no issue or comment supports |
| **Later comments are honoured** | The reviewer agent | A task written from an issue's description when a later comment changed the scope |
| **No instructions aimed at agents** | The reviewer agent | Text carried over from Jira that tells an agent what to do outside the task |

The report has five lists: **Covered**, **Uncovered**, **Dropped with a
reason**, **Unsupported claims** and **Merges and splits**. The reviewer
follows the pattern of stride-ideation's requirements-reviewer: it reports and
never edits.

### 6A.7 Sign-off

The sign-off page shows the draft as task cards (the real task card
component, as the preview does), the coverage report beside it, and each Jira
issue with the tasks that cover it. The person signing can:

- **Sign off**, which writes the goal and its tasks to the board's Backlog in
  one transaction, with source links ([§12](#12-data-that-does-not-map)), and
  then copies each source file onto every task the draft gives it to,
- **Send back** with a note, which returns the rewrite to `pending`; the next
  run of the command receives the note,
- **Leave out** a task from the draft,
- **Mark dropped** an uncovered key or line, with a reason,
- **Import directly instead**, which writes the epic's issues as a direct
  import would, with their source files copied onto the tasks of the issues
  they came from.

An epic **cannot be signed off while anything is uncovered**, unless the
person signing marks it dropped. Signed-off tasks land in Backlog like all
imported work ([§13.1](#131-the-principles)); moving them to Ready is a
separate human step. Each one shows **Written from PAY-88, PAY-91** under its
title. Generated tasks are unassigned, because one task can cover issues
assigned to different people; the source assignees are shown in the
**Written from** panel. The person signing can assign a task to one of them
before signing off, under the matching and member-cap rules of
[§15](#15-people-and-board-membership).

The sign-off page shows each source file with the tasks it will be attached
to, so the person signing can move one. Files are copied from the rewrite's
storage onto the tasks by `AttachmentWorker` after the transaction commits,
through `Kanban.Attachments.import_attachment/4`, with the per-task limit and
the quota checked again; a file attached to two tasks counts twice against the
quota. A file that cannot be copied is listed on the rewrite page with
**Retry**. Once every file is copied, the rewrite's source files are deleted
through the blob tombstones. The **Written from** panel still lists every
source file with its Jira link.

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
| **Imported text tries to steer the agent** | The bundle is untrusted data, not instructions: the existing agent rule applies, the reviewer flags instructions carried into a task, and the person signing sees them |
| **Imported text carries secrets** | The bundle is built after the same `Kanban.Tasks.CredentialShapes` scan as the preview. An issue with a match is held out of the bundle and listed, until it is fixed in Jira or the field is excluded. Drafts are scanned again on receipt |
| **The draft is untrusted input** | It is validated by the task changesets, capped in size, and never written until a person signs it off. A draft submitted against an older bundle hash is refused |
| **Two runs give different tasks** | The rewrite is not deterministic. The coverage report is what makes a result checkable. The bundle, its hash, the signed-off draft and the report are kept with the run, so a rewrite can be audited later |
| **Jira changes after the rewrite** | Re-sync never edits rewritten tasks ([§13.5](#135-re-sync-when-the-team-keeps-working-in-jira)). A change to a rewritten issue is listed under **Changed after rewrite**, naming the tasks written from it |
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

### 7.2 AI-optimized board or custom board

**The import writes only to AI-optimized boards.** Every board a run creates
is made with `Kanban.Boards.create_ai_optimized_board/3`, and a custom board
is not offered. The Phase 3 import into an existing board accepts only a
board with `ai_optimized_board: true`.

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
- **Agents cannot reach it.** Board API tokens are available only on
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
the issue. Searching for a Jira key on the board finds the task (Phase 2).
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
| `attachments` | `[%{external_id, filename, url, size, mime_type, author, created_at}]` | Metadata only; the files are fetched at import time, never staged ([§14.3](#143-attachments)) |
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
  `initiative:`, `jira-status:`, `blocked`, the per-project label) are listed on the mapping
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

**Links to rewritten issues.** A rewritten issue has no task of its own, so a
*blocks* link to or from it is carried in the bundle and resolved at sign-off
through the coverage map: the tasks covering the blocking issue become
dependencies of the tasks covering the blocked one, under the same rules as
the table (same board, no cycles). Inside one epic the agent sets dependencies
itself, as the draft's own index-based dependencies. A link to an epic that is
still `pending` is resolved when that epic is signed off.

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

Some task fields are locked on free boards (`telemetry_event`,
`metrics_to_track`, per `Kanban.Plans.locked_task_fields/0`). An import's
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
| **Kept as unmapped data** on the import link | Every remaining field value, link, link to a file that was not copied, worklog total, sprint history and original parent | The **Imported from** panel on the task: collapsed by default, a readable list, plus **Download Jira data** (JSON) |
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

**Rewritten issues.** A rewritten issue has no task of its own, so its data
cannot live on an import link. The whole item, mapped fields and the rest,
stays in the rewrite's bundle on `import_rewrites`, with the same 64 KB cap per
issue. Each task written from it gets a **source link** per issue it covers,
and its **Written from** panel lists those issues: key, title, status,
assignee, the lines of each issue the task covers, and **Download Jira data**
for each one. So nothing from a rewritten issue is dropped either. It is one
click away from every task written from it, and an issue the rewrite left out
is in the coverage report with its reason.

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
| To Do, in an epic being rewritten | No task of its own; covered by the rewrite's tasks, written to Backlog at sign-off | `status: :open` on the rewritten tasks | [§6A](#6a-rewrite-or-import-epic-by-epic). Put To Do work in Ready does not apply to rewritten tasks |
| To Do, imported directly | Backlog (Ready if the importer opts in) | `status: :open` | |
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
   - **Attachments** on an imported issue follow the same rule as its other
     fields: a new Jira file is copied, unless the task changed in Stride
     (then it is listed with the conflict). A file removed in Jira is not
     removed in Stride; it is listed under **No longer in Jira**.
   - **Rewritten, and the rewrite still `pending` or `drafted`** → the bundle
     is rebuilt with the new version. A draft written from the old bundle is
     marked *stale*, and the sign-off page shows what changed; it can be
     signed off as it is or sent back.
   - **Rewritten and signed off** → the tasks written from it are never
     touched. The issue is listed under **Changed after rewrite**, with the
     change and the tasks that cover it, so a person decides what to do.
   - **New in Jira, in an epic chosen for rewrite** → not started: added to
     the rewrite (a signed-off epic gets a new `pending` rewrite holding just
     the new issues). Started: imported directly under the epic's goal.
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
| The destination board can hold attachments | The attachments plan gate (`:attachments` in `Kanban.Plans`) | Always true when plans are enforced, because an import's boards are always Organization boards ([§19](#19-permissions-and-plans)). It can fail only if the workspace leaves its Organization while files are still being copied; the rest then stay links |
| The type is on the allow-list (PNG, JPEG, GIF, WebP, PDF, plain text, Markdown, CSV, JSON) and the first bytes agree with it | `TaskAttachment.create_changeset/3` | Link, reason *type not stored* (a `.zip`, `.docx`, `.svg`, `.mp4` and the like) or *type mismatch* |
| At most 25 MiB | The per-file limit | Link, reason *too large* |
| At most 20 files on the task | The per-task limit | The oldest 20 are copied; the rest stay links, reason *too many files* |
| The Organization's storage quota (10 GiB) has room | The quota | Copying stops at the quota; the rest stay links, reason *quota* |

The preview shows, per board, how many files and bytes will be copied, how
many will stay links and why, and how much of the quota the import will use.
The importer can choose **Copy attachments** (the default where the board
allows it) or **Link to Jira only**.

**How files are copied.** Files are never staged and never held in memory:

- After a board's transaction commits, `AttachmentWorker` jobs (queue
  `imports`, one per batch of 50 files) download each file from the
  connection's own Jira site, through `UrlGuard`, with
  `GET /rest/api/3/attachment/content/{id}?redirect=false` so the download never
  follows a redirect to another host. The body streams to a temp file and is
  refused if it grows past the size Jira reported or past the per-file limit.
- `Kanban.Attachments.import_attachment/4`, a function the import adds to the
  attachments context, stores it. It runs the same changeset, magic-byte check,
  limits, quota lock and pending-tombstone protocol as `create_attachment/4`,
  but sets `uploaded_by_id` to the matched Jira author ([§15](#15-people-and-board-membership))
  instead of the importer, keeps the Jira upload time, and sends no per-file
  broadcast. One board reload is sent when a board's files are done.
- Each copied file gets a row in `import_attachment_links`, keyed by the Jira
  attachment id, so a retried job or a re-sync never copies a file twice.
- A file that fails (Jira error, storage error) is retried by the job, then
  left as a link and listed in the report with **Retry failed files**.

Copying runs while the run is `imported`. The boards are usable as soon as
their transaction commits, and files appear as they arrive; the run page shows
the progress, and **Finish migration** waits until copying is done.

**Files embedded in descriptions and comments.** Jira attachments belong to the
issue, and descriptions and comments embed them as media nodes. A media node is
matched to an issue attachment by file name, where that name is unique on the
issue. A matched file embedded in exactly one comment is attached to that
comment (`comment_id`); every other file is attached to the task. The text line
becomes *[image: screenshot.png] (attached)*, and keeps the Jira URL only when
the file was not copied ([§14.1](#141-descriptions)). How Jira exposes the
media-to-attachment id should be re-checked when Phase 1 starts; matching by
name is the fallback.

**Linked pull requests.** Linked branches and pull requests from Jira's
development panel, where the site exposes them, are not files. They are listed
on the import link under **Linked pull requests**, as before.

**Rewritten issues.** Their files are handed to the agent and copied onto the
tasks written from them at sign-off ([§6A.5](#6a5-how-a-rewrite-runs),
[§6A.7](#6a7-sign-off)).

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

Rewritten tasks are new work, so their history starts at sign-off with a
`:creation` entry by the person who signed off. A rewritten issue's changelog
stays in the bundle. Since the issues were not started, no cycle time is lost.

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
   changelog actors are not added; their names show on the issues. People
   assigned only to rewritten issues are not added by the import, because
   rewritten tasks are written unassigned. The sign-off page lists them, and
   assigning one of them a task there adds them to the board ([§6A.7](#6a7-sign-off)).

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

Does not apply to imports. On a free board, with plans enforced, a board holds
at most three human members (`Kanban.Plans.free_board_member_cap/0`), but an
import's boards are always in an Organization workspace when plans are
enforced, and an Organization workspace has no cap ([§19](#19-permissions-and-plans)).
While plans are not enforced there is no cap either. The preview still shows
how many people each board will gain.

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
  rewrite.ex                               Schema + state machine: import_rewrites (§6A)
  source_link.ex                           Schema: import_source_links (§12)
  attachment_link.ex                       Schema: import_attachment_links (§14.3)
  rewrite_file.ex                          Schema: import_rewrite_files (§6A.5)
  attachments.ex                           Which files to copy, and why the rest stay links (§14.3)
  rewrite/recommend.ex                     Per-epic path and quality signals (§6A.2)
  rewrite/bundle.ex                        Builds and hashes the epic bundle (§6A.5)
  rewrite/draft.ex                         Validates a submitted draft without inserting (§6A.5)
  rewrite/coverage.ex                      The code half of the coverage report (§6A.6)
  rewrite/writer.ex                        Writes a signed-off draft in one transaction (§6A.7)
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
  workers/attachment_worker.ex             Oban: copy files from Jira or from rewrite storage (§14.3)
  workers/resync_worker.ex                 Oban: re-sync
  workers/cleanup_worker.ex                Oban cron: staging purge, stale credentials

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
- after commit, one `AttachmentWorker` job per batch of 50 files copies the
  board's attachments ([§14.3](#143-attachments)). Files are outside the
  transaction because they are network and storage calls; a file that fails
  never rolls back the board,
- a board that fails rolls back alone. The run ends `imported` with the failed
  board listed and a **Retry this board** action, or `failed` if every board
  failed.

The import writes only the directly imported issues, including the started
work and goals of split epics. In the same transaction it creates one
`import_rewrites` row per epic chosen for rewrite, with its bundle and hash.
After commit, `AttachmentWorker` copies the rewritten issues' files into
`import_rewrite_files`, and the bundle's hash is taken once they are in, so it
covers the file list too. A rewrite can be started only after that.

**Rewrite** (per epic, outside any job):

- the agent fetches the bundle and submits a draft through the API
  ([§16.6](#166-the-rewrite-api)); `Rewrite.Draft` validates it and
  `Rewrite.Coverage` computes the code half of the report, in the request,
- **Sign off** runs `Rewrite.Writer` in one transaction on the destination
  board: the goal (or the existing goal of a split epic) → tasks with
  pre-generated identifiers → the draft's own dependencies → dependencies from
  Jira links ([§10.7](#107-dependencies-and-other-relations)) → source links →
  goal placement, with the same "no broadcast, no notification" rules as the
  import and one board reload after commit; then `AttachmentWorker` copies the
  source files onto the tasks.

**Re-sync** (`ResyncWorker`) fetches into staging with an `updated >=` clause,
then applies [§13.5](#135-re-sync-when-the-team-keeps-working-in-jira) in one
transaction per board.

### 16.4 Idempotency

`import_task_links` has a unique index on
`(board_id, source, source_site, external_id)`. A retried import job finds the
link and skips the issue. A re-sync finds it and updates the task. A second
run of the same project into the same board (Phase 3) cannot duplicate an
issue.

A rewrite is written once: sign-off locks the `import_rewrites` row and
moves it to `signed_off` in the same transaction as the tasks, so a double
click or a retried request finds it signed off and writes nothing. A
re-submitted draft replaces the previous one while the rewrite is `drafted`,
and is refused after sign-off. Files are idempotent through
`import_attachment_links`: a retried `AttachmentWorker` job, a re-sync or a
retried sign-off copy finds the row and skips the file.

### 16.5 Long transactions

A 5,000-issue board with comments is tens of thousands of rows. A single
transaction of that size is expected to take tens of seconds, which is
acceptable for a one-off write to a board nobody else can see yet. Phase 1
measures it. If measurement shows otherwise, the fallback is to write the
board in chunks with `board.import_state = :importing` hiding it from every
list until the last chunk commits. That fallback is listed under
[§24](#24-decisions-needed) and not built up front.

### 16.6 The rewrite API

Three endpoints, for the agent running the rewrite. All three take the usual
Bearer token, which must reach the destination board (a board token for that
board, or a workspace token for its workspace), and all three refuse a rewrite
whose run is not `imported`. With plans enforced, all three first check the
destination board against the `:imports` plan feature and return
`403 plan_required` when it is not in an Organization workspace
([§19](#19-permissions-and-plans)), before any lookup, as the attachment
download does.

| Endpoint | What it does |
|---|---|
| `GET /api/import_rewrites/:id/bundle` | Returns the bundle, its SHA-256, the destination board, the goal of a split epic and any note from **Send back** |
| `GET /api/import_rewrites/:id/files/:file_id` | Streams one source file, with the same headers, uniform 404s, plan check and per-token rate limit as the task attachment download (`GET /api/tasks/:id/attachments/:attachment_id`), so the plugins' download code works unchanged |
| `POST /api/import_rewrites/:id/draft` | Takes the goal and tasks in the [`POST /api/tasks/batch`](../api/post_tasks_batch.md) shape, the coverage map, the reviewer's findings, the bundle hash, the agent name and the plugin variant and version that drafted it (`stride-copilot-import 0.1.0`). Validates without writing, returns the coverage report, and moves the rewrite to `drafted`. Refused with `409` if the hash is not the current bundle's, or the rewrite is signed off |

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
  `stride-opencode-lite`) or neither. The import plugin needs only the API URL
  and token in `.stride_auth.md`.
- **It is released on its own.** The drafter and reviewer rules will change
  as Phase 1's hand checks find missed requirements ([§22](#22-testing-strategy)).
  Those changes ship without a workflow plugin release.

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

`stride-import` (Claude Code) is the source. The other five are ports of it,
built the way the ideation and security-review families are: each follows the
source's procedure and agent rules, uses its runtime's own file layout,
manifest and tool names, and carries a contract script that fails when it
drifts from the source.

| Variant | Runtime | Manifest | Entry point | Agents | Distribution |
|---|---|---|---|---|---|
| `stride-import` | Claude Code | `.claude-plugin/plugin.json` | `/stride-import:rewrite-epic` command | `agents/*.md` | `stride-marketplace` catalog |
| `stride-codex-import` | Codex CLI | `.codex-plugin/plugin.json`, with `AGENTS.md` | `stride-import-rewrite-epic` skill | `agents/*.md` | `stride-codex-marketplace`, vendored |
| `stride-copilot-import` | GitHub Copilot CLI | `plugin.json` at the repository root | `stride-import-rewrite-epic` skill | `agents/*.agent.md` | `stride-copilot-marketplace`, vendored |
| `stride-gemini-import` | Gemini CLI | `gemini-extension.json`, with `GEMINI.md` | `/rewrite-epic` command (`commands/rewrite-epic.toml`) | `agents/*.md` | `stride-gemini-marketplace` catalog |
| `stride-opencode-import` | OpenCode | None: the version is in the CHANGELOG, with `AGENTS.md` | `/rewrite-epic` command | `agents/*.md` | Its own repository, through `install.sh` and `install.ps1` |
| `stride-pi-import` | Pi | `package.json` | `stride-import-rewrite-epic` skill | Agent files that the `stride-pi` subagent-dispatch extension loads, with an inline fallback ([§16A.6](#16a6-the-agents)) | Its own repository, through `install.sh` |

**The lite variants do not get their own.** `stride-lite`,
`stride-copilot-lite` and `stride-opencode-lite` are lighter builds of the
workflow plugin. The import plugin does not depend on the workflow plugin, so
each runtime's one import variant works next to its full or its lite workflow
plugin.

The run page shows the command for each runtime, with a runtime picker that is
remembered per user. Its text comes from `Kanban.Imports.AgentCommands`
([§16.1](#161-modules)); a test compares that table with each variant's
README, so a renamed entry point fails in this repository's tests.

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
  lib/download-files.sh               Source file download (attachment contract)
  lib/download-files.ps1              The same, for Windows
  lib/check-draft.sh                  Local shape check of a draft before it is sent
  fixtures/                           Bundles and expected coverage, for the checks below
  scripts/check_contract.sh           Pins the procedure's rules (as the security-review
                                      ports' check_agent_contract.sh does)
  scripts/check_draft_contract.sh     Fails when draft-contract.md drifts from create-goals
  scripts/test-all.sh                 Runs every check
  README.md  CHANGELOG.md  SECURITY.md  LICENSE
```

**The field rules are pinned, not borrowed.** The drafter needs the
`create-goals` field rules: the `"goals"` root key, index dependencies, the
five fields the review queue scores, `verification_steps` as objects, and the
seven-category `behaviour_test_matrix`. It cannot rely on the workflow
plugin's skill. A lite plugin may not carry it, the skill's gate refuses a
call from outside the workflow orchestrator, and its name differs by runtime.
So each variant carries `draft-contract.md`, a copy of those rules with the
source commit it was taken from. `check_draft_contract.sh` fails when the
source has moved on. The server applies the same rules again when the draft
arrives ([§6A.5](#6a5-how-a-rewrite-runs)), so a stale copy can produce a
refused draft but never a bad task.

**The coverage map schema** lives in `draft-contract.md` and matches what
`Rewrite.Coverage` reads:

```json
{
  "tasks": [
    {"task_index": 0, "covers": [{"key": "PAY-88", "lines": ["ac:2", "checklist:1"]}], "files": [17]}
  ],
  "dropped": [{"key": "PAY-90", "reason": "Duplicate of PAY-88, closed in a comment on 3 Oct"}],
  "files_not_needed": [{"file_id": 19, "reason": "Earlier version of the design in file 17"}]
}
```

Line references (`ac:2`, `checklist:1`, `subtask:PAY-93`) are the ids the
bundle gives each acceptance-criteria line, checklist item and sub-task, so
the coverage check compares ids, not text.

### 16A.5 The rewrite-epic procedure

Arguments: one or more rewrite ids, as the run page lists them. Options:
`--no-files`, which skips the download even when the run allows files, and
`--dry-run`, which stops after writing the local draft file.

1. **Preflight.** Read `STRIDE_API_URL` and `STRIDE_API_TOKEN` from
   `.stride_auth.md`. Stop if the file is missing. The token is never echoed,
   put on a command line or written to a file: requests send it from an
   environment variable or a header file, as the attachment contract does.
   Say once if `.stride/` is not in `.gitignore`, because draft files quote
   Jira text.
2. **Fetch the bundle** (`GET /api/import_rewrites/:id/bundle`). Hash the
   bundle body and compare it with the returned SHA-256; stop on a mismatch.
   A `404` or a run that is not `imported` stops this id and moves to the
   next. A `403 plan_required` stops this id with one line saying the
   destination workspace is no longer in an Organization. A send-back note in the response goes to the drafter.
3. **Download the source files** into `.stride/attachments/rewrite-<id>/`,
   under the attachment download contract: a manifest, the same caps, a
   sha256 check on every file, uniform handling of `404`s, and `Retry-After`
   on `429`. Skipped when the run chose **Rewrite without files** or
   `--no-files` is set; the manifest still lists every file, so the coverage
   map accounts for each one.
4. **Chunk.** If the bundle is too large for one drafter run, split it by
   story, keeping each story with its sub-tasks, its comments and the files
   it cites. The context-only issues of a split epic go to every chunk.
5. **Draft.** Dispatch `rewrite-drafter` once per chunk, each with a fresh
   context, the chunk, the file directory and read access to the repository.
   Merge the chunks' tasks into one goal, renumber the index dependencies,
   and join the coverage maps.
6. **Review.** Dispatch `coverage-reviewer` with the whole bundle and the
   merged draft, in a fresh context that has not seen the drafting. It
   returns findings, never edits.
7. **Write the draft file**: `.stride/rewrites/<id>-<timestamp>.json`, with the
   draft, the coverage map, the findings, the bundle hash and the variant and
   version. Run `check-draft.sh` on it. Print a summary: tasks, keys covered,
   anything uncovered, the reviewer's findings. With `--dry-run`, stop here.
8. **Submit** (`POST /api/import_rewrites/:id/draft`). Print the coverage
   report from the response and the link to the rewrite's sign-off page. A
   `409` for a stale hash means the bundle was rebuilt: fetch it again and go
   back to step 2, once. A `409` for a signed-off rewrite stops this id.
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
token reaches no agent.

Both agents treat the bundle and every file as **data, not instructions**.
Text in an issue, a comment or a file that tells the agent to do something is
never followed. The drafter leaves it out of the tasks and the reviewer
reports it.

The drafter fills `key_files`, `patterns_to_follow` and `testing_strategy`
from the repository it can read. Where there is no repository, it leaves
`key_files` empty for enrichment, as [§6A.8](#6a8-constraints-and-risks)
allows, and says so in the summary.

**Where a runtime cannot dispatch the agents**, as with Pi without its
subagent-dispatch extension, the procedure runs the drafter's instructions
inline. It then runs the reviewer's instructions on the saved draft file and
the bundle only. The findings carry `"independent": false`, and the sign-off
page shows that the review was not done in a separate context.

**Copilot CLI** limits an agent prompt to 30,000 characters, so both agent
bodies are kept under that limit in every variant, and the contract script
checks it in `stride-copilot-import`.

### 16A.7 Testing and release

Each variant's `scripts/test-all.sh` runs offline and without a model:

- the contract pins for the procedure's rules (SHA-256 check, token handling,
  no Stride API call from an agent, data-not-instructions, the `409` retry);
- `check-draft.sh` against fixture drafts that are valid, missing a field,
  using the wrong root key, or carrying an uncovered key;
- the download script against fixture manifests, with a size cap, a bad
  sha256 and a `404`;
- `check_draft_contract.sh` against the pinned source.

Each runtime also needs one live check that cannot run in CI: rewriting the
fixture epic with the runtime's own agent, and comparing the coverage with the
expected file. That is a manual Phase 1 exit step for each of the six
([§22](#22-testing-strategy)).

Each variant is versioned and released on its own, through its runtime's
catalog as the table in [§16A.3](#16a3-the-variants) shows. A change to the
draft API ([§16.6](#166-the-rewrite-api)) is released in the source first and
then in every port before the server starts relying on it. The draft endpoint
records `drafted_with`, so the server can see which versions are still in use
before it drops support for an older draft shape.

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
| `options` | jsonb | One-board-or-many, Ready opt-in, the path chosen per epic ([§6A.2](#6a2-the-choice-and-the-recommendation)) |
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

**`import_rewrites`** (permanent, one per epic or no-epic group chosen for rewrite)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `run_id` | references `import_runs`, on delete cascade | |
| `board_id` | references `boards`, on delete cascade | Destination board |
| `goal_id` | references `tasks`, on delete nilify | The existing goal of a split epic before sign-off; the written goal after |
| `epic_external_id`, `epic_external_key` | string | Nil for a no-epic group |
| `status` | string | `pending`, `drafted`, `signed_off`, `imported_directly` ([§4](#4-the-import-at-a-glance)) |
| `bundle` | jsonb | The items being rewritten and the context-only items, each capped at 64 KB |
| `bundle_sha256` | string | Of the current bundle; a draft must name it |
| `stale` | boolean | Set when re-sync rebuilt the bundle after the draft was submitted |
| `draft` | jsonb | The submitted goal and tasks |
| `coverage` | jsonb | Coverage map, computed report, reviewer findings, and the keys and lines marked dropped by the person signing |
| `send_back_note` | string | Shown to the agent on the next bundle fetch |
| `drafted_by_agent` | string | The agent name sent with the draft |
| `drafted_with` | string | The import plugin variant and version that drafted it ([§16A](#16a-the-agent-side-plugin-stride-import)), so an audit can tell which drafter and reviewer rules applied |
| `signed_off_by_id` | references `users`, on delete nilify | |
| `drafted_at`, `signed_off_at` | utc_datetime | |
| timestamps | | |

Index: unique `(run_id, epic_external_id)`.

**`import_source_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_id` | references `tasks`, on delete cascade | A rewritten task |
| `rewrite_id` | references `import_rewrites`, on delete cascade | Its bundle holds the issue's data |
| `external_id`, `external_key`, `external_url` | string | |
| `covered_lines` | jsonb | Which lines of the issue this task covers |

Index: unique `(task_id, external_id)`; index on `external_key` for Jira-key
search.

**`import_attachment_links`** (permanent)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `task_attachment_id` | references `task_attachments`, on delete cascade | Unique |
| `board_id` | references `boards`, on delete cascade | Part of the idempotency index |
| `run_id` | references `import_runs`, on delete nilify | |
| `source_site`, `external_id` | string | The Jira attachment id |

Index: unique `(board_id, source_site, external_id, task_attachment_id)`, so
one Jira file is copied once per task it belongs to. A Jira file left as a link
has no row here; it is in the import link's unmapped data, or in the rewrite's
bundle, with its reason.

**`import_rewrite_files`** (deleted when its rewrite's files are copied, at
finish, or with the run)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | Used in the file's `download_url` |
| `rewrite_id` | references `import_rewrites`, on delete cascade | |
| `external_id`, `external_key` | string | The Jira attachment id, and the key of the issue it is on |
| `comment_external_id` | string | The comment that embeds it, when there is exactly one |
| `filename`, `content_type`, `byte_size`, `sha256` | as `task_attachments` | Validated by the same changeset |
| `storage_key` | string | Unique; `boards/<board_id>/<uuid>`, as attachment keys are |
| `uploaded_by_id` | references `users`, on delete nilify | The matched Jira author |
| `uploaded_at` | utc_datetime | The Jira upload time |

An `AFTER DELETE` trigger queues each row's blob in `attachment_blob_deletions`,
exactly as the `task_attachments` trigger does, so every path that removes a
rewrite file (sign-off, finish, undo, deleting the board) removes its blob.
Source files count against the Organization's quota while they are held.

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
`<.input>`, `<.button>` and form components.

| Page | What is on it |
|---|---|
| **Imports** `/imports` | Runs in this workspace: Jira site, scope summary, status, boards, who ran it, when. **New import**. In a workspace outside an Organization, with plans enforced, the LockedFeature prompt for *Import* instead, and the sidebar entry shows the lock |
| **Connect** `/imports/new` | Site URL, email, API token, a short "where to create an API token" help with a link to Atlassian's page, **Test connection**, the result. Or pick a connection already saved in this workspace |
| **Scope** `/imports/:id/scope` | [§6](#6-choosing-what-to-import): projects or boards with counts, epics with counts, filters, the JQL box, closed-work choice, running total, limit warnings, restricted-issue count and opt-in. **Fetch** |
| **Fetching** (on `/imports/:id`) | Progress bar by phase (issues, comments, changelog), live; **Cancel** |
| **Rewrite or import** `/imports/:id/paths` | [§6A.2](#6a2-the-choice-and-the-recommendation): one row per epic and per no-epic group, with not-started / started / done counts, file counts, the quality signals, the recommended path and the choice; **Rewrite all recommended**, **Import all directly**, **Rewrite without files**; the note that rewritten text and files go to the team's agent and its model provider |
| **Mapping** `/imports/:id/mapping` | Tabs: *Boards* (one or many, names; every board is AI-optimized), *Status* (each Jira status to one of the five columns), *Issue types and hierarchy*, *Priority*, *Size*, *People*, *Labels*, *Fields* ([§11](#11-mapping-additional-fields)), *Sections*. Every tab shows only values that occur, with counts. **Save as preset** |
| **Preview** `/imports/:id/preview` | Per destination board: task counts by column and type, goals, comments, labels, people added, attachments to copy and to leave as links (with the reasons and the quota they use), and the epics and issue counts that will be rewritten; **sample cards** (ten issues chosen to cover each type and status) rendered with the real task card component; warnings grouped by kind with the issues they affect; blocking errors that must be fixed before **Import** is enabled |
| **Run** `/imports/:id` | During import: progress per board, then file-copy progress, with **Retry failed files**. After: the rewrites, each with its state, and the command to run them in the importer's agent, for the runtime chosen in a picker remembered per user, with a link to that runtime's import plugin ([§16A.3](#16a3-the-variants)); the report ([§21](#21-telemetry-audit-log-and-the-import-report)), **Open board**, **Re-sync changes**, conflicts, **Changed after rewrite**, **Finish migration**, **Undo import**, **Delete stored credential** |
| **Rewrite** `/imports/:id/rewrites/:rewrite_id` | [§6A.7](#6a7-sign-off): the draft as task cards, the coverage report, each Jira issue with the tasks covering it, each source file with the tasks it goes to, the people assigned in Jira; **Sign off**, **Send back**, **Leave out**, **Mark dropped**, **Import directly instead** |
| **Task view** | The **Imported from PAY-88** or **Written from PAY-88, PAY-91** line under the title, and the collapsed panel of the same name ([§12](#12-data-that-does-not-map)) |

---

## 19. Permissions and plans

| Action | Who |
|---|---|
| Start an import into an Organization workspace | Org-admins, and workspace owners of that workspace |
| Start an import into a personal workspace | Nobody when plans are enforced. While they are not, the workspace's owner, as for every paid feature |
| See a run, its report and its unmapped data | The run's creator, the Organization's org-admins, and owners of the boards it created |
| Use a stored connection | Its creator and the Organization's org-admins |
| Re-sync, finish, undo | The run's creator and the Organization's org-admins |
| Choose rewrite or import, send back, sign off a rewrite | The run's creator, the Organization's org-admins, and owners of the destination board |
| Fetch a bundle and submit a draft | An API token that reaches the destination board ([§16.6](#166-the-rewrite-api)) |
| See the **Imported from** panel on a task | Anyone who can see the task |

Org-admins and workspace owners are the roles that can decide who gets access
to boards. An import adds people to boards and attributes work to them, so
plain workspace members cannot start one.

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
  every LiveView event on the import pages, and all three rewrite API endpoints
  ([§16.6](#166-the-rewrite-api)), which check the destination board with
  `check_board/3` and surface `:rest`. A refusal is `{:error, {:plan_required, :imports}}`
  and emits the existing `[:kanban, :plan, :feature_refused]` event.
- **While plans are not enforced**, the check passes everywhere, as for every
  other paid feature, so imports work in any workspace until launch.
- **A workspace that leaves its Organization** during a run: the run's boards
  become free boards. Re-sync, rewrites and sign-off are refused with the
  LockedFeature prompt; **Finish migration**, **Undo import** and
  **Delete stored credential** stay available, so the team can close or
  remove what it brought.

Because every destination is an Organization board when plans are enforced,
the free-board rules never reach an import: no member cap
([§15.3](#153-free-board-member-cap)), no locked task fields
([§11.2](#112-what-a-field-can-be-mapped-to)), and attachments are always
copied where their own limits allow ([§14.3](#143-attachments)).

---

## 20. Security and privacy

| Risk | Rule |
|---|---|
| **The token leaks** | `EncryptedString` at rest; never logged, never in telemetry metadata, the report, an error message, an export or an Oban job argument (jobs carry the run id and load the credential inside the worker); deleted at finish or after 30 idle days |
| **SSRF through the Jira site URL** | `https` only. Every request goes through `Kanban.Webhooks.UrlGuard` with the same resolver configuration webhooks use, so private, loopback and link-local addresses are refused and a host resolving to both public and private addresses is refused. Redirects are not followed to another host. A self-hosted operator can allow private addresses for Jira Data Center with an explicit config switch |
| **Restricted issues become visible to the whole board** | Issues with a security level are **skipped by default**. The scope page shows how many there are and an opt-in, with the warning that everyone on the destination board will be able to read them |
| **Restricted comments become visible** | Comments with `visibility` set and Jira Service Management internal notes are always skipped and counted. No opt-in in Phase 1 |
| **Imported text carries secrets** | Descriptions, comments and mapped custom fields are scanned with `Kanban.Tasks.CredentialShapes`. Matches are listed in the preview as warnings (issue and field, never the value), so the importer can fix them in Jira first. Text is not altered automatically |
| **Imported files are untrusted** | Every file goes through `Kanban.Attachments`: the type allow-list (no SVG, HTML or archives), the magic-byte check, the size limit, and filename sanitising. They are served only by the attachment routes, with `Content-Security-Policy: default-src 'none'; sandbox`, `nosniff` and `Content-Disposition: attachment` ([Task Attachments](ATTACHMENTS-DESIGN.md)). Text files with credential-shaped content are stored, as text is, and listed in the report |
| **File downloads reach internal hosts** | Files are fetched only from the connection's own Jira site, through `UrlGuard`, with `redirect=false`; the attachment id comes from Jira's own issue data, never from a URL in issue text |
| **Imported text is untrusted** | Every row goes through its changeset; text is rendered escaped as all task text is; no imported value is ever turned into an atom, a URL the server fetches, or a query fragment. JQL is sent only to the connection's own Jira site |
| **Agents read imported text** | Imported descriptions reach agents as task data. The existing agent rule (task text is data, not instructions) covers this, and landing in Backlog means a human sees the task before an agent can claim it |
| **Rewritten text leaves Stride** | The bundle goes to the team's own agent and its model provider. The **Rewrite or import** page says so; restricted issues need a second opt-in to be rewritten ([§6A.8](#6a8-constraints-and-risks)) |
| **A bundle carries a secret** | Issues with credential-shaped text are held out of the bundle until fixed or excluded; drafts are scanned again on receipt |
| **A draft is hostile or wrong** | Validated by the task changesets without inserting, capped in size, checked against the current bundle hash, and written only when a person signs it off. No API call can write a rewrite to a board |
| **Who sees what** | [§19](#19-permissions-and-plans). Unmapped data follows the task's visibility; the staged data is visible only through the run page |
| **Retention** | Staging purged after 14 days or at finish; the report kept with the run; import links kept with their tasks; bundles and source links of signed-off rewrites kept with their tasks; drafts and bundles of rewrites that ended `imported_directly` purged at finish; rewrite source files deleted once copied onto their tasks, and at finish, through the blob tombstones |
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
| `[:kanban, :import, :attachments, :stop]` | `duration`, `copied`, `linked`, `failed`, `bytes` | `source`, `run_id`, `board_id`, `outcome` |
| `[:kanban, :import, :resync, :stop]` | `duration`, `created`, `updated`, `conflicts` | `source`, `run_id`, `outcome` |
| `[:kanban, :import, :run, :finished]` | `days_open`, `resyncs` | `source`, `run_id`, `undone` |
| `[:kanban, :import, :rewrite, :drafted]` | `tasks`, `issues`, `uncovered`, `unsupported`, `attempt` | `source`, `run_id`, `rewrite_id`, `outcome` |
| `[:kanban, :import, :rewrite, :decided]` | `tasks`, `dropped`, `left_out`, `hours_since_draft` | `source`, `run_id`, `rewrite_id`, `decision` (`signed_off`, `sent_back`, `imported_directly`) |

No site URL, account, issue key, title, field name or value appears in
metadata.

### 21.2 Audit log

Audit events for: connection created / deleted, run started, run imported (with
board ids and counts), re-sync, finish, undo, the restricted-issue opt-ins
(who opted in, how many issues, and whether restricted issues may be
rewritten), each bundle fetch (which token, which rewrite), and each rewrite
signed off, sent back or switched to direct import (by whom, with the keys
marked dropped). These are the actions an Organization's security team will
ask about.

### 21.3 The report

Kept as `import_runs.report` and downloadable as JSON and CSV:

- **Created:** boards, goals, tasks by type and column, comments, labels, history entries, people added to boards.
- **Rewritten:** per epic, its state, the issues it covers, the tasks written, and the keys and lines dropped with their reasons. An epic that is not yet signed off is listed as *pending*.
- **Attachments:** files copied, bytes used against the quota, and every file left as a link to Jira with its reason (*plan*, *type not stored*, *type mismatch*, *too large*, *too many files*, *quota*, *failed*), by Jira key.
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
| Undo | Boards created by the run deleted; nothing else touched; copied attachments' blobs queued for deletion | DataCase |
| Attachments | Each rule of [§14.3](#143-attachments): plan gate, allow-list, magic bytes, size, the 20-file limit, quota; a body larger than Jira reported; `redirect=false` and `UrlGuard` on every download; uploader from people matching; comment matching by file name; a retried job copies nothing twice; a failed file leaves a link | DataCase with `Req.Test` Jira stubs and the local storage adapter in `tmp/test_attachments` |
| Rewrite files | Copied into `import_rewrite_files` with the same rules; the eight-key bundle entries; the file download endpoint's headers, 404s and rate limit; copied onto every task the draft names at sign-off; blobs tombstoned after copy, at finish and on undo | DataCase, ConnCase |
| Rewrite recommendation | Each row of [§6A.2](#6a2-the-choice-and-the-recommendation) and [§6A.3](#6a3-epics-already-in-progress), each quality signal, the rewrite preselected for every epic with not-started work | Unit tests on `Rewrite.Recommend` with hand-built items |
| Bundle | Rewritten and context-only items, restricted and credential-shaped issues held out, the 64 KB cap, a stable hash | Unit tests on `Rewrite.Bundle` |
| Draft and coverage | A valid draft, an invalid task, an uncovered key, an uncovered line, a dropped key without a reason, a merge and a split, a stale hash, a draft after sign-off | Unit tests on `Rewrite.Draft` and `Rewrite.Coverage`; controller tests for the `409`s |
| Sign-off writer | One transaction; tasks under a new goal, and under the existing goal of a split epic; dependencies from the draft and from Jira links; source links; no broadcast or notification; a double sign-off writes once; sign-off refused while anything is uncovered | DataCase, `refute_enqueued` |
| Rewrite API | Token reach (board, workspace, another board), run state, size cap | `KanbanWeb.ConnCase` |
| People | Email match, case, hidden email, disabled user, user outside the Organization, app accounts, member cap | Mirrors the workspace importer's user tests |
| Security | URL guard on every Jira request, token never in logs or job args or the report, restricted issues and comments skipped | `ExUnit.CaptureLog` scans, Oban job arg assertions |
| Plan gate | `:imports` refused in a workspace outside an Organization with plans enforced, allowed with them off; refused on every run-advancing function, LiveView event and rewrite endpoint; `feature_refused` emitted; a workspace that leaves its Organization mid-run keeps Finish, Undo and credential deletion | DataCase and ConnCase with `:plans_enforced` set per test |
| LiveViews | Each wizard page, permissions per role, translations rendered | `Phoenix.LiveViewTest`; locale tests with the session set |
| Dark mode | Every new page and the task panel | `mix dark_mode.scan` and the contrast check (run by `mix precommit`) |
| End to end | A real Jira Cloud site made for the purpose, with epics, sub-tasks, custom fields, a security level and restricted comments, imported into the dev app, with one epic rewritten, one split epic and one imported directly | Manual / exploratory, Phase 1 and Phase 2 exit |
| Rewrite quality | A set of real, messy epics rewritten by the import plugin, checked by hand for missed requirements the coverage report did not flag | Manual, Phase 1 exit; the misses found become reviewer rules |
| Agent commands | `Kanban.Imports.AgentCommands` has an entry for each of the six variants, and each entry matches the entry point in that variant's README | Unit test against the READMEs' recorded entry points |
| Import plugin, offline | In each of the six variants: contract pins, the draft shape check, the download script, and the pinned field rules against the source ([§16A.7](#16a7-testing-and-release)) | Each variant's `scripts/test-all.sh`, in its own CI |
| Import plugin, live | The fixture epic rewritten through each of the six variants with that runtime's own agent; the coverage matches the expected file, and the draft is accepted by a dev server | Manual, Phase 1 exit, once per runtime |

---

## 23. Phased delivery

Each phase ships on its own and is useful on its own.

| Phase | Scope | Exit criteria |
|---|---|---|
| **1. Core Jira Cloud import** | Needs Task Attachments (G488–G491) shipped. Connections (API token), runs, staging, the adapter behaviour, the Jira Cloud adapter, document-format conversion, epics and sub-task flattening, default mapping, status/type/priority/complexity/people/label mapping tables, restricted issues and comments, preview, writer, attachment copying, report, **Imported from** panel, undo, telemetry, audit. **The rewrite** ([§6A](#6a-rewrite-or-import-epic-by-epic)): the **Rewrite or import** page and its recommendation, split epics, bundles and source files, the rewrite API, drafts, the coverage report, sign-off, the **Written from** panel, and the new `stride-import` plugin in all six variants: Claude Code, Codex CLI, GitHub Copilot CLI, Gemini CLI, OpenCode and Pi ([§16A](#16a-the-agent-side-plugin-stride-import)) | A Jira project of ~2,000 issues with epics, sub-tasks and comments imports with no silent loss; the report accounts for every issue and every file. Every not-started epic in it can be rewritten and signed off, and a hand check of the rewritten epics finds no requirement missing that the coverage report did not flag. The fixture epic rewrites and is accepted through every one of the six variants, each released through its runtime's catalog |
| **2. Custom fields and polish** | Custom field discovery and mapping ([§11](#11-mapping-additional-fields)), section extraction, mapping presets, Jira-key search, *Exclude imported history* on metrics | A project whose acceptance criteria and team data live in custom fields imports them into Stride fields |
| **3. Moving while working** | Re-sync and conflicts (including stale drafts and **Changed after rewrite**), Finish migration, the optional "moved to Stride" marker, import into an existing board, OAuth 2.0 (3LO) | A team can import, keep working in Jira for two weeks, re-sync, and finish with no lost changes |
| **4. Jira Data Center** | `jira_dc` adapter, PAT auth, REST v2, wiki markup, self-hosted private-address switch | A Data Center instance imports through the same pipeline |

---

## 24. Decisions needed

These were the choices the design could not make on its own. All of them were
settled on 2026-10-30: decisions 3 and 13 were changed to Organization-only,
and every other recommendation was accepted as written.

| # | Question | Decision |
|---|---|---|
| 1 | Where should To Do work land: Backlog or Ready? | **Backlog**, with an opt-in for Ready ([§10.3](#103-status-to-column)). It is the only default that cannot hand an agent a context-free task |
| 2 | Should the import offer custom boards as well as AI-optimized ones? | **No**: AI-optimized boards only ([§7.2](#72-ai-optimized-board-or-custom-board)). The fixed five columns are what agents and the rewrite rely on, and they remove the column-stage guessing a custom layout would need. An explicit stage per column is no longer needed for imports |
| 3 | Is import available on every plan? | **No: Organization only.** Import, re-sync and mapping presets are the `:imports` plan feature; when plans are enforced only a workspace in an Organization can start an import ([§19](#19-permissions-and-plans)) |
| 4 | Where does unmapped data live? | **On the import link**, shown in a collapsed panel ([§12](#12-data-that-does-not-map)), not in the description or `technical_details` |
| 5 | Should stories with sub-tasks become goals? | **No by default** (flatten under the epic), with the option on the mapping page ([§10.2](#102-hierarchy)) |
| 6 | One transaction per board, or chunked writes with a hidden board? | **One transaction**, measured in Phase 1; chunked only if measurement demands it ([§16.5](#165-long-transactions)) |
| 7 | Should imported history count in metrics? | **Yes by default**, with *Exclude imported history* on the metrics pages in Phase 2 ([§14.4](#144-history)) |
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
| Attachment files | Listed in each issue's `attachment` field; content from `GET /rest/api/3/attachment/content/{id}?redirect=false`, so the file comes from the site itself rather than a redirect to another host |
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
| `mediaSingle` / `mediaGroup` / `media` | `[image: <name>] (attached)` or `[file: <name>] (attached)` when the file was copied ([§14.3](#143-attachments)); otherwise `[image: <name>](<Jira URL>)` or `[file: <name>](<Jira URL>)` |
| `status` (lozenge) | `[<text>]` |
| `date` | ISO date |
| `expand` / `nestedExpand` | Its title in bold, then its content |
| `hardBreak` | Newline |
| Unknown node | Its text content, and a count in the report under *repaired* |

NUL bytes and invalid UTF-8 are removed from all converted text, because the
database columns cannot hold them.

