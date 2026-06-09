# Fully-Populated Review Report Contract

This document defines what a **fully-populated** `reviewer_result` must contain on
the agent completion payload submitted to `PATCH /api/tasks/:id/complete`, and the
rules that tie that report back to the task it describes. Plugin maintainers across
the Stride plugin repos write against this contract; the Stride server validates
against it (`Kanban.Tasks.CompletionValidation`) and the review queue UI renders it.

The guiding principle: **a dispatched review must deliver all of its information —
no exceptions.** A review that omits a section, ships an empty project-checks list,
or reports a section as unassessed when the task supplied content for it is a defect,
not an acceptable state. The server is the backstop that refuses to persist such a
report; this contract is what "fully populated" means.

## Required structured sections

When a `reviewer_result` is marked `"dispatched": true`, it must carry **every**
section below. The canonical list is the `@required_review_sections` attribute in
`lib/kanban/tasks/completion_validation.ex`, exposed as
`CompletionValidation.required_review_sections/0` — it is the single source of
truth, and no caller may re-enumerate the keys inline (an inline allow-list is
exactly how `project_checks` came to be silently dropped).

| Section | Type | Meaning |
|---------|------|---------|
| `issues` | list | Categorized review issues. May be empty, but must be present. |
| `acceptance_criteria` | list | Per-criterion results the review queue renders. |
| `project_checks` | list | Verdict for every bullet of the project checklist (`CODE-REVIEW.md`). Must be non-empty and cover the whole checklist. |
| `testing_strategy` | object | Per-section verdict: were the task's specified tests written. |
| `patterns` | object | Per-section verdict: was `patterns_to_follow` honored. |
| `pitfalls` | object | Per-section verdict: were the task's `pitfalls` avoided. |
| `security_considerations` | object | Per-section verdict: were the task's `security_considerations` addressed. |
| `schema_version` | string | The reviewer schema version that produced the block. |

In addition, a dispatched review must carry **either** `status` **or** `issue_counts`
so the review queue can render the verdict. This either/or pair is required alongside
the sections above but, because it is not a single fixed key, is enforced separately
(`require_status_or_issue_counts/2`) rather than listed in
`@required_review_sections`.

The per-section verdict objects use the status enum `passed` / `failed` /
`not_assessed`. `not_assessed` is reserved strictly for a section the **task** left
empty — it may never stand in for information the agent failed to deliver.

## Task cross-field rules

Beyond shape, the report must be **consistent with the task it describes**. The
validator compares the report against the task's own inputs:

1. **Security considerations.** If the task supplied `security_considerations`, the
   report's `security_considerations` verdict must be a real assessment (`passed` or
   `failed`) — never `not_assessed` or absent. A task that listed security
   considerations can never come back "not assessed."
2. **Testing strategy.** If the task supplied a `testing_strategy`, the report's
   `testing_strategy` verdict must be a real assessment, never `not_assessed` or
   absent.
3. **Acceptance criteria coverage.** The report's `acceptance_criteria` entries must
   account for every acceptance-criterion line the task defined. A report that checks
   fewer criteria than the task listed is incomplete.

When the task supplies no content for a given field, the matching rule is skipped —
the report is not forced to invent a verdict for something the task never asked about.

## Enforcement

These rules are enforced server-side at the completion endpoint and are designed to
be **non-bypassable**: no agent, plugin, or runtime can persist a thin or
task-inconsistent review report. The defect classes this contract closes are the two
recurring failures where the project-checks list was truncated and where a supplied
security consideration was reported as unassessed.
