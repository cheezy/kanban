# Retention and Legal Hold — Implementation Design

**Roadmap item:** *Retention and legal hold*, under *Planned*: "Set how long archived tasks are kept, and hold them when a legal matter requires it." ([ROADMAP](../../ROADMAP.md))

**Status:** Proposed design, not yet decomposed into tasks. Every decision in [§14](#14-decisions-needed) is settled: D1–D9 on 2026-11-10; D10–D14, which the exploratory review raised, the same day; D15–D17, with D8 revised, on 2026-11-18; and D18–D21, with D16 revised, which the second exploratory review raised, the same day.

**Date:** 2026-11-10, revised the same day to record the decisions and again
to apply the exploratory review (`.exploratory/retention-legal-hold-design/SUMMARY.md`).
Revised on 2026-11-18 for what has shipped since: signed audit exports (D8)
and the audit stream's security emails (D15). Revised again the same day to
apply the second exploratory review
(`.exploratory/sessions/2026-11-18-1241-docs-plans-retention-and-legal-hold-desi.md`).

This document describes two related controls for an Organization:

- a **retention period for archived tasks**: archived tasks are deleted for
  good once they have been archived for longer than the period the
  Organization chooses;
- **legal holds**: when a legal matter requires it, an org-admin places a hold
  on the whole Organization, a workspace or a board. While the hold lasts,
  nothing it covers can be permanently deleted, by a person, by an agent, by
  retention or by a cascade, and edits keep the earlier version.

It covers what exists today, the rules, how they are enforced in the
application and in the database, the screens, the security rules, the tests,
and the work broken into goals and tasks.

**Both are Organization features.** Only an org-admin can set them, from the
Organization console. Boards outside an Organization keep the site-wide
setting they have today ([§5.5](#55-boards-outside-an-organization)).

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [What exists today](#2-what-exists-today)
3. [At a glance](#3-at-a-glance)
4. [Access and the plan gate](#4-access-and-the-plan-gate)
5. [Retention for archived tasks](#5-retention-for-archived-tasks)
6. [Legal holds](#6-legal-holds)
7. [Enforcement](#7-enforcement)
8. [Exporting held data](#8-exporting-held-data)
9. [Data model](#9-data-model)
10. [Screens](#10-screens)
11. [Security](#11-security)
12. [Telemetry, audit events, notifications and docs](#12-telemetry-audit-events-notifications-and-docs)
13. [Testing strategy](#13-testing-strategy)
14. [Decisions needed](#14-decisions-needed)
15. [Goals, tasks and order](#15-goals-tasks-and-order)
16. [Risks](#16-risks)

---

## 1. Goals and non-goals

### Goals

- An org-admin can set **how long archived tasks are kept**, for the whole
  Organization: **follow the site setting** (the default, and what happens
  today), **forever**, or a number of days.
- Archived tasks past the period are **deleted for good**, with their
  comments, history, labels and attachments, by the existing daily retention
  job.
- Shortening the period **never deletes anything at once**. The shorter period
  starts to apply after a waiting time, and every org-admin is told roughly
  what it will delete and when ([§5.3](#53-changing-the-period)). A board that
  joins the Organization gets the same wait.
- People can see **after which date an archived task will be deleted**, on the
  board's Archive page.
- An org-admin can place a **legal hold** on the Organization, a workspace or
  a board, naming the matter, and release it when the matter ends. A release
  waits 7 days and can be cancelled.
- While a hold covers it, **no task, comment, attachment, task history or label
  in use can be permanently deleted**: not from the board, the Archive page, a
  column or board deletion, the retention job, or a database cascade.
- While a hold covers it, **edits keep the earlier version**: of a task's
  content, of a comment, of the archive details an unarchive clears, of the
  labels on a task, and of every author the database clears when an account is
  deleted.
- A hold on the whole Organization can also **pause audit log retention**, so
  the Organization's audit events are kept for the matter too.
- Placing, requesting a release, cancelling it, the release itself and every
  refused deletion are **audit events**, and every org-admin is emailed about
  each step of a hold's life.
- An org-admin can **export** everything a hold covers, including the earlier
  versions it kept, as a signed archive ([§8](#8-exporting-held-data)).

### Non-goals (for this roadmap item)

- **Archiving tasks automatically.** Stride never archives a task by itself
  today, and this item does not add that. Retention applies only to tasks
  people have archived.
- **Retention for live tasks, comments or history.** Only archived tasks are
  deleted by age.
- **Holds on a person.** eDiscovery tools often hold everything one person
  (a "custodian") wrote, wherever it is. A hold here covers a place: the
  Organization, a workspace or a board ([§14](#14-decisions-needed), D2).
- **A matter-management tool.** A hold records a matter name, a reason and who
  placed it. Stride does not track legal deadlines, send hold notices with
  acknowledgements, or interview custodians.
- **Freezing a board.** A hold preserves; it does not stop work. People and
  agents keep creating, editing, moving and archiving tasks on a held board.
- **Holds on boards outside an Organization.** Personal and free boards keep
  today's behaviour.
- **Retention or hold information in the API.** Agents can't archive through
  the API and the task JSON has no archive fields, so the API gains nothing
  ([§14](#14-decisions-needed), D14).

---

## 2. What exists today

| Piece | Where | What it does today |
| --- | --- | --- |
| The daily retention job | `lib/kanban/retention/purge_worker.ex`, cron 03:47 UTC on `:maintenance` | Four steps: each Organization's audit events by its `audit_retention_days`; site audit events (90 days); **archived tasks**, only when the site setting `archived_task_retention_days` is set (default `nil`, keep all), **on every board, Organization boards included**; expired SAML state. Each step runs on its own, with no transaction around it, and a failed step is listed in `failed_steps`. Each Organization's audit step runs inside `Kanban.AuditStream.Retention.purge/4`: it takes the Organization's stream destination leases (skipping that Organization for the day when one is held, listed in `audit_stream_skipped`) and records as a gap what each destination had not yet sent. Records one `retention_purge` audit event per run, with `organization_counts` (audit events per Organization), `archived_task_count`, `failed_steps` and `audit_stream_skipped` among its keys |
| Archived-task purge | `Kanban.Archives.Retention.purge_archived_before/2` | Deletes archived tasks older than a cutoff with `Repo.delete_all`, in batches. It keeps a goal while any child is kept, and a task an unarchived task depends on. **Site-wide only**: there is no per-Organization or per-board period |
| Audit purge | `Kanban.AuditLog.Retention.purge_organization_before/3`, `Kanban.AuditLog.purge_before/1`, and the database purge functions in [audit-log-hardening.md](../audit-log-hardening.md) | The worker calls the first, through the `Kanban.AuditLog` delegate and the stream wrapper above. `purge_before/1` has no caller in `lib/` but an operator can run it. The database functions keep a 90-day floor, refusing a newer cutoff with SQLSTATE `KAP01`, and know nothing of Organizations' settings |
| The security policy | `Kanban.Organizations.SecurityPolicy`, edited on `/org/security` (`OrgLive.Security`) through `SecurityPolicies.update_policy/2` | `require_two_factor`, `two_factor_grace_days`, and `audit_retention_days` (90 to 3650, or `nil` for forever). `editable_fields/0` is both what the form casts and what `organization_policy_updated` compares. One form and one **Save** cover every setting |
| Archiving | `Kanban.Tasks.Archiving` | `archive_task/2` sets `archived_at`, `archive_reason`, `archive_note`, `archived_by_id` and `duplicate_of_id`, and cascades to a goal's children. `unarchive_task/1` **clears all five**, so the reason and note are lost. People archive in three places: a task's **Archive** action on the board, the board's bulk-selection bar, and **Archive old (30d+)** on the Archive page. None is a form. The API can't archive (`task_param_filter.ex` refuses the archive fields), and the task JSON carries no archive fields |
| Deleting a task | `Kanban.Tasks.Lifecycle.delete_task/1`, which takes no actor | Refuses `:has_dependents`, then deletes. Deleting a goal's last child **also deletes the goal**, in a second statement outside a transaction. Called from the board (**Delete**) and the Archive page (**Delete forever**). There is no API or MCP delete |
| Deleting a column | `Kanban.Columns.delete_column/2` | `Repo.delete` with no check. `tasks.column_id` is `on_delete: :delete_all`, so **every task in the column is deleted, archived ones included**. The board's confirmation says "All tasks in this column will also be deleted" but gives no count and never mentions the archived tasks, which the board doesn't show. That is a defect of its own ([§15](#15-goals-tasks-and-order)). The confirmation is a fixed `data-confirm` text that the browser shows before anything reaches the server. `BoardLive.Show` lets only the owner delete a column, and never on an AI-optimized board |
| Deleting a board | `Kanban.Boards.delete_board/2`, owner only, from **Delete** on the board list (`BoardLive.Index`) | Cascades columns, tasks, comments, history, labels and attachments, and also the board's API tokens, members, notifications and webhook endpoints |
| Moving a board | `Kanban.Workspaces.BoardMoves` | Moves a **personal** board into an Organization workspace. There is no move back to a personal workspace, and none between Organization workspaces, so a board in an Organization never moves. A move is refused with `{:error, {:quota_exceeded, sizes}}` when the board's files would take the Organization past its attachment storage (`Kanban.Attachments.Usage.check_board_move/2`) |
| Labels | `Kanban.Labels`, tables `labels` (per board) and `task_labels` | `delete_label/2` is a plain `Repo.delete`; `task_labels.label_id` is `on_delete: :delete_all`, so deleting a label removes it from every task. `set_task_labels/3` adds and removes a task's labels. Nothing records either |
| Workspaces and Organizations | `workspaces.organization_id`, `boards.workspace_id` | `on_delete: :restrict`; there is no function that deletes an Organization or an Organization workspace |
| Comments | `Kanban.Tasks.Comments` | `delete_comment/2` deletes; `update_comment/3` overwrites `content` and sets `edited_at`, **keeping no earlier version** |
| Task history | `task_history` | Records only creation, moves, priority changes and assignment. Edits to a task's title, description and other text **leave no history** |
| Attachments | `Kanban.Attachments`, [attachments.md](../attachments.md) | An `AFTER DELETE` trigger on `task_attachments` queues each stored file in `attachment_blob_deletions`, which `BlobCleanupWorker` empties every 15 minutes. That covers direct deletes, cascades and `delete_all`, so a deletion stopped in the database never queues a file. An Organization has 10 GB of attachment storage (`Kanban.Attachments.Limits`, counted by `Kanban.Attachments.Usage`). An upload, a board move into the Organization and a workspace import are each refused with `:quota_exceeded` when it is full |
| Leaving an Organization | `Kanban.Workspaces.MembershipCascade` | Unassigns the person's open tasks and releases their claims on the Organization's boards |
| Account deletion | `Kanban.Accounts.AccountDeletion` (`delete_own_account/3`, `delete_disabled_managed_account/1`), `Kanban.Accounts.AdminManagement.delete_user/2`, `Kanban.Workspaces.PersonalCleanup` | Three ways in: a person deleting their own account; a site admin deleting a disabled managed account, routed to `delete_disabled_managed_account/1`; and a site admin deleting any other account, which `delete_user/2` deletes directly. All three delete the user row, and foreign keys set to `NULL` (`nilify_all`) nine author columns on the tables a hold covers: `tasks.created_by_id`, `completed_by_id`, `reviewed_by_id`, `archived_by_id` and `assigned_to_id`; `task_comments.author_user_id`; `task_history.from_user_id` and `to_user_id`; `task_attachments.uploaded_by_id`. `audit_events.actor_user_id` is cleared the same way, so the audit log loses the link to the person |
| Workspace export | `Kanban.Workspaces.Export`, org-admin only, [workspace-export.md](../workspace-export.md) | A zip of a workspace's boards, columns, tasks (**archived included**), comments, task history and attachment files, as JSON arrays, with a `manifest.json` (format, format version, `exported_at`, app version, workspace, counts, files, skipped attachments). An Oban job (`Export.Worker`, one attempt) builds it from one `REPEATABLE READ` snapshot, whose start is `exported_at`, then copies the files. The `workspace_exports` row holds only the workspace, who asked, the status and the file. A unique index (`workspace_exports_one_active_index`) allows one pending or running export per workspace. The importer (`Export.Importer.Archive`) accepts exactly the manifest, the format's JSON files and `attachments/<id>` files, and refuses any other name. Kept for 7 days. No audit events, no signature |
| Signed audit export | `Kanban.AuditLog.SignedExport`, `Kanban.AuditLog.Signing`, [audit-log-signed-exports.md](../audit-log-signed-exports.md) | Streams one audit file with a `manifest.json` (schema `stride.audit-export.v1`, instance, the file's size and SHA-256, `key_id`, `snapshot_at`), `manifest.json.sig` (Ed25519 over the manifest's bytes) and an unsigned `README.txt`. `signed_export_available?/0` reads the current config. The docs cover publishing previous keys after a rotation, and revocation |
| Security emails to org-admins | `Kanban.Notifications.AuditStreamAlerts`, `AuditStreamEmailWorker` | One job per enabled org-admin on `:notifications`, queued in the caller's transaction, with no preference or plan gate. The args are a snapshot, and nothing is read from the destination when the email is sent. At send time the worker skips a recipient who is no longer an enabled org-admin, and shows a deleted actor as a deleted account. Three attempts |
| Audit log | [audit-log-hardening.md](../audit-log-hardening.md), [organization-security-policies.md](../organization-security-policies.md#audit-retention) | Append-only, with a 90-day floor in the database purge function. The site-admin viewer at `/admin/audit-log` lists every Organization's events |
| Database errors | `Kanban.Tasks.DbErrors` | Rescues one `Postgrex.Error` SQLSTATE and turns it into an error tuple, re-raising every other. The pattern for mapping a new SQLSTATE. The one custom SQLSTATE in use is the audit purge's `KAP01`, which `AuditLog.purge_before/1` and `AuditLog.Retention` rescue into `{:error, :cutoff_too_recent}` |

---

## 3. At a glance

```text
 Organization console (org-admins)
   ├── Security: "Keep archived tasks: [site setting | forever | 365 days]"   ── §5
   │             its own card and Save; a shorter period waits 7 days
   └── Legal holds: place a hold on the Organization, a workspace or a board ── §6
                    name the matter, give a reason;
                    a release waits 7 days and can be cancelled;
                    Export held data: a signed zip of what it covers           ── §8

 Every step above, and each one the nightly job applies
   → an audit event, and an email to every org-admin queued
     in the same transaction                                                   ── §12.3

 Daily retention job (03:47 UTC)
   apply holds whose release date has passed         (one transaction each)
   apply retention changes whose date has passed     (one transaction each)
   for each Organization:
     archived tasks archived before (now − its period)
       minus tasks on held boards
       minus kept goals and depended-on tasks (as today)   ── deleted, with their files
     audit events: skipped while an Organization-wide hold pauses audit retention
   revisions: deleted 30 days after every hold they were kept for is released

 Any delete of a held task, comment, attachment, label in use, column or board
   1. the context refuses it with {:error, :legal_hold}   (a clear message)
   2. a database trigger refuses it anyway                (covers cascades and bugs)
   → a legal_hold_deletion_refused audit event, written after the rollback

 Any change that would carry a held row out of a hold's cover
   (a board's workspace, a column's board, a task's column on another board, …)
   → refused by a database trigger

 Any edit on a held board
   → the earlier version is kept in legal_hold_revisions (a database trigger)
```

---

## 4. Access and the plan gate

- **Who.** Only an enabled org-admin of the Organization can change the
  retention period, place holds, request or cancel a release, and export held
  data. The pages use `on_mount {KanbanWeb.UserAuth, :require_org_admin}` and
  re-read the role on every event, as `OrgLive.Security` does. The
  Organization's two-factor requirement applies ([§14](#14-decisions-needed),
  D1).
- **The plan.** Both are Organization features, so every Organization has
  them. No new plan feature is needed.
- **Site admins.** Stride's own site admins cannot see or change an
  Organization's holds or retention in the Organization console. They **do**
  see the `legal_hold_*` and retention audit events in the site audit log at
  `/admin/audit-log` and its export, which list every Organization's events.
  Those events carry ids and the scope only, never the matter name or reason
  ([§11.2](#112-what-holds-reveal)). An operator of a self-hosted instance can
  still reach the database ([§7.4](#74-what-enforcement-cannot-do)).
- **Holds belong to the Organization**, not to the org-admin who placed them.
  An org-admin leaving or deleting their account does not release anything.

---

## 5. Retention for archived tasks

### 5.1 The setting

The Organization's security policy gains **Keep archived tasks**, with three
choices:

- **Follow the site setting**, the default. Organization boards are treated as
  they are today: the site setting `archived_task_retention_days` applies, and
  when it is unset nothing is deleted. Shipping this item changes nothing on
  any instance until an org-admin picks something else
  ([§14](#14-decisions-needed), D13).
- **Forever**: nothing is deleted, even when the site setting is set.
- **A number of days**, from **30 to 3650**.

The 30-day minimum means a typing mistake can't delete what was archived this
week. It is checked by the form and by a database check constraint, for the
period in force and for a pending one.

The period counts from each task's `archived_at`. A task that is unarchived
and archived again starts again from its new `archived_at`.

**Which period is longer.** Retention changes are compared by the period they
would apply now. **Forever**, and **Follow the site setting** while the site
setting is unset, are the longest. **Follow the site setting** with the site
setting set counts as that number of days.

### 5.2 What the job deletes

The archived-task step of `Kanban.Retention.PurgeWorker` changes from one
site-wide cutoff to one cutoff per Organization:

- **Boards in an Organization** use the Organization's period in force
  ([§5.3](#53-changing-the-period)).
- **A board that joined the Organization less than 7 days ago** uses whichever
  of the site setting and the Organization's period keeps tasks longer. The
  board records when it joined (`boards.organization_joined_at`, set by
  `BoardMoves`), so moving a board in can't delete its history overnight
  ([§14](#14-decisions-needed), D11). Boards already in an Organization when
  this ships have the column unset and get no grace.
- **Boards outside an Organization** keep the site setting,
  `archived_task_retention_days` ([§5.5](#55-boards-outside-an-organization)).
- **An Organization with no security policy row** follows the site setting.

`Kanban.Archives.Retention.purge_archived_before/2` gains a board scope, so
each Organization's purge touches only its own boards. It keeps its existing
rules (a goal is kept while a child is kept; a task an unarchived task depends
on is kept), and gains one: **a task on a held board is never selected**
([§6](#6-legal-holds)). A deleted task takes its comments, history, labels and
attachments with it, as today, and its files are queued for removal by the
existing trigger.

Before the archived-task step, the job applies every pending retention change
whose date has passed ([§5.3](#53-changing-the-period)), so the new period
applies on that same run. The Organization audit step, and its
`AuditStream.Retention` wrapper with the leases and gap recording
([§2](#2-what-exists-today)), is left as it is.

The `retention_purge` audit event keeps its existing keys and gains one,
`archived_task_counts`: a list with one entry per Organization that had tasks
deleted or kept, each `%{organization_id, archived_count}`. H7 adds
`held_count` to each entry once holds exist. The name keeps it apart from the
existing `organization_counts`, which counts audit events. The existing
`archived_task_count` becomes the total deleted across every board, inside
and outside Organizations, and is `nil` only when no board had a period. The
key is declared in the catalog like any other ([§12.2](#122-audit-actions)).

### 5.3 Changing the period

The retention setting has its own function,
`Kanban.Organizations.SecurityPolicies.set_archived_task_retention/2`, its own
card and **Save** on `/org/security`, and its own audit actions. It is not in
`SecurityPolicy.editable_fields/0`, so the shared policy form can't cast it
and an unrelated save can't touch it ([§14](#14-decisions-needed), D12).

- **Making it longer**, or choosing a choice that is no shorter, applies at
  once. It records `archived_task_retention_changed`.
- **Making it shorter waits 7 days.** The new choice is saved as the pending
  one, with `archived_task_retention_effective_at` 7 days ahead and who asked.
  The job keeps using the period in force until then. It records
  `archived_task_retention_change_scheduled`, and every org-admin is emailed
  with:
  - who made the change;
  - the period in force and the new one;
  - the date from which the next nightly run will apply it;
  - **about** how many archived tasks it would delete then, counted now. The
    email says the count is an estimate: tasks archived before that date, and
    holds released before it, can add to it.
- **Only one change waits at a time.** A new choice while one is pending
  replaces it. If the new choice is no shorter than the period in force, the
  pending change is cancelled and the new choice applies at once; if it is
  shorter, the 7-day wait starts again from now. Both are audited and emailed.
- **Cancel change** clears the pending change. It records
  `archived_task_retention_change_cancelled` and is emailed.
- **When the date passes**, the next nightly run moves the pending choice into
  force before deleting anything. In one transaction per Organization it
  updates the policy, records `archived_task_retention_change_applied` with no
  actor, and queues an email to every org-admin with the period now in force
  and about how many archived tasks it will delete in that run, counted then
  ([§14](#14-decisions-needed), D21). This mirrors the email sent when a
  hold's release takes effect ([§6.6](#66-releasing-a-hold)), so people who
  missed the first email learn that deleting has started.

A shorter period can't be used to delete a lot of history overnight, and a
mistake has a week to be noticed ([§14](#14-decisions-needed), D7).

### 5.4 What people see

- **The Archive page** says how long the Organization keeps archived tasks:
  "Archived tasks are deleted 365 days after they are archived." When a change
  is pending it adds: "From 12 December 2026, archived tasks will be deleted
  90 days after they are archived." Each row shows one of
  ([§10.3](#103-the-archive-page)):
  - **Deleted after** *date*: the day `archived_at` plus the period in force
    is reached. The nightly run deletes it the first night after, so "after".
  - **Kept while a task in this goal is open**, for a goal the job keeps
    because a child is kept;
  - **Kept while another task depends on it**, for a depended-on task;
  - **Kept forever**, when nothing is deleted;
  - **On hold**, when a hold covers the board.

  Dates are shown in the reader's locale, with the year, as the rest of the
  page does for long-range dates.
- **Archiving a task** on a board with a period shows the same sentence in
  each of the three places people archive ([§2](#2-what-exists-today)): in the
  confirmation of a task's **Archive** action, of the bulk bar's **Archive**,
  and of **Archive old (30d+)**. Where one of them has no confirmation today,
  the sentence goes in a line under the action. Nobody archives something they
  need without knowing.
- **Moving a board into an Organization** states the Organization's period in
  the move's confirmation, and when it starts to apply to the board
  ([§5.2](#52-what-the-job-deletes)). The confirmation keeps its existing
  refusal when the board's files don't fit the Organization's storage
  ([§2](#2-what-exists-today)).
- **Agents** see nothing new. They can't archive through the API, and the task
  JSON carries no archive fields, so no deletion date is added
  ([§14](#14-decisions-needed), D14). A deletion date in the API would also
  show which tasks are held, by being missing.

### 5.5 Boards outside an Organization

Personal and free boards are unchanged: the site setting
`archived_task_retention_days` (unset by default) applies to them, and they
cannot be held ([§14](#14-decisions-needed), D9). The comment beside the setting in `config/config.exs` and the
operator docs say that it applies to boards outside an Organization, and to
Organizations that follow the site setting.

---

## 6. Legal holds

### 6.1 What a hold is

A hold has:

- a **matter name**, at most 120 characters, such as "Northwind v. Acme";
- a **reason**, at most 2,000 characters, which can hold privileged detail and
  is stored encrypted;
- a **scope**: the whole Organization, one workspace, or one board;
- for an Organization-wide hold, whether it also **pauses audit log retention**
  ([§6.8](#68-audit-events));
- who placed it and when;
- its **release requests**, each one kept for good: who asked, when, why,
  and the date it takes effect, and then whether it was cancelled (by whom
  and when) or applied ([§6.6](#66-releasing-a-hold));
- once released, when.

An Organization can have up to **100 active holds**. Holds can overlap. Data is
held while **any** active hold covers it. A hold's matter name, scope and
audit pause cannot be changed; for a different scope, place a new hold and
release the old one. A hold is never deleted, only released, so the record of
every hold stays.

A hold is in force from the moment it is saved. A delete whose statement had
already started may still finish ([§7.4](#74-what-enforcement-cannot-do)).

### 6.2 What a hold covers

A hold covers everything inside its scope, as it is **now**:

- **Organization:** every board in every workspace of the Organization.
- **Workspace:** every board in that workspace.
- **Board:** that board.

On a covered board, it covers:

- every task, open or archived;
- the task's comments, attachments, comment attachments, history and labels;
- every label of the board that a task carries;
- every column that holds a task, and the board itself. An empty column is not
  held and can be deleted ([§6.3](#63-what-a-hold-blocks)).

Scope follows the board: a personal board moved into a held workspace or
Organization becomes held. A board never leaves an Organization
([§2](#2-what-exists-today)), and the database refuses any change that would
take a held row out of a hold's cover ([§7.2](#72-in-the-database)).

### 6.3 What a hold blocks

| Action | While held |
| --- | --- |
| Delete a task, from the board (**Delete**) or the Archive page (**Delete forever**) | Refused: "This task can't be deleted while your Organization holds this board for a legal matter." |
| Delete a goal's last child (which today also deletes the goal) | Refused, as above, and neither is deleted |
| Delete a comment | Refused |
| Delete an attachment, on a task or a comment | Refused |
| Delete a label that a task on the board carries | Refused. A label no task carries can be deleted |
| Delete a column | Refused while it holds any task, archived or not. An empty column can be deleted |
| Delete a board | Refused |
| Change a held row's parent: a board's workspace, a workspace's Organization, a column's board, a task's column to one on another board, or the task of a comment, attachment, history row or label link | Refused by the database ([§7.2](#72-in-the-database)). No screen does any of these today |
| Retention deleting an archived task | Not selected ([§5.2](#52-what-the-job-deletes)) |
| Retention deleting audit events | Skipped while an Organization-wide hold pauses audit retention ([§6.8](#68-audit-events)) |
| A database cascade, bulk delete or `TRUNCATE` that reaches a held row | Refused by the database ([§7.2](#72-in-the-database)) |

Each refusal the application sees also records a `legal_hold_deletion_refused`
audit event, naming who tried, what and where, but not the matter
([§12.2](#122-audit-actions)), so an attempt to destroy held data leaves a
trace.

### 6.4 What keeps working

Everything else on a held board works as before:

- people and agents create, edit, move, claim, complete and review tasks;
- tasks are archived and unarchived;
- comments are added and edited;
- attachments are uploaded;
- labels are added to and removed from tasks, created and renamed;
- assignments change.

The one difference is that edits keep the earlier version
([§6.5](#65-edits-keep-the-earlier-version)).

### 6.5 Edits keep the earlier version

On a held board, when any of these changes is saved, the database copies the
earlier values into `legal_hold_revisions` ([§7.3](#73-keeping-earlier-versions)):

- **a task's content**: every column of `tasks` except where it is and who is
  working on it. Left out are `position`, `column_id`, `status`, `updated_at`,
  the claim fields `ClaimRelease` writes (`claimed_at`, `claim_expires_at` and
  the rest), and `assigned_to_id`, except when `assigned_to_id` is cleared.
  `task_history` already records moves and assignments, so claiming,
  unclaiming and dragging a card add nothing. The title, description,
  acceptance criteria and the other text fields, its review and completion
  details, and `created_by_id`, `completed_by_id`, `reviewed_by_id` and
  `archived_by_id` are kept;
- **a comment's content and author**, when it is edited or the author is
  cleared;
- **the archive details**, when a task is unarchived: `archived_at`,
  `archive_reason`, `archive_note`, `archived_by_id` and `duplicate_of_id`;
- **a task's labels**: removing a label from a task keeps the label's id and
  name; renaming a label a task carries keeps its old name;
- **authorship elsewhere**: when an account deletion clears
  `task_history.from_user_id` or `to_user_id`, or
  `task_attachments.uploaded_by_id`, the earlier user id is kept
  ([§6.7](#67-people-who-leave-or-delete-their-account)).

The revisions are not shown on the board. Org-admins see how many a hold has
kept, and get them in the export ([§8](#8-exporting-held-data)). Each revision
records the holds that were active when it was written. It is kept while any
of them is active, and the nightly job deletes it **30 days after the last of
them is released**, so the matter has a month to export after its hold ends
([§14](#14-decisions-needed), D4). A revision also goes with its task, which a
hold stops from being deleted. A comment's revisions stay until that 30-day
point even if the comment is deleted after the release.

### 6.6 Releasing a hold

An org-admin requests a release from the hold's page, with a short note on
why. Before confirming, the page shows what release will make deletable: "When
this hold is released on 17 November 2026, about 214 archived tasks that are
past the retention period will be deleted at the next nightly run."

**A release waits 7 days** ([§14](#14-decisions-needed), D10). Until then the
hold applies in full, and any org-admin can **Cancel release**. When the date
passes, the next nightly run releases the hold in one transaction: it sets
`released_at`, marks the request applied, records `legal_hold_released` and
queues the "took effect" email. Then it applies retention to what is no
longer held. Every org-admin is emailed when a release is requested, when it
is cancelled, and when it takes effect. The wait matches the one for a
shorter retention period, so neither is a quicker way to delete than the
other.

**Each request is a row of its own** in `legal_hold_release_requests`
([§9.2](#92-legal_holds)), never deleted, and its note never changes. Cancel
sets the row's `cancelled_at` and who cancelled it; it clears nothing. A hold
has at most one open request at a time, and a new request after a cancel is
a new row. So every note anyone gave stays on record, and each email names
the request it is about ([§14](#14-decisions-needed), D20).

The hold's page suggests exporting before the release takes effect: once its
revisions' 30 days have passed ([§6.5](#65-edits-keep-the-earlier-version)),
they are gone.

### 6.7 People who leave or delete their account

- **Leaving the Organization** unassigns the person's open tasks and releases
  their claims, as today ([§2](#2-what-exists-today)). Their tasks and comments
  stay where they are. On a held board, the cleared assignment is kept as a
  revision, and `task_history` records the unassignment.
- **Deleting an account** still works (D5), by every one of the three ways in
  ([§2](#2-what-exists-today)). The personal workspace is emptied as today:
  personal boards are never held. On held Organization boards their tasks,
  comments, history and files stay, and the database clears the nine author
  columns as it does today. Before each is cleared, the revision triggers keep
  the earlier user id ([§6.5](#65-edits-keep-the-earlier-version)).

  Each of the three ways writes one `legal_hold_custodian_removed` audit event
  for each Organization with an active hold that the person belonged to. The
  event stores the person's user id, name and email in the row itself, because
  the audit log clears `actor_user_id` with the account and can't look the
  email up afterwards. The audit log keeps that row for its own retention
  period, or for as long as an audit pause lasts, so the matter can still tell
  who wrote what.

  The event is written **inside the deleting transaction**, before the user
  row goes, which is unlike the other account-deletion events, written after
  the commit. It is the only record of who wrote the held content, so a crash
  between the commit and a later write must not lose it, and inside the
  transaction the person's memberships, name and email can still be read.

  An audit stream destination set not to receive personal data strips every
  `email` key ([audit log streaming design](AUDIT-LOG-STREAMING-DESIGN.md)),
  so its copy of this event carries the user id and name but not the email.
  The email stays in Stride's own audit log and its exports.

### 6.8 Audit events

An Organization-wide hold has a **Pause audit log retention** option, on by
default. While any active hold with it applies:

- `AuditLog.Retention.purge_organization_before/3`, which the nightly job
  calls, deletes nothing for that Organization, so its audit events are kept
  whatever `audit_retention_days` says;
- `AuditLog.purge_before/1`, the operator's manual purge, skips that
  Organization's events too.

The pause lives in those two functions rather than in the worker, so no
caller in the application can get round it. The database purge functions in
[audit-log-hardening.md](../audit-log-hardening.md) are for operators and know
nothing of holds. The runbook says not to use them while
`Kanban.Release.legal_hold_status/0` reports a pause ([§7.4](#74-what-enforcement-cannot-do)).

The security page shows "Audit log retention is paused by a legal hold". When
the last such hold is released, the next run purges what is past the period.

A workspace or board hold cannot pause audit retention, because audit events
belong to the Organization, not to a board ([§14](#14-decisions-needed), D6).

With [audit log streaming](AUDIT-LOG-STREAMING-DESIGN.md), a paused audit
purge also means no retention gaps for that Organization's destinations.

---

## 7. Enforcement

A hold is enforced twice: by the contexts, so people get a clear message, and
by the database, so nothing reaches a held row by another route.

### 7.1 In the application

`Kanban.LegalHolds.held_board?/1` answers whether any active hold covers a
board id. It is an internal check, so it takes no scope; the contexts call it
before deleting, and return `{:error, :legal_hold}`:

- `Lifecycle.delete_task/2`, which gains the acting user so the refusal event
  can name them. It deletes the task and, when it was a goal's last child, the
  goal, in **one transaction**, so a refusal leaves both;
- `Comments.delete_comment/2`;
- `Attachments.delete_attachment/2`;
- `Labels.delete_label/2`, when a task on the board carries the label;
- `Columns.delete_column/2`;
- `Boards.delete_board/2`.

Every LiveView that calls one of them handles `{:error, :legal_hold}` and shows
a translated flash. Today several match only the results they know, such as
the `case` at `board_live/index.ex:224`, which would raise a `CaseClauseError`.
The board, the task, the Archive page and the board list **disable** each
held item's **Delete** and show why beside it ([§10.4](#104-the-board-and-the-task));
the context check stays, because a stale page can still send the event.

**The refusal event.** When the context refuses, it writes
`legal_hold_deletion_refused` before returning. When the database refuses
(`KLH01`, [§7.2](#72-in-the-database)), the transaction that was running is
already aborted, and an event written in it would be rolled back with it.
`Kanban.LegalHolds.Enforcement` therefore writes the event after the
rollback: directly when there was no outer transaction, otherwise from a
supervised task on its own connection, which it waits for.

### 7.2 In the database

A function `board_legal_hold_active(board_id bigint) returns boolean` checks
`legal_holds` for an active hold on the board, its workspace or its
Organization. It returns `false` when the board, its workspace or its
Organization can't be found. That happens only inside a cascade whose top the
triggers already allowed, because a held top is always refused before its
children are reached (see **Cascades** below).

**Deletes.** `BEFORE DELETE` row triggers call it on:

| Table | How the trigger finds the board |
| --- | --- |
| `boards` | `OLD.id` |
| `columns` | `OLD.board_id`; it refuses only when the column holds a task, so an empty column on a held board can still be removed |
| `tasks` | `OLD.column_id` → `columns.board_id` |
| `task_comments` | `OLD.task_id` → `tasks` → `columns` |
| `task_attachments` | `OLD.task_id` → `tasks` → `columns` |
| `task_history` | `OLD.task_id` → `tasks` → `columns` |
| `labels` | `OLD.board_id`; it refuses only when a task carries the label |

A held row raises SQLSTATE `KLH01` ("legal hold"). `KLH01` doesn't clash with
any code in use; the only other custom one is the audit purge's `KAP01`
([§2](#2-what-exists-today)). Ecto's `Repo.delete` and
`Repo.delete_all` raise on it rather than returning an error, so
`Kanban.LegalHolds.Enforcement` follows `Kanban.Tasks.DbErrors`: it wraps each
delete, rescues the `Postgrex.Error` whose `pg_code` is `"KLH01"`, returns
`{:error, :legal_hold}`, and re-raises every other error.

**Moves.** `BEFORE UPDATE` row triggers refuse a change that would carry a
held row out of a hold's cover, checked against the **old** location:

| Table | Refused change |
| --- | --- |
| `workspaces` | `organization_id`, while a hold covers the workspace |
| `boards` | `workspace_id`, while the board is held |
| `columns` | `board_id`, while the board is held |
| `tasks` | `column_id` to a column on another board, while the old board is held. Moves between columns of one board are allowed |
| `task_comments`, `task_attachments`, `task_history`, `task_labels` | `task_id`, while the old task's board is held |

Without these, moving a row and then deleting it would get past every delete
trigger.

**`TRUNCATE`.** Statement-level `BEFORE TRUNCATE` triggers on every table
above, and on `task_labels`, `legal_holds`, `legal_hold_release_requests` and
`legal_hold_revisions`, refuse while any hold is active anywhere, as
`audit_events` already does for its own table. H3 adds them to the tables that
exist by then; H6 adds the one on `legal_hold_revisions` when it creates the
table.

**Cascades.** Postgres runs row triggers on cascaded deletes too. A direct
delete always reaches the trigger of the table it starts at while its parent
rows still exist, and that trigger refuses. So a cascade is always stopped at
its top, before any child row is touched, and the whole statement rolls back.
Children further down a cascade that was allowed may find their parents
already gone, which is why the function returns `false` then rather than
raising.

**Files.** Because the row delete is refused, the `task_attachments` delete
trigger never queues the file, so `BlobCleanupWorker` never removes a held
file.

**Cost.** Each guarded row runs one lookup. `legal_holds` is small, with a
partial index on `(scope_type, scope_id) WHERE released_at IS NULL`. The cost
falls on large allowed cascades: in the review, deleting an unheld board of
10,000 tasks ran 31,006 lookups and took about 2.7 times as long. That is
acceptable for an action that is rare and already slow, and the tests keep it
measured ([§13](#13-testing-strategy)). Retention's own query already leaves
held tasks out ([§5.2](#52-what-the-job-deletes)), so the trigger only
refuses for it if a hold is placed during a run.

**`legal_holds` itself.** A trigger refuses every `DELETE`. An `UPDATE` may
only:

- set `released_at` once, while the hold has an open release request whose
  `effective_at` has passed;
- set `placed_by_id` to `NULL`, which the foreign key does when that person's
  account is deleted;
- rewrite `reason`, so the encryption key can be rotated. The context offers
  no way to edit the reason.

Every other column is fixed once the hold is placed.

**`legal_hold_release_requests`.** A trigger refuses every `DELETE`, and an
`INSERT` for a hold that is released or already has an open request. An
`UPDATE` may only set `cancelled_at` and `cancelled_by_id` once, or
`applied_at` once after `effective_at`, on an open request, or set
`requested_by_id` or `cancelled_by_id` to `NULL` when that account is
deleted. The note, who asked, when and the effective date never change.

**`legal_hold_revisions`.** A trigger refuses every `UPDATE`, and a `DELETE`
of a revision while any hold it was kept for is active. The task cascade
can't reach a held revision, because the task's own trigger refuses first.

### 7.3 Keeping earlier versions

`AFTER UPDATE` row triggers on `tasks`, `task_comments`, `task_history`,
`task_attachments` and `labels`, and a `BEFORE DELETE` row trigger on
`task_labels`, write the earlier values into `legal_hold_revisions` when the
row is on a held board and a kept column changed
([§6.5](#65-edits-keep-the-earlier-version)). On `task_history` and
`task_attachments` only a user id being cleared counts.

A trigger is used rather than context code, because tasks are also updated by
`update_all` (bulk archive, positioning) and by foreign-key `nilify_all` on
account deletion, which no context sees. Postgres fires row triggers for both,
once per row, with the old user id still in `OLD`. Position-only, move-only
and claim-only updates write nothing.

**Who changed it.** `changed_by_id` comes from
`NULLIF(current_setting('kanban.current_user_id', true), '')::bigint`. The
`NULLIF` matters: on a pooled connection where any transaction has used
`SET LOCAL kanban.current_user_id`, the setting reads back as `''` afterwards,
and a bare `::bigint` cast would raise and abort the edit. The contexts that
know the acting user call `set_config('kanban.current_user_id', …, true)` at
the start of their transaction. An update outside such a transaction, such as
a cascade from an account deletion or a bulk update, records `NULL`, so the
column is "who, when known".

### 7.4 What enforcement cannot do

- **The app role owns these tables.** In production (Fly Managed Postgres) it
  could drop or disable the triggers (`DROP TRIGGER`,
  `ALTER TABLE … DISABLE TRIGGER`) or replace `board_legal_hold_active`. They
  guard against bugs, mistakes and every code path, not against someone who
  controls the application or the database. The audit log of every hold,
  release and refused deletion is the evidence that the controls were in
  place.
- **`Kanban.Release.legal_hold_status/0`**, like `audit_log_status/0`, reports
  whether every trigger is present and enabled (`pg_trigger.tgenabled`),
  whether `board_legal_hold_active` matches the expected body, and which
  Organizations have an audit pause. The operator runbook runs it after every
  deploy.
- **A delete already running when a hold is placed** may still commit: each
  statement checks the holds that were committed when it started. A hold
  covers deletes that start after it is saved, and its page says so.
- **A self-hosting operator** can always change the database, and the database
  audit purge functions ignore holds ([§6.8](#68-audit-events)). The operator
  docs say what a hold means and that it depends on the operator.

---

## 8. Exporting held data

A hold's page has **Export held data**. It starts the existing workspace
export ([§2](#2-what-exists-today)) for each workspace the hold covers,
limited to the boards the hold covers, so a board hold exports that board and
not its whole workspace. The export format gains two files, as JSON arrays
like the rest of the archive:

- `legal_hold_revisions.json`: the revisions kept for the exported boards;
- `legal_hold.json`: **this** hold only, with its matter name, scope, when it
  was placed and by whom, its release requests with their notes, and when it
  was released. Other holds, and other matters' names, are not included.
  Neither is the reason, which can be privileged; it is shown on the hold's
  page and can be copied from there.

**Where the hold and the filter live.** `workspace_exports` gains
`legal_hold_id`, `board_ids` and `signed_key_id` ([§9.5](#95-workspace_exports)).
The Worker reads the board filter from the row, not from its job args, and the
Writer exports only those boards. An ordinary export leaves all three empty
and works as today. The hold's page lists the exports whose `legal_hold_id`
is this hold.

**One export at a time, per hold.** The unique index that allows one pending
or running export per workspace becomes one per workspace and hold, so an
ordinary export and each hold's exports don't block each other
([§14](#14-decisions-needed), D19). Starting a hold's export is all-or-nothing:
one transaction inserts a row for every covered workspace, and if this hold
already has an export pending or running for any of them, the whole request is
refused with a message naming that workspace. Each request records one
`legal_hold_export_requested` audit event, listing every workspace and board.

**The importer.** The format version is raised. The importer reads the two new
JSON files and ignores them, and accepts `manifest.json.sig` and `README.txt`
in the archive without verifying them ([§14](#14-decisions-needed), D18). It
already checks each attachment file's size and SHA-256 against
`attachments.json`. Verifying the signature is a step for whoever receives
the archive, as with the signed audit export, so an archive from another
instance, or signed with a key since removed, still imports. The importer
change is part of H10.

The audit events that belong to the matter are exported separately, from the
Organization audit log, as today.

**The export is signed** with the signed audit export's key and Ed25519
signature (`Kanban.AuditLog.Signing`,
[signed audit exports](../audit-log-signed-exports.md)), so whoever receives
it can check that nobody changed it after Stride built it
([§14](#14-decisions-needed), D8). The archive already has a `manifest.json`
([§2](#2-what-exists-today)). Signing **extends** that manifest, and adds two
files:

- `manifest.json` keeps every field the importer needs (format, format version,
  `exported_at`, app version, workspace, counts, files, skipped attachments)
  and gains:
  - `schema`: `stride.legal-hold-export.v1`, so a verifier can tell it from a
    signed audit export, which the same key signs;
  - `instance`: the signing instance, as the audit manifest has;
  - `legal_hold_id`, `board_ids`, and who asked and when;
  - `key_id`;
  - every other file in the archive with its size and SHA-256, the attachment
    files included, except `manifest.json.sig` and `README.txt`.
- `manifest.json.sig`: the Ed25519 signature over the exact bytes of
  `manifest.json`, made by `Kanban.AuditLog.Signing.sign/1`.
- `README.txt`, which is not signed: what the export is, and how to verify
  it, the signature first and then each listed file's SHA-256. A new
  `Kanban.LegalHolds.ExportReadme` writes it, because the audit export's README
  describes a single CSV or JSON file. The address of the published public keys
  comes from the endpoint's configured URL, because the Worker has no request.

**What the signature proves.** `exported_at` is the moment the Writer's
snapshot started, inside its `REPEATABLE READ` transaction. Everything in the
JSON files is as of that moment, which is later than the request, by however
long the job waited in the queue. Attachment files are copied after the
snapshot. A file deleted or changed by then is left out and listed in
`skipped_attachments`, as today. The manifest says so in those words, as the
audit export's `snapshot_at` does.

**When it can't be signed.** The Worker signs while it builds, and records the
signing key's id on the row, or `NULL` when it built the archive unsigned. The
hold's page reads that, not the current config, so what it says about an
export stays true for its 7 days:

- with no signing key (`signed_export_available?/0` is false), the archive is
  built without `manifest.json.sig` and `README.txt`, its manifest still lists
  every file's hash, and the page says the export is unsigned;
- if the key changes while an archive is being built, the build fails (the
  Worker makes one attempt), and the page says to request it again;
- an archive signed with a key that is later rotated stays verifiable only
  while the old public key is published as a previous key, and one signed with
  a key that is later revoked fails verification. The operator docs for signed
  audit exports say how to keep previous keys published, and the held-data
  docs point there ([§12.4](#124-docs)).

The manifest names no matter and carries no reason.

Exports expire after 7 days, as today: an export is a copy, and the held data
itself stays in Stride. [workspace-export.md](../workspace-export.md) gains the
two files, the board filter, the signed manifest and how to verify it
([§12.4](#124-docs)).

---

## 9. Data model

### 9.1 Security policy

`organization_security_policies` gains:

| Column | Type | Notes |
| --- | --- | --- |
| `archived_task_retention` | string, not null, default `site` | `site`, `forever` or `days` |
| `archived_task_retention_days` | integer, nullable | Set only when `days`. Check constraint: 30 to 3650, and set exactly when the choice is `days` |
| `pending_archived_task_retention` | string, nullable | A shorter choice waiting to apply ([§5.3](#53-changing-the-period)) |
| `pending_archived_task_retention_days` | integer, nullable | Same constraint as above, against the pending choice |
| `archived_task_retention_effective_at` | utc_datetime, nullable | When the pending choice applies |
| `archived_task_retention_requested_by_id` | FK users, `nilify_all` | Who asked for the pending change |

A check constraint makes the pending columns all set or all empty, apart from
`archived_task_retention_requested_by_id`, which an account deletion can clear.
`SecurityPolicy` gains an `archived_task_retention_days_range/0` helper next to
the audit one, and a changeset of its own for the setting. None of these
columns is in `editable_fields/0` ([§5.3](#53-changing-the-period)).

`boards` gains `organization_joined_at` (utc_datetime, nullable), set by
`BoardMoves` when a board moves into an Organization
([§5.2](#52-what-the-job-deletes)).

### 9.2 `legal_holds`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial | |
| `organization_id` | FK organizations, `on_delete: :restrict` | An Organization with holds can't be deleted |
| `matter_name` | string, ≤ 120 | |
| `reason` | `EncryptedBinary` | ≤ 2,000 characters |
| `scope_type` | string | `organization`, `workspace`, `board` |
| `scope_id` | bigint | The Organization's, workspace's or board's id; checked against the Organization when placed |
| `pauses_audit_retention` | boolean | Only `true` for an Organization scope (check constraint) |
| `placed_by_id` | FK users, `nilify_all` | |
| `placed_at` | utc_datetime | |
| `released_at` | utc_datetime, nullable | Set once by the nightly job; never cleared |

What an `UPDATE` may change is in [§7.2](#72-in-the-database). Partial index on
`(scope_type, scope_id) WHERE released_at IS NULL`, and an index on
`organization_id`.

**`legal_hold_release_requests`**, one row per release request, never deleted
([§6.6](#66-releasing-a-hold)):

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial | |
| `legal_hold_id` | FK legal_holds, `on_delete: :restrict` | |
| `requested_by_id` | FK users, `nilify_all` | |
| `requested_at` | utc_datetime | |
| `note` | string, ≤ 500 | Why the release was requested; never changed |
| `effective_at` | utc_datetime | `requested_at` plus 7 days |
| `cancelled_at`, `cancelled_by_id` (FK users, `nilify_all`) | | Set once by a cancel |
| `applied_at` | utc_datetime, nullable | Set once by the nightly job, with the hold's `released_at` |

A partial unique index on `legal_hold_id WHERE cancelled_at IS NULL AND
applied_at IS NULL` allows one open request per hold, and an index on
`effective_at` of the same rows finds those due. What an `UPDATE` may change is
in [§7.2](#72-in-the-database).

### 9.3 `legal_hold_revisions`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial | |
| `board_id` | bigint | Copied so counts and the export need no join through tasks and columns. Not a foreign key: a held board can't be deleted, and the revision purge removes the rows later |
| `entity_type` | string | `task`, `comment`, `history`, `attachment`, `label`, `task_label` |
| `entity_id` | bigint | |
| `task_id` | FK tasks, `on_delete: :delete_all`, nullable | The task, or the comment's, history row's, attachment's or label link's task. `NULL` for a label rename |
| `hold_ids` | bigint[] | The active holds covering the board when the revision was written |
| `before` | jsonb | The changed kept columns' earlier values only |
| `changed_by_id` | bigint, nullable | Who, when known ([§7.3](#73-keeping-earlier-versions)) |
| `inserted_at` | utc_datetime_usec | |

Indexes `[board_id, inserted_at]` and `[task_id]`, and a GIN index on
`hold_ids` for the purge ([§6.5](#65-edits-keep-the-earlier-version)).

### 9.4 Modules

| Module | Purpose |
| --- | --- |
| `Kanban.LegalHolds` | The context: place, request and cancel a release, list, counts, and `held_board?/1`. Every public function takes the scope first and checks org-admin; `held_board?/1` is the internal check the other contexts call, so it takes a board id only |
| `Kanban.LegalHolds.LegalHold`, `ReleaseRequest`, `Revision` | Schemas and changesets |
| `Kanban.LegalHolds.Enforcement` | Mapping SQLSTATE `KLH01` to `{:error, :legal_hold}`, following `Kanban.Tasks.DbErrors`, and writing the refusal audit event after the rollback |
| `Kanban.LegalHolds.ExportReadme` | The held-data export's `README.txt` ([§8](#8-exporting-held-data)) |
| `Kanban.Notifications.LegalHoldAlerts`, `LegalHoldEmailWorker` | The security emails to every enabled org-admin, queued in the change's transaction, modelled on `AuditStreamAlerts` ([§12.3](#123-emails)) |
| `Kanban.Attachments.Usage` | Gains `held_bytes/1`: the bytes of the Organization's files on boards an active hold covers ([§10.4](#104-the-board-and-the-task)) |
| `Kanban.Workspaces.Export` and its `Worker` and `Writer` | Gain the hold, the board filter and signing; the importer's archive check gains the two JSON files, `manifest.json.sig` and `README.txt` ([§8](#8-exporting-held-data)) |
| `Kanban.Organizations.SecurityPolicies` | Gains `set_archived_task_retention/2` and `cancel_archived_task_retention_change/1` |
| `Kanban.Archives.Retention` | Gains the board scope and the hold filter |
| `Kanban.Retention.PurgeWorker` | Applies due releases and retention changes, per-Organization archived-task cutoffs with the join grace, and the revision purge |
| `Kanban.Release` | Gains `legal_hold_status/0` |

### 9.5 `workspace_exports`

`workspace_exports` gains three nullable columns, all empty for an ordinary
export ([§8](#8-exporting-held-data)):

| Column | Type | Notes |
| --- | --- | --- |
| `legal_hold_id` | FK legal_holds, `on_delete: :restrict` | The hold the export was made for |
| `board_ids` | bigint[] | The boards to export; empty means every board in the workspace |
| `signed_key_id` | string | The signing key's id, or `NULL` when the archive was built unsigned |

`workspace_exports_one_active_index` becomes unique on `(workspace_id,
COALESCE(legal_hold_id, 0))` for pending and running rows
([§14](#14-decisions-needed), D19).

---

## 10. Screens

All text is translated into every language Stride supports (de, en, es, fr,
ja, pt, zh), and every screen works in light and dark mode, using the tokens
in the [dark mode contract](../dark-mode-contract.md).

### 10.1 Security: Keep archived tasks

On `/org/security`, under **Audit log retention**, a new card **Archived task
retention**, with **its own form and Save**, separate from the policy form
above it:

- **Keep archived tasks**: **Follow the site setting** (showing what that is
  now), **Forever**, or a number of days;
- a line saying deleted tasks can't be recovered and their files go with them;
- when a shorter period is waiting, a notice with who asked, its date and
  **Cancel change**;
- when holds keep tasks past the period, "214 archived tasks are past this
  period and kept by legal holds." (added by H7);
- when an Organization-wide hold pauses audit retention, "Audit log retention
  is paused by a legal hold" on the **Audit log retention** card (added by H7).

Saving a shorter period asks for confirmation, with the estimated count it
will delete and the date.

### 10.2 Legal holds

A new page, **Legal holds**, at `/org/legal-holds` (`KanbanWeb.OrgLive.LegalHolds`),
in the existing `live_session :require_authenticated_user` block, reached from
the Organization console's header buttons.

- **The list:** active holds first, with any pending release and its date,
  then released ones, each with its matter name, scope, who placed it and
  when, and counts of boards, tasks and kept revisions.
- **Place a hold:** matter name, reason, scope (Organization, a workspace, a
  board, chosen from the Organization's own), and **Pause audit log
  retention** for an Organization scope. Confirming says what the hold
  will stop.
- **A hold's page:** its details, its reason, what it covers, its revision
  count, every release request with its note and whether it was cancelled,
  **Export held data** with the hold's exports (each marked signed or
  unsigned, from its own row), and **Release** or, while a release is
  pending, **Cancel release**. Release asks for a note and shows its date and
  what will become deletable ([§6.6](#66-releasing-a-hold), [§8](#8-exporting-held-data)).

### 10.3 The Archive page

The header line from [§5.4](#54-what-people-see), with the pending-change
line when there is one, and in each row one of **Deleted after** *date*,
**Kept while a task in this goal is open**, **Kept while another task
depends on it**, **Kept forever**, or **On hold**. R5 builds every state but
**On hold**, which H5 adds once holds exist; until then no board is held. On
a held board, the row menu's **Delete forever** is disabled, with a lock icon
and "Deleting is turned off on this board by your Organization." **Archive old
(30d+)**, which archives rather than deletes, still works.

### 10.4 The board and the task

On a held board, a task's **Delete**, a comment's **Delete**, an attachment's
**Delete**, a label's **Delete** when a task carries it, and a column's
**Delete** when it holds a task are disabled with the same sentence, and so is
the board's **Delete** on the board list (`BoardLive.Index`). Members are not
told the matter's name ([§14](#14-decisions-needed), D3). There is no **Move**
to disable: a board in an Organization has none.

**Deleting a column.** The column-deletion defect ([§15](#15-goals-tasks-and-order))
replaces the column's fixed `data-confirm` with a step on the server. Clicking
**Delete** asks the server, which counts the column's open and archived tasks
at that moment and opens a confirmation modal: "Delete this column? It holds
12 open tasks and 30 archived tasks, which will be deleted with it." An empty
column asks no counts. Confirming deletes. On a held board, H5 uses the same
step to refuse a column that holds a task, with the sentence above
([§14](#14-decisions-needed), D16).

**When storage is full.** Held files can't be deleted, so they can fill the
Organization's attachment storage. When an upload, a board move into the
Organization or a workspace import is refused with `:quota_exceeded`, and
files on held boards take up part of the storage
(`Kanban.Attachments.Usage.held_bytes/1`), the message adds how much of it is
held. It says that held files can't be deleted until their hold is released,
and that an org-admin can ask Stride for more storage. It names no matter and
no board ([§14](#14-decisions-needed), D17).

---

## 11. Security

### 11.1 Abuse by an org-admin

An org-admin can already delete a board. Retention and holds add powers that
could destroy evidence, and the design limits each:

- **Deleting history by shortening retention.** The 7-day wait, the email to
  every org-admin with the estimated count, and an audit event for every
  request, replacement, cancel and application ([§5.3](#53-changing-the-period)).
- **Moving boards in under a short period.** The 7-day join grace
  ([§5.2](#52-what-the-job-deletes)), and the period stated in the move's
  confirmation.
- **Releasing a hold to destroy evidence.** The release waits 7 days, can be
  cancelled by any org-admin, and is emailed and audited at every step. Its
  page shows what will become deletable. An org-admin who releases a hold and
  deletes data has left a record of both, a week apart.
- **Removing the other org-admins first.** An org-admin can remove,
  disable or SCIM-deprovision every other org-admin, so the release emails
  reach no one else. This is not prevented. The removals and the release are
  all audit events a week apart, which an [audit log stream](AUDIT-LOG-STREAMING-DESIGN.md)
  sends out of Stride, and the docs recommend streaming for Organizations that
  rely on holds.

### 11.2 What holds reveal

- **To members**, a held board shows only that deleting is turned off by the
  Organization, never the matter name or reason.
- **To agents**, the API gives no hold or retention information. A refused
  deletion can't happen through the API today (there is no delete endpoint),
  and if one is added it returns `423 Locked` with `{"error": "legal_hold"}`
  and no detail.
- **The reason** is encrypted at rest (`Kanban.Encryption`), never logged, put
  in telemetry, put in audit metadata or exported ([§8](#8-exporting-held-data)).
- **Audit metadata** names a hold by its id and scope only. The matter name
  appears only on the holds page, in the export's `legal_hold.json`, and in
  the emails to org-admins. Site admins see the ids and scopes in the site
  audit log ([§4](#4-access-and-the-plan-gate)), not the matter.

### 11.3 Data protection

A legal hold can keep personal data longer than the privacy policy's usual
periods. `/privacy` gains a sentence: an Organization may keep its data,
including its audit events and a record of who wrote what, for as long as a
legal matter requires. Account deletion still removes the account
([§6.7](#67-people-who-leave-or-delete-their-account)).

---

## 12. Telemetry, audit events, notifications and docs

### 12.1 Telemetry

Declared in `Kanban.Telemetry.Catalog`, emitted with `Kanban.Telemetry.emit/3`,
tested with `Kanban.TelemetryHelpers.attach_telemetry/2`. Each task that adds
an event also refreshes the event reference in `docs/telemetry.md`.

| Event | Measurements | Metadata | Metric |
| --- | --- | --- | --- |
| `[:kanban, :legal_hold, :placed]` | `count` | `scope_type` | counter, persisted |
| `[:kanban, :legal_hold, :released]` | `count`, `duration_days` | `scope_type` | counter, persisted |
| `[:kanban, :legal_hold, :deletion_refused]` | `count` | `entity_type` | counter tagged by `entity_type` |
| `[:kanban, :retention, :archived_tasks_purged]` | `count`, `tasks`, `held` | — | sum of `tasks` and of `held` |

R6 adds `archived_tasks_purged` with `count` and `tasks`; H7 adds its `held`
measurement once holds exist.

`entity_type` is not an allowed metric tag today. H4 adds it to the tag rule
in `docs/telemetry.md` and to `@tag_keys` in `test/kanban/telemetry_test.exs`;
it takes six fixed values, so it adds no cardinality risk.

These four events carry no Organization id, matter name or reason. The audit
actions in [§12.2](#122-audit-actions) also emit telemetry, as every audit
action does, and that carries `organization_id`.

### 12.2 Audit actions

Added to `@audit_actions` in `Kanban.Telemetry.Catalog.Families`, with labels
in `KanbanWeb.AuditLogActions` and descriptions in `docs/telemetry.md`,
translated into every locale.

**Every key passed to `AuditLog.event/2` is declared**, because the telemetry
call-site test fails on any undeclared key. A key that must be stored in the
row but kept out of telemetry is added to `@telemetry_omitted_keys` in
`Kanban.AuditLog` (`lib/kanban/audit_log.ex`) and to `@audit_omitted_keys` in
`test/kanban/telemetry_test.exs`, as `:email`, `:ip` and `:filters` are. A
declared key the metadata allow-list in `docs/telemetry.md` refuses goes there
too.

| Action | Keys | Kept out of telemetry |
| --- | --- | --- |
| `legal_hold_placed` | `user_id`, `organization_id`, `hold_id`, `scope_type`, `scope_id`, `pauses_audit_retention` | — |
| `legal_hold_release_requested` | `user_id`, `organization_id`, `hold_id`, `release_request_id`, `scope_type`, `scope_id`, `effective_at` | — |
| `legal_hold_release_cancelled` | `user_id`, `organization_id`, `hold_id`, `release_request_id` | — |
| `legal_hold_released` | `organization_id`, `hold_id`, `release_request_id`, `scope_type`, `scope_id` | — |
| `legal_hold_deletion_refused` | `user_id`, `organization_id`, `entity_type`, `entity_id`, `board_id`, `hold_ids` | — |
| `legal_hold_custodian_removed` | `organization_id`, `removed_user_id`, `removed_user_name`, `email` | `removed_user_name`, `email` |
| `legal_hold_export_requested` | `user_id`, `organization_id`, `hold_id`, `workspace_ids`, `board_ids` | — |
| `archived_task_retention_changed` | `user_id`, `organization_id`, `from_period`, `to_period` | — |
| `archived_task_retention_change_scheduled` | `user_id`, `organization_id`, `from_period`, `to_period`, `effective_at`, `estimated_count` | — |
| `archived_task_retention_change_cancelled` | `user_id`, `organization_id`, `to_period` | — |
| `archived_task_retention_change_applied` | `organization_id`, `from_period`, `to_period` | — |

A period is written as `"site"`, `"forever"` or the number of days.
`legal_hold_export_requested` is recorded once per request, however many
workspaces it covers. `retention_purge` gains the `archived_task_counts` key
([§5.2](#52-what-the-job-deletes)).
`organization_policy_updated` is unchanged: the retention setting is not one
of its fields.

### 12.3 Emails

Sent to every enabled org-admin, the one who acted included, the way the
audit stream's security emails are sent (`Kanban.Notifications.AuditStreamAlerts`,
[§2](#2-what-exists-today); [§14](#14-decisions-needed), D15).
`Kanban.Notifications.LegalHoldAlerts` queues one
`Kanban.Notifications.LegalHoldEmailWorker` job per org-admin, on the
`:notifications` queue, **inside the transaction that makes the change**, so a
change that rolls back emails nobody. Each email is in the recipient's
locale, with `Gettext.with_locale/3`. These are security emails: no
notification preference or plan gates them, and nobody can turn them off.

The job args are ids, periods, dates and counts. They never hold the matter
name, the reason or the release note. When it sends, the worker reads the
matter name from the hold, and the note, who asked and the date from the
release request the job names. Both rows are never deleted, and none of
those columns ever changes ([§7.2](#72-in-the-database)). So the email is
right however late the job runs (a failed delivery is retried within about a
minute, and a job stranded by a crash is picked up again after an hour), and
none of them is stored in `oban_jobs`. A deleted requester is shown as a
deleted account.

At send time the worker also skips a recipient who is no longer an enabled
org-admin of the Organization, as `AuditStreamEmailWorker` does.

**The nightly steps.** The job today runs each step without a transaction
([§2](#2-what-exists-today)). Each release it applies, and each retention
change, runs in **its own transaction**, which holds the update, the audit
event and the email jobs. If any of them fails, the whole change rolls back,
nothing is emailed, the step is listed in `failed_steps`, and the next night
tries again.

The emails are:

- a hold was placed (by whom, the matter name and the scope);
- a release was requested (by whom, the note, and the date), or cancelled
  (by whom), each naming the request;
- a release took effect, sent by the nightly job;
- a shorter archived-task period was scheduled (when it applies and about
  what it will delete), replaced, or cancelled;
- a shorter period took effect (the period now in force and about how many
  archived tasks that night's run deletes), sent by the nightly job
  ([§14](#14-decisions-needed), D21).

### 12.4 Docs

- **New:** `docs/retention-and-legal-hold.md`, for org-admins and operators:
  - setting the period, the wait and the join grace;
  - what a hold blocks and what it keeps;
  - releasing a hold, and exporting before it takes effect;
  - exporting held data: what the archive holds, what `exported_at` proves,
    and the unsigned case;
  - what enforcement cannot do ([§7.4](#74-what-enforcement-cannot-do)), the
    runbook check with `legal_hold_status/0`, and the advice to stream the
    audit log.

  It is added to `docs/README.md`.
- `docs/organization-security-policies.md`: archived task retention, next to
  *Audit retention*, and the audit pause.
- `docs/organizations.md`: a short section with links.
- `docs/workspace-export.md`: the board filter, the two new files, the
  signed manifest and `README.txt`, and how to verify a signed archive (the
  signature, then each file's SHA-256), pointing to
  [audit-log-signed-exports.md](../audit-log-signed-exports.md) for the
  public keys, keeping previous keys after a rotation, and the OpenSSL
  version needed.
- `docs/attachments.md`: held files count toward the storage and can't be
  deleted, and the storage-full message.
- `docs/telemetry.md`: the new events, actions and the `entity_type` tag.
- The comment on `archived_task_retention_days` in `config/config.exs`
  ([§5.5](#55-boards-outside-an-organization)).
- The `/privacy` page: the sentence in [§11.3](#113-data-protection), translated.
- An in-app Resources guide, *Keeping and holding your Organization's data*.
- `CHANGELOG.md`, `priv/changelog/body.html`, `ROADMAP.md` (move the item to
  Complete), and the pricing page's Organization features, translated.

---

## 13. Testing strategy

| Area | Tests |
| --- | --- |
| Retention setting | The three choices; the range 30 to 3650 in the changeset and the check constraints, for the period in force and the pending one; a half-set pending change refused by the database; the shared policy form can't change it; a longer choice applies at once; a shorter one waits 7 days, emails and can be cancelled; a new choice replaces a pending one by the rules in [§5.3](#53-changing-the-period); each step's audit action; the apply step, its audit event and its email commit or roll back together |
| Retention job | Per-Organization cutoffs; **Follow the site setting** matches today, set and unset; **Forever** deletes nothing with the site setting set; an Organization with no policy row follows the site setting; a board that joined less than 7 days ago uses the longer period; boards outside an Organization keep the site setting; a pending change is applied before the step on its date; the existing goal and dependency rules still hold; held tasks are never selected; files are queued for deleted tasks only; the `retention_purge` counts: `archived_task_counts` per Organization and `archived_task_count` as the total, with the existing `organization_counts`, `failed_steps` and `audit_stream_skipped` unchanged; the audit step's stream leases and gaps behave as today |
| Archive page dates | **Deleted after** for a plain task, the kept goal and depended-on task states, **Kept forever**, a pending change, and each locale's date format with the year (R5); **On hold** on a held board, with no date (H5) |
| Archive and move prompts | The period sentence in each of the three archive actions; the period and its start date in the board move's confirmation, and the move's existing quota refusal still shown |
| Column deletion | The defect's confirmation step counts the open and archived tasks at the moment it opens, an empty column asks no counts, and only the owner reaches it; on a held board the same step refuses a column that holds a task (H5) |
| Holds | Place, overlap, request and cancel a release, the release on its date; the 100 limit; scope checked against the Organization; matter, scope and pause can't change; a released hold can't be changed or deleted; the guard allows the foreign key to clear `placed_by_id`, and allows `reason` to be rewritten; the matter name and reason length limits, and the reason stored encrypted; a personal board moved into a held workspace becomes held; org-admin only, with the two-factor requirement, and another Organization's org-admin gets nothing |
| Release requests | Each request is a new row; a second open request is refused; a cancel sets `cancelled_at` and clears nothing; a request after a cancel is a new row; the note, requester and dates can't change; deleting a row, or truncating the table, fails; the foreign keys can clear `requested_by_id` and `cancelled_by_id`; the nightly release sets `released_at`, `applied_at`, the audit event and the email in one transaction, and a failure leaves the hold active for the next night |
| Application refusals | Each of the six context functions returns `{:error, :legal_hold}` on a held board, and works on an unheld one, with the audit event; a goal's last child and the goal are both kept on refusal; every LiveView caller shows the flash rather than crashing |
| Database refusals | Without the context checks, a direct `Repo.delete`, `Repo.delete_all`, a column delete, a board delete and a label delete each return `{:error, :legal_hold}` through `Enforcement` and change nothing, attachments' files included; a refusal inside an outer transaction still records its audit event; every parent change in [§7.2](#72-in-the-database) is refused on a held row and allowed on an unheld one; `TRUNCATE` of each guarded table is refused while a hold is active; deleting from `legal_holds` or a held revision fails; an allowed cascade whose parents are gone finishes; a hold placed during a retention run stops the run's later deletes |
| Revisions | Editing each kind of kept field writes one revision with the earlier values only; position, move, claim and assignment updates write none, except clearing an assignment; unarchive keeps the archive details; account deletion keeps all nine cleared author columns; removing and renaming a label keeps the label; `changed_by_id` is set when the context knows the actor and `NULL` otherwise, including on a pooled connection after a `SET LOCAL`; nothing is written on an unheld board; revisions are deleted 30 days after their last hold is released and not before |
| Accounts | Deleting an account that wrote on a held board succeeds by each of the three ways in, keeps its content, and writes `legal_hold_custodian_removed` with the name and email inside the deleting transaction, so a deletion that rolls back writes none; an org-admin who placed, requested or cancelled a release of a hold can delete their account |
| Audit pause | An Organization-wide hold with the pause stops `purge_organization_before/3` and `purge_before/1` deleting that Organization's events; releasing it resumes them; a board hold cannot pause; `legal_hold_status/0` reports it |
| Release status | `legal_hold_status/0` reports every trigger present and enabled, and flags a missing trigger, a disabled one (`ALTER TABLE … DISABLE TRIGGER`) and a changed `board_legal_hold_active` body, as the `audit_log_status/0` tests do |
| Export | A board hold exports only that board, with the filter read from the export row; the new files are JSON arrays with the right rows, only this hold, its release requests, and no reason; an ordinary export is unchanged; a hold's export and an ordinary export of one workspace run side by side; a second request for the same hold while one is running is refused for every workspace, and starts none; one `legal_hold_export_requested` event per request; the importer accepts the new version, with and without `manifest.json.sig` and `README.txt`, and an old version; the extended manifest keeps every field the importer needs, has the `stride.legal-hold-export.v1` schema and the instance, and lists every other file, attachments included, with its right size and SHA-256; it verifies against the public key; a changed file or manifest fails verification; a row written after the snapshot started is not in the archive; with no signing key the export is unsigned, `signed_key_id` is `NULL` and the page says so even after a key is added; a key change during the build fails it |
| Emails | Each email in [§12.3](#123-emails) is queued for every enabled org-admin in the change's transaction, and none when the change rolls back; a requested email shows its own request's note after a cancel and after a new request; a recipient who stopped being an org-admin is skipped; a deleted requester shows as a deleted account; each recipient's locale; no matter name, reason or note in the job args; held storage message for an upload, a board move and an import (`held_bytes/1` across Organization, workspace and board holds, comment attachments, and a released hold) |
| Cost | The 10,000-task board delete stays within about three times its time without the triggers |
| UI | The pages in every supported locale, including plurals; disabled actions and their sentence on held boards; the storage-full message with and without held files, naming no matter or board; light and dark mode |
| Telemetry | Catalog entries, call sites, omitted keys and no forbidden keys, by the existing telemetry tests |

The trigger tests run in the normal sandbox: the triggers act inside the
test's own transaction. The pooled-connection `SET LOCAL` test needs two
transactions on one connection, which the sandbox gives.

---

## 14. Decisions needed

| # | Question | Decision |
| --- | --- | --- |
| D1 | Who can place and release holds? | **Settled on 2026-11-10: Org-admins only**, with the two-factor requirement. Custom roles are a separate roadmap item; a "legal" role can be added then |
| D2 | What can a hold cover? | **Settled on 2026-11-10: The Organization, a workspace or a board.** Holds on a person (everything they wrote, wherever it is) are left for later; account deletion keeps a record of who wrote what ([§6.7](#67-people-who-leave-or-delete-their-account)) |
| D3 | What do members see on a held board? | **Settled on 2026-11-10: That deleting is turned off by the Organization**, with no matter name or reason. Hiding the hold completely would leave members puzzled by refusals; naming the matter could reveal a confidential legal matter |
| D4 | Should edits on a held board keep the earlier version? | **Settled on 2026-11-10: Yes, for task content, comments, unarchive details, labels and authorship**, by database triggers. The review added: kept until 30 days after the last hold they were kept for is released. The alternatives are freezing edits, which stops work, or keeping nothing, which lets held text be overwritten |
| D5 | Can someone delete their account while their writing is held? | **Settled on 2026-11-10: Yes.** The account goes, their content stays, and the revisions and the `legal_hold_custodian_removed` event keep who wrote it. Refusing would block a person's own deletion right because of their employer's matter |
| D6 | Can a hold pause audit log retention? | **Settled on 2026-11-10: Yes, an Organization-wide hold, on by default.** Board and workspace holds can't, because audit events belong to the Organization |
| D7 | How is the retention period protected against mistakes and abuse? | **Settled on 2026-11-10: A 30-day minimum, and a 7-day wait before a shorter period applies**, with an email to every org-admin |
| D8 | How is held data exported? | **Settled on 2026-11-10: The existing workspace export, with the revisions and the hold added.** A separate legal export format is not needed for v1. **Revised on 2026-11-18:** signed audit exports have shipped, so the held-data export is signed in v1, the same way ([§8](#8-exporting-held-data)) |
| D9 | Should holds and the per-Organization period reach boards outside an Organization? | **Settled on 2026-11-10: No.** They keep the site setting and can't be held |
| D10 | Does releasing a hold take effect at once? | **Settled on 2026-11-10: No. A release waits 7 days and can be cancelled**, with emails at each step, matching the wait for a shorter retention period ([§6.6](#66-releasing-a-hold)) |
| D11 | Does a board moving into an Organization take its period at once? | **Settled on 2026-11-10: No. For 7 days it uses whichever of the site setting and the Organization's period keeps tasks longer** ([§5.2](#52-what-the-job-deletes)) |
| D12 | How is the retention setting saved? | **Settled on 2026-11-10: Its own function, card, Save and audit actions**, outside `editable_fields/0`, so the shared policy form can't change it or skip the wait ([§5.3](#53-changing-the-period)) |
| D13 | What does an Organization that hasn't chosen a period get? | **Settled on 2026-11-10: The site setting, as today.** **Forever** is a separate, explicit choice ([§5.1](#51-the-setting)) |
| D14 | Does the API show when an archived task will be deleted? | **Settled on 2026-11-10: No.** Agents can't archive, the task JSON has no archive fields, and a missing date would reveal a hold ([§5.4](#54-what-people-see)) |
| D15 | How are the emails to org-admins sent? | **Settled on 2026-11-18: The way the audit stream's security emails are**, through `Kanban.Notifications.LegalHoldAlerts`, queued in the change's transaction, with no preference or plan gate ([§12.3](#123-emails)). The new `AdminNotifier` the earlier draft proposed is dropped |
| D16 | What does the column-deletion defect change? | **Settled on 2026-11-18: The confirmation names how many open and how many archived tasks the delete removes.** Deleting a column that holds tasks stays allowed on an unheld board ([§15](#15-goals-tasks-and-order)). **Revised the same day:** the fixed `data-confirm` is replaced by a confirmation step on the server, which counts at the moment it opens; H5 reuses the step for held columns ([§10.4](#104-the-board-and-the-task)) |
| D17 | What happens when held files fill the attachment storage? | **Settled on 2026-11-18: The storage-full message says how much of the storage is held**, naming no matter or board, in H5 ([§10.4](#104-the-board-and-the-task)) |
| D18 | What does the importer do with a signed held-data archive? | **Settled on 2026-11-18: It accepts `manifest.json.sig` and `README.txt` and doesn't verify them.** It already checks each file's size and hash. Verifying is for whoever receives the archive, so an archive from another instance, or signed with a key since removed, still imports ([§8](#8-exporting-held-data)) |
| D19 | What happens when a hold's export meets a running export of the same workspace? | **Settled on 2026-11-18: Each hold has its own slot.** One pending or running export per workspace and hold, so ordinary exports and holds' exports don't block each other. Starting a hold's export is all-or-nothing across its workspaces ([§8](#8-exporting-held-data), [§9.5](#95-workspace_exports)) |
| D20 | How are release requests kept? | **Settled on 2026-11-18: One row per request, never deleted** (`legal_hold_release_requests`). A cancel marks its row and clears nothing, so every note stays on record, and each email reads the request it names ([§6.6](#66-releasing-a-hold)) |
| D21 | Is every org-admin emailed when a shorter retention period takes effect? | **Settled on 2026-11-18: Yes**, by the nightly job, with the period now in force and about how many tasks it deletes, matching the email when a hold's release takes effect ([§5.3](#53-changing-the-period)) |

---

## 15. Goals, tasks and order

**First, a defect of its own.** The column-deletion hazard in
[§2](#2-what-exists-today), which deletes a column's archived tasks without
saying so, is filed as a defect before this work. It affects every board, held
or not, and H5's column guard builds on its confirmation step
([§14](#14-decisions-needed), D16):

| # | Defect | Size | Depends on |
| --- | --- | --- | --- |
| C1 | Replace the column's fixed `data-confirm` with a confirmation step on the server: **Delete** asks the server, which counts the column's open and archived tasks at that moment and opens a modal naming both; an empty column asks no counts; confirming deletes. Tests for the counts, the empty column and owner-only access; the changelog entry | small | — |

Then two goals. Each task is about 1 to 3 hours. Every task that adds text
visible in the UI runs `mix gettext.extract --merge` and translates every
locale. Every task that changes a screen passes `mix dark_mode.scan` and `mix
dark_mode.contrast --enforce` and is checked in light and dark mode. Every
task that adds a telemetry event or audit action declares every key it passes
([§12.2](#122-audit-actions)) and refreshes the event reference in
`docs/telemetry.md` in the same task. Every task that queues an email does it
in the transaction that makes the change ([§12.3](#123-emails)). The
`after_doing` hook runs none of these, so each task lists them in its
verification steps.

### G-R — Let an Organization set how long archived tasks are kept

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| R1 | Add the retention columns to the security policy and `organization_joined_at` to boards, with the check constraints, the range helper and the setting's own changeset, outside `editable_fields/0` | small | — |
| R2 | `set_archived_task_retention/2` and `cancel_archived_task_retention_change/1`: at once or after 7 days, the replace rules, the audit actions for a change, a scheduled change and a cancel, and `Kanban.Notifications.LegalHoldAlerts` and its worker (the recipient check at send time, a deleted actor shown as deleted) with the scheduled, replaced and cancelled emails | medium | R1 |
| R3 | Scope `Archives.Retention.purge_archived_before` to a set of boards, and run the archived-task step per Organization in `PurgeWorker`: apply due changes, each in one transaction with `archived_task_retention_change_applied` and the "took effect" email; the three choices, the join grace, the site setting for other boards; leave the audit step and its stream wrapper as they are; `BoardMoves` sets `organization_joined_at`; the `config/config.exs` comment | medium | R1, R2 |
| R4 | The **Archived task retention** card on `/org/security`, with its own form and Save, and the confirmation with the estimated count | medium | R2 |
| R5 | The Archive page's header line and every row state but **On hold**, with locale dates; the sentence in the three archive actions; the period in the board move's confirmation, keeping its quota refusal | medium | R3 |
| R6 | The `archived_tasks_purged` telemetry event with `count` and `tasks`, the `retention_purge` `archived_task_counts` key, and `archived_task_count` as the total | small | R3 |

### G-H — Legal holds

| # | Task | Size | Depends on |
| --- | --- | --- | --- |
| H1 | Add `legal_holds` and `legal_hold_release_requests` with their constraints, indexes, and the triggers that refuse their deletes, their truncation, and inserts and updates outside [§7.2](#72-in-the-database)'s lists; the `LegalHold` and `ReleaseRequest` schemas | medium | — |
| H2 | The `LegalHolds` context: place, request and cancel a release (a new request row each time), list, counts and `held_board?/1`, with the 100 limit, the hold audit actions and the `placed` and `released` telemetry | medium | H1 |
| H3 | `board_legal_hold_active/1`, the seven `BEFORE DELETE` triggers, the `BEFORE UPDATE` parent guards, the `BEFORE TRUNCATE` triggers on the tables that exist by then, and `Kanban.Release.legal_hold_status/0` with its tests for missing, disabled and changed objects | medium | H1 |
| H4 | `LegalHolds.Enforcement` mapping `KLH01` and writing the refusal event after the rollback; the refusals in the six context functions; `delete_task/2` with the actor and one transaction; the `deletion_refused` telemetry and the `entity_type` tag | medium | H2, H3 |
| H5 | Handle `{:error, :legal_hold}` in every LiveView caller; disable the delete actions on held boards in the board, board list, task, comment, attachment, label, column and Archive screens, with the column refusal in C1's confirmation step; the Archive page's **On hold** row state; `Kanban.Attachments.Usage.held_bytes/1` and the held-storage line in the upload, board-move and import refusals ([§10.4](#104-the-board-and-the-task)) | medium | H4, **C1** |
| H6 | Add `legal_hold_revisions` with its guard and its `BEFORE TRUNCATE` trigger, the revision triggers on the six tables, `kanban.current_user_id` with `NULLIF`, and `set_config` in the contexts that know the actor | medium | H3 |
| H7 | Retention with holds: keep held tasks out of archived-task retention with `held_count` and the `held` measurement; the audit pause in `purge_organization_before/3` and `purge_before/1`; releases applied on their date, each in one transaction with `legal_hold_released` and the "took effect" email; the revision purge; the two security-page notices | medium | H2, H6, H9, **R3**, **R4**, **R6** |
| H8 | `legal_hold_custodian_removed`, with the name and email, written inside the deleting transaction in all three account-deletion paths | small | H2 |
| H9 | The `/org/legal-holds` pages: list, place, a hold's page, request and cancel a release; the hold emails through `LegalHoldAlerts`, reading the matter name from the hold and the note from the request row | medium | H2, H6, **R2** |
| H10 | `workspace_exports` gains `legal_hold_id`, `board_ids` and `signed_key_id`, and the one-active index becomes per workspace and hold ([§9.5](#95-workspace_exports)); the Worker reads the board filter from the row; `legal_hold.json` and `legal_hold_revisions.json` in the export and the importer; **Export held data**, starting every covered workspace or none, with one audit event per request | medium | H6, H9 |
| H11 | Sign the held-data export: extend `manifest.json` with the schema, the instance, the hold, the boards and every other file's size and SHA-256; `manifest.json.sig` through `Kanban.AuditLog.Signing`; `Kanban.LegalHolds.ExportReadme` with the keys address from config; `signed_key_id` on the row and the unsigned and key-changed messages on the hold's page; the importer accepts `manifest.json.sig` and `README.txt` ([§8](#8-exporting-held-data)) | medium | H10 |
| H12 | Docs: `docs/retention-and-legal-hold.md`, the security-policy, organizations, workspace-export (with verifying a signed archive) and attachments docs, `docs/README.md`, the `/privacy` sentence | medium | H5, H7, H8, H9, H11, **R4**, **R5** |
| H13 | The Resources guide, with screenshots in light and dark mode | medium | H5, H7, H9, H11, **R5** |
| H14 | Release prose: pricing features, `ROADMAP.md`, `CHANGELOG.md`, `priv/changelog/body.html` | small | H8, H12, H13 |

**Dependencies between goals.** Bold entries are outside the goal. File C1
first, then create G-R, then G-H with H5 → C1, H7 → R3, R4 and R6, H9 → R2,
H12 → R4 and R5, and H13 → R5, using those tasks' identifiers. Within a
goal, dependencies use array positions.

**Critical path:** H1 → H3 → H6 → H9 → H10 → H11 → H12 → H14.

---

## 16. Risks

| Risk | Mitigation |
| --- | --- |
| A trigger blocks a legitimate operation nobody thought of, such as an import or a migration that deletes or moves rows on a held board | Holds are rare and scoped; the error names the hold rule; `legal_hold_status/0` and the database show active holds. Migrations that delete or move task data check for holds first |
| The revision table grows on a busy held board | Only kept columns, only changed values, never position, move or claim updates; about 4 revisions per agent task, about 1 MB per 1,000 tasks in the review. A hold's revision count is shown on its page, and revisions go 30 days after release |
| An org-admin shortens retention, moves boards in, or releases a hold to destroy evidence | The 7-day waits, emails to every org-admin, and audit events for every step ([§11.1](#111-abuse-by-an-org-admin)) |
| An org-admin removes the other org-admins before releasing a hold | Not prevented. Every step is audited a week apart, and streaming the audit log sends it out of Stride ([§11.1](#111-abuse-by-an-org-admin)) |
| Holds are trusted to mean more than they do | [§7.4](#74-what-enforcement-cannot-do) and the docs say plainly that the app and database operators can still remove data, and that the audit log is the record |
| Large allowed cascades slow down by about 2.7 times | Board and column deletes are rare; the cost test keeps it measured ([§7.2](#72-in-the-database)) |
| Held files fill the Organization's 10 GB attachment storage, and nothing can be deleted to free it | The storage-full message for an upload, a board move or an import says how much of the storage is held ([§10.4](#104-the-board-and-the-task), H5); once a hold is released its files can be deleted again, and the Organization can ask Stride for more storage |
| The column cascade deletes tasks on an unheld board | A separate defect, C1, before this work: the confirmation counts the open and archived tasks it will delete ([§15](#15-goals-tasks-and-order)) |
| A held-data export can't be signed, or stops being verifiable | An instance with no signing key builds it unsigned and the hold's page says so; a key change during the build fails it with a message to request it again; the docs say to keep a rotated key's public half published for as long as its archives matter, and that a revoked key's archives fail verification ([§8](#8-exporting-held-data)) |
| A nightly release or retention change half-applies, or emails about a change that didn't happen | Each one runs in its own transaction with its audit event and its email jobs; a failure rolls all of it back and the next night tries again ([§12.3](#123-emails)) |
