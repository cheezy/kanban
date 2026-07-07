# Security Findings — Input Validation, Changesets & File-Path Handling (W1597)

> Domain 6 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass; the MEDIUM finding
> hand-verified against current code.
>
> **Verdict: one real validation gap.** 0 critical · 0 high · **1 medium** · 0 low ·
> 4 boundaries verified clean.

## Surface reviewed

`tasks/task.ex` (changesets, length validators, API allow-lists),
`schemas/task/key_file.ex`, `schemas/task/verification_step.ex`,
`api/changed_files_transport.ex`, `tasks/db_errors.ex`,
`tasks/completion_validation.ex`.

## D114 — path traversal in `changed_files[].path` (MEDIUM, needs_review)

**Verified.** `CompletionValidation.check_changed_file_path/3`
(`completion_validation.ex:744`) accepts any non-empty string — it enforces only
`is_binary(path) and byte_size(path) > 0`. The sibling `KeyFile.validate_file_path/1`
(`key_file.ex:29`) rejects both a leading `/` and any `..`. The public
`PUT /api/tasks/:id/changed_files` payload is fully attacker-controlled, so
`{"path":"../../../etc/passwd"}` or `{"path":"/etc/shadow"}` validates cleanly and
persists into the `tasks.changed_files` JSONB column.

No filesystem sink for the stored path exists in the reviewed code, so today the
risk is **stored traversal metadata** — but any downstream consumer that treats the
path as a real location (diff-apply tooling, a "view file" link builder, an artifact
writer) inherits a genuine traversal primitive. MEDIUM because the sink is latent,
not present. **Fix:** mirror `KeyFile.validate_file_path/1` on `check_changed_file_path`
(reject leading `/`, `..`, null bytes → clean 422), ideally via a shared
`relative_safe?/1` helper so the two boundaries can't drift again.

## Verified-clean boundaries

- **`KeyFile.file_path`** rejects absolute paths and `..` before persistence (the
  correct reference implementation).
- **W1413 error translation** — `db_errors.ex:41` catches only Postgrex 22001
  (string truncation) → sanitized `:base` 422 with no field name / no raw SQL;
  every other error re-raised with its stacktrace preserved.
- **API mass-assignment** — `api_create_changeset`/`api_update_changeset` cast only
  the strict allow-lists; workflow/audit fields can't be set by an API caller;
  `varchar(255)` scalar + array-element lengths bounded by code-point count, with
  the W1412 regression guard keeping the allow-list in sync with the schema.
- **Decompression-bomb guard** — the gzip+base64 transport uses bounded streaming
  inflate (5MB decoded / 10MB encoded caps); malformed input → 422, not a raise.
