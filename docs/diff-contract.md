# Per-File Diff JSON Contract

This document defines the shape of the optional per-file `diff` field carried on the agent completion payload submitted to `PATCH /api/tasks/:id/complete`. Plugin maintainers across the six Stride plugin repos (`stride`, `stride-copilot`, `stride-gemini`, `stride-codex`, `stride-opencode`, `stride-pi`) write against this contract; the Stride server validates against it and the review queue UI renders it.

The field is **optional**. Legacy plugin versions that do not emit it produce a working review with no diff panel (no crash, no error). New plugin versions emit it so reviewers can approve or reject without leaving Stride.

## Field location

The completion payload gains a `changed_files` array. Each entry is an object describing one file the agent touched.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | Yes | Repo-relative file path (e.g., `lib/foo.ex`). Matches the path the plugin would put in `actual_files_changed`. |
| `diff` | string | No | Unified-patch text for this file, truncated to the rule below. Omit for binary files (see below) and for legacy emit paths that do not capture diffs. |

Example completion payload fragment:

```json
{
  "actual_files_changed": "lib/foo.ex, lib/bar.ex, assets/logo.png",
  "changed_files": [
    {"path": "lib/foo.ex", "diff": "--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1,3 +1,4 @@\n defmodule Foo do\n+  @moduledoc \"Foo\"\n end\n"},
    {"path": "lib/bar.ex", "diff": "--- a/lib/bar.ex\n+++ b/lib/bar.ex\n@@ -10,7 +10,7 @@\n   def call(x), do: x\n-  def old(x), do: x\n+  def new(x), do: x + 1\n"},
    {"path": "assets/logo.png", "diff": "[binary file — no diff captured]"}
  ]
}
```

`changed_files` coexists with `actual_files_changed` (the existing comma-separated string). The server keeps `actual_files_changed` as the canonical file list for backward compatibility; `changed_files` adds structured per-file content alongside it.

## Encoding

`diff` is **unified-patch text** — the same format produced by `git diff` with no special flags. Plugins SHOULD generate it with:

```bash
git diff <base>..HEAD -- <path>
```

Rules:

- UTF-8 encoded.
- Includes the standard `--- a/<path>` / `+++ b/<path>` headers and one or more `@@ ... @@` hunks.
- Line endings are preserved as the plugin captured them; the server does not normalize.
- No syntax highlighting, no HTML, no ANSI color codes — plain text only.

## Truncation

The `diff` value for any single file MUST NOT exceed **500 lines** (counting newlines in the captured patch text). Plugins are responsible for truncating before sending; the server applies a defensive backstop and rejects payloads where any per-file `diff` exceeds the cap.

When a plugin truncates, it appends this exact marker on its own line at the end of the truncated content:

```
[diff truncated at 500 lines]
```

The truncation marker is the source of truth across all plugins and the UI. The review queue panel renders a "view full diff in repo" affordance when it sees this marker; do not vary the string.

Example truncated diff:

```diff
--- a/lib/big_module.ex
+++ b/lib/big_module.ex
@@ -1,500 +1,500 @@
... 498 lines of patch content ...
[diff truncated at 500 lines]
```

## Binary files

Plugins MUST NOT attempt to produce a unified-patch diff for binary files (images, compiled artifacts, fonts, etc.). For each binary file the agent touched, emit a `changed_files` entry with `path` set and `diff` set to this exact placeholder:

```
[binary file — no diff captured]
```

The UI renders this placeholder as a "binary file changed" notice with no preview. Detection of "binary" is the plugin's responsibility — `git diff --numstat` reports binary files with `-\t-` as the line counts, and `file --mime-encoding` can disambiguate edge cases.

## Backward compatibility

- The `changed_files` field is **optional** on the completion payload. Payloads that omit it continue to validate.
- Per-file `diff` is optional within each `changed_files` entry. A plugin MAY emit `{"path": "lib/foo.ex"}` with no `diff` if it could not capture one (e.g., the file was deleted, the base ref was unavailable, the diff exceeded a sanity cap). The UI renders "no diff available" for such entries.
- Server-side validation accepts entries with or without `diff`; only malformed values (non-string `diff`, missing `path`, oversized per-file `diff`) are rejected.
- Older plugin versions that emit only `actual_files_changed` continue to work; the review queue shows the file list with no inline diff panel content.

## What plugin maintainers MUST emit vs MAY emit

**MUST**, when emitting `changed_files`:

- An array (possibly empty) of objects, each with a string `path`.
- Truncation applied per-file at 500 lines, with the exact marker string above.
- The exact binary-file placeholder string for binary entries.

**MAY** (per-plugin discretion):

- Omit `changed_files` entirely on legacy code paths.
- Omit `diff` on individual entries where capture failed or was skipped.
- Skip `changed_files` for tasks the plugin classifies as "no diff worth showing" (docs-only edits, generated-file-only changes).

## See also

- [`PATCH /api/tasks/:id/complete`](api/patch_tasks_id_complete.md) — the completion endpoint that carries this field.
- `lib/kanban_web/components/review_diff_panel.ex` — the review queue component that consumes this field.
- `lib/kanban/tasks/completion_validation.ex` — server-side validator (`changed_files` validation added in W720).
