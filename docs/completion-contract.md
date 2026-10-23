# Fully-Populated Review Report Contract

This document is for contributors changing the completion validators and for
plugin maintainers across the Stride plugin repos whose agents build the review
report. It defines what a **fully-populated** `reviewer_result` must contain on
the agent completion payload submitted to `PATCH /api/tasks/:id/complete`, and the
rules that tie that report back to the task it describes. Plugin maintainers write
against this contract; the Stride server validates against it
(`Kanban.Tasks.CompletionValidation`) and the review queue UI renders it.

The guiding principle: **a dispatched review must deliver all of its information —
no exceptions.** A review that omits a section, ships an empty project-checks list,
or reports a section as unassessed when the task supplied content for it is a defect,
not an acceptable state. The server is the backstop that refuses to persist such a
report; this contract is what "fully populated" means.

## Required structured sections

When a `reviewer_result` is marked `"dispatched": true`, it must carry **every**
section below. The canonical list is the `@required_review_sections` attribute in
`lib/kanban/tasks/completion_validation/review_contract.ex`, re-exported as
`CompletionValidation.required_review_sections/0` — it is the single source of
truth, and no caller may re-enumerate the keys inline (an inline allow-list is
exactly how `project_checks` came to be silently dropped).

| Section | Type | Meaning |
|---------|------|---------|
| `issues` | list | Categorized review issues. May be empty, but must be present. |
| `acceptance_criteria` | list | Per-criterion results the review queue renders. |
| `project_checks` | list | One verdict per bullet of the **calling project's** optional root `CODE-REVIEW.md`. The key must be present and its value a list — `null` is rejected; the list may be any length, and `[]` is valid — it means that project has no checklist. The server never sees that file, so it never gates on the list's length. |
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
3. **Acceptance criteria coverage.** The report must carry at least as many
   `acceptance_criteria` entries as the task has non-blank acceptance-criterion
   lines. A report that checks fewer criteria than the task listed is incomplete.
   Entries are counted, not matched to the task's lines by text; an over-count is
   covered by the strict-mode check below.

When the task supplies no content for a given field, the matching rule is skipped —
the report is not forced to invent a verdict for something the task never asked about.

## Failed verdicts carry a note

A `failed` verdict on `testing_strategy`, `patterns`, `pitfalls`,
`security_considerations` or `behaviour_test_matrix` must carry a string `note` of
at least 20 non-whitespace characters that names the specific violation or gap. A
note made only of placeholder or status words, such as `placeholder`, `TBD`, `n/a`
or `section failed`, is refused. `passed` and `not_assessed` verdicts need no note.
The list of sections and the placeholder words live in
`lib/kanban/tasks/completion_validation/review_contract.ex`.

## Enforcement

These rules are enforced server-side at the completion endpoint and are designed to
be **non-bypassable**: no agent, plugin, or runtime can persist a thin or
task-inconsistent review report. The required sections, the `status` or
`issue_counts` pair, a `project_checks` value that is a list, the failed-verdict
note and the three task cross-field rules are checked on every dispatched review
and reject with a 422 whatever the strict-validation setting is. The defect classes
this contract closes are the two recurring failures where the project-checks list
was truncated and where a supplied security consideration was reported as
unassessed.

## Checks that follow the strict-validation setting

Two further consistency checks run on every completion but reject only when strict
completion validation is on:

- **Security breakdown.** When `security_considerations.considerations[]` marks any
  item `partial` or `unmitigated`, the section verdict must be `failed`.
- **Acceptance-criteria counts.** The `acceptance_criteria` array length and the
  legacy `acceptance_criteria_checked` integer must each equal the task's number of
  non-blank criterion lines. Unlike the coverage rule above, this also flags an
  over-count.

Strict validation is on by default in production and off elsewhere, and the
`STRIDE_STRICT_COMPLETION_VALIDATION` environment variable (`true` or `false`)
overrides that default. With it off, these failures are logged as a warning and the
completion succeeds.
