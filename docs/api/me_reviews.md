# GET /api/me/reviews/:task_id

What the Stride mobile app's review screen shows for one task waiting in Review
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §6.4, §7.5): the
agent's summary, the reviewer's verdicts, the acceptance criteria, the security
review, the behaviour matrix, the changed files with the flagged ones first, the
size of the change, and whether this device may approve it.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication). The app sends the same
[`X-Stride-App` header](get_me.md#the-version-header), and an outdated app is
answered `426` before its token is checked.

## Who can see a review

The task must be waiting in the Review column for a decision, on a board the
person can **write** to: the same pending-review query and board-write check
the web Review Queue (`/review`) uses before an approval. A task that is
missing, not waiting for review, archived, on a board the person cannot see, on a board
they can only read, and an id that is not a positive integer in the signed
64-bit range all answer the same `404 {"error": "Not Found"}`, so the answer
reveals nothing about the task.

## Plans

The route is plan-gated with the `mobile_app` feature (design §10). While paid
plans are enforced, Stride checks the person's plan first and then the task's
board, so a person in an Organization still cannot use the app on a board
outside it. The board is checked only once the person is known to be able to
review the task. A refusal is:

```json
{
  "error": "plan_required",
  "feature": "mobile_app",
  "message": "The Stride app is available to boards in an Organization."
}
```

with `403 Forbidden`. `error` is always `plan_required`, so the app can show its
locked panel without matching the message.

## The response

`200 OK`:

```json
{
  "data": {
    "task": {
      "id": 4812,
      "identifier": "W2701",
      "title": "Show the member list on the org page",
      "priority": "high",
      "completed_by_agent": "Claude Opus 4.6",
      "time_spent_minutes": 45,
      "board": {"id": 55, "name": "Stride Development"},
      "goal": {"id": 4800, "identifier": "G530", "title": "Organization console"}
    },
    "summary": "Added the member list and its query.",
    "verdicts": [
      {"section": "acceptance_criteria", "status": "passed", "note": null},
      {"section": "testing_strategy", "status": "passed", "note": null},
      {"section": "patterns", "status": "failed", "note": "The member query is written in the LiveView."},
      {"section": "pitfalls", "status": "passed", "note": null},
      {"section": "security_considerations", "status": "passed", "note": null}
    ],
    "acceptance_criteria": [
      {"criterion": "Members are listed by name", "status": "met", "evidence": "test/kanban_web/live/org_live_test.exs"}
    ],
    "security_considerations": [
      {"consideration": "Only members see the list", "status": "mitigated", "detail": "Scoped to the Organization"}
    ],
    "security_findings": {"critical": 0, "important": 0, "minor": 0},
    "project_checks": {"met": 12, "not_met": 0, "not_applicable": 3},
    "exploratory": {"count": null, "note": "see_notes_on_web"},
    "behaviour_matrix": [
      {"category": "Happy path", "behaviour": "Lists the members", "test_name": "lists members", "type": null, "status": "passing"}
    ],
    "files": [
      {"index": 1, "path": "lib/kanban_web/live/org_live/show.ex", "additions": 11, "deletions": 2, "truncated": false, "flagged": true, "flag_reason": "issue"},
      {"index": 0, "path": "lib/kanban/organizations.ex", "additions": 20, "deletions": 0, "truncated": false, "flagged": false, "flag_reason": null}
    ],
    "size": {"files": 2, "changed_lines": 33, "truncated": false, "large_change": false},
    "approvable_here": true,
    "approvable_here_reason": null,
    "review_requested_at": "2026-11-18T09:30:00Z",
    "waiting_since": "2026-11-18T09:30:00Z",
    "holds_up": [
      {"id": 4813, "identifier": "W2702", "title": "Invite members from the org page"}
    ]
  }
}
```

Every key is always present, and a value that is not known is `null`. Keys are
only ever added, never removed or renamed, while a supported app version reads
them (design §7.2).

### The verdicts

`verdicts` has one entry per section, always in this order:
`acceptance_criteria`, `testing_strategy`, `patterns`, `pitfalls` and
`security_considerations`. `status` is `passed`, `failed`, `not_assessed` or
`null`, resolved by exactly the functions the `/review` verdict cells use, so
the app and the web never show one task with different verdicts. `note` is the
reviewer's note for the section. A task with no review verdicts at all, for
example one whose review was skipped, has `verdicts: []`.

`acceptance_criteria` and `security_considerations` are the reviewer's
per-item results. When the reviewer gave none, they are the task's own criteria
and considerations, with a `null` status. A reviewer criterion whose text is
missing or blank keeps its status with a `null` `criterion`, so a `not_met` is
never dropped. `security_findings` counts the reviewer's security issues by
severity, a severity outside the three counting as `minor` as `/review` groups
it, and `project_checks` counts its project checks by status.

`behaviour_matrix` is the matrix the reviewer echoed back, as `/review` shows
it, and is empty when it echoed none. A row's `type` is the kind of test it
names, such as unit or integration, or `null` when the reviewer gave none.

`exploratory.count` is always `null` today: no structured exploratory result is
stored, and the completion notes are free text that is never parsed. The app
shows "See notes on the web" for it.

### The files

`files` lists each changed file once. `additions` and `deletions` come from the
stored diff, and `truncated` says whether that diff was cut at the per-diff
cap. `index` is the file's position in the stored changed files, which the
file's diff route will take. A task that stored no diffs lists the files it
named instead, with `index`, `additions` and `deletions` all `null`.

A file is **flagged** when a reviewer issue names it, or when the security
section does:

- `flag_reason: "security"` when a security issue names the file, when the
  text of a security consideration whose status is not `mitigated` or
  `not_applicable` names it (a `partial`, `unmitigated` or status-less one),
  or when the security section failed and its note names it;
- `flag_reason: "issue"` when any other issue names it.

An issue may write its file as `path`, `./path`, `path:12`, `path:12:3`,
`path:12-15` or `path#L12`, with backslashes or doubled slashes, or as a longer
path that ends in `/` plus the listed one (a `b/` diff prefix or an absolute
path). Security text may name a file as `path` or `./path`. Two stored entries
that spell one path differently are one file. An issue that names a file that
is not in the list flags nothing. Flagged files
come first; otherwise the files are in diff order. When the reviewer's issues
carry no file at all, nothing is flagged and the files stay in diff order.

The diffs themselves are not in this response.

### Size and approvable_here

`size` counts the change as the large-change guard does (design §7.6): the
files, the added plus deleted lines of the stored diffs, and whether any diff
was cut at the cap. It counts every stored diff, including an entry with no
usable path, which `files` leaves out, so the files' counts can add up to less
than `changed_lines`. `large_change` is `true` above the phone limits that
[GET /api/me](get_me.md) returns, or when a diff was cut.

`approvable_here` says whether **this device** may approve the review: a phone
may not approve a large change, and a tablet may approve any change.
`approvable_here_reason` is `"too_large_for_phone"` when it is `false`, the
same code the approve route answers with, and `null` otherwise. Requesting
changes is never limited. The app must not work this out for itself; the
server's answer decides.

To approve, the app asks for an approval challenge and sends a signed
approval: see [Approve a review in the app](me_review_approval.md). To send
the task back with feedback, see
[Request changes on a review in the app](me_review_request_changes.md).

### Timestamps and holds_up

`review_requested_at` is when the task last entered Review, and is `null` for a
task that predates that stamp. An approval is bound to it. `waiting_since` is
the age `/review` shows: `review_requested_at`, else when the task was last
updated.

`holds_up` lists the tasks on the same board that depend on this one and are
not yet completed, by id.

## Errors

- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token.
- `403` with the `plan_required` body above.
- `404 {"error": "Not Found"}` as described in
  [Who can see a review](#who-can-see-a-review).
