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

`diff` is **unified-patch text** — the same format produced by `git diff` with no special flags. The `diff` value represents whatever change exists between `<base>` and the agent's working tree at completion time, regardless of commit state — committed-since-base, staged-but-uncommitted, and modified-but-unstaged changes all surface in the same patch.

Plugins SHOULD generate the per-file diff for tracked changes with the working-tree-relative form:

```bash
git diff <base> -- <path>
```

For untracked new files that the agent created but never committed, plugins SHOULD enumerate them with `git ls-files --others --exclude-standard` and synthesize a unified-patch entry per file. The standard idiom is `git diff --no-index --no-color /dev/null <path>`, which emits a normal new-file unified patch (with `--- /dev/null` / `+++ b/<path>` headers) for text files and the `Binary files /dev/null and b/<path> differ` sentinel for binary files (use the binary placeholder string for the latter — see the **Binary files** section below).

> **Why the working-tree form, not `<base>..HEAD`?** The earlier contract specified `git diff <base>..HEAD -- <path>`, which captures committed history only. Agents that complete a task without committing first (a common Claude Code pattern when work fits in a single conversation) produced empty snapshots under that form. The working-tree-relative form captures the agent's full working state at completion time and matches what the reviewer would see if they `git diff`'d the agent's branch locally.

Rules:

- UTF-8 encoded.
- Includes the standard `--- a/<path>` (or `--- /dev/null` for new files) / `+++ b/<path>` headers and one or more `@@ ... @@` hunks.
- Line endings are preserved as the plugin captured them; the server does not normalize.
- No syntax highlighting, no HTML, no ANSI color codes — plain text only.
- A single path that's both committed-since-base AND further modified in the working tree appears exactly once in the snapshot, with a diff that reflects the final working-tree state.

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

The UI renders this placeholder as a "binary file changed" notice with no preview. Detection of "binary" is the plugin's responsibility — `git diff --numstat` reports tracked binary files with `-\t-` as the line counts. For untracked new files, plugins can detect binary content by sniffing the `Binary files ... differ` line that `git diff --no-index --no-color /dev/null <path>` emits in place of a unified patch. `file --mime-encoding` can disambiguate edge cases.

Untracked new files that the plugin captures via the synthesized new-file patch (see the **Encoding** section above) appear in the snapshot with a `--- /dev/null` / `+++ b/<path>` header; untracked binaries use the placeholder string above just like tracked binaries.

## Backward compatibility

- The `changed_files` field is **optional** on the completion payload. Payloads that omit it continue to validate.
- Per-file `diff` is optional within each `changed_files` entry. A plugin MAY emit `{"path": "lib/foo.ex"}` with no `diff` if it could not capture one (e.g., the file was deleted, the base ref was unavailable, the diff exceeded a sanity cap). The UI renders "no diff available" for such entries.
- Server-side validation accepts entries with or without `diff`; only malformed values (non-string `diff`, missing `path`, oversized per-file `diff`) are rejected.
- Older plugin versions that emit only `actual_files_changed` continue to work; the review queue shows the file list with no inline diff panel content.

## Transport encoding (optional, edge-filter safe)

Some deployments sit behind an edge request filter (a CDN/WAF layer in front of the app) that inspects request bodies and rejects any body whose text resembles attack syntax. A raw unified diff of ordinary source code can trip such a filter, so the upload is dropped before it reaches the app and `changed_files` silently stays empty (D61).

To avoid that, `PUT /api/tasks/:id/changed_files` **also** accepts a transport-encoded envelope in place of the raw array. The envelope wraps the **same JSON array** (the `[{"path", "diff"}]` shape above), encoded so the body carries no recognizable source text:

```json
{ "changed_files": { "encoding": "base64", "data": "<base64 of the JSON array>" } }
```

- `encoding` MUST be `"base64"` or `"gzip+base64"` (gzip the JSON array, then base64 the gzipped bytes).
- `data` MUST be the encoded JSON array; once decoded it is validated and stored **identically** to the raw shape — all rules above (per-file 500-line cap, binary placeholder, `path` required) apply to the decoded entries.
- This is **purely additive**. The raw array (`{"changed_files": [...]}`) and the bare top-level array body continue to work unchanged; plugins only need the envelope when an edge filter would otherwise reject the raw diff.
- The server bounds the encoded and decoded sizes and returns the standard `completion validation failed` (422) envelope for invalid base64, an unsupported `encoding`, a decompression failure, or a payload that does not decode to a JSON array.

Plugin maintainers SHOULD prefer the encoded form for the diff upload when targeting an edge-filtered deployment, and SHOULD surface a failed upload (a non-2xx response) rather than discarding it silently.

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

- [`PUT /api/tasks/:id/changed_files`](api/put_tasks_id_changed_files.md) — the dedicated upload endpoint and **sole writer** for this field (as of W777/W778).
- [`PATCH /api/tasks/:id/complete`](api/patch_tasks_id_complete.md) — the completion endpoint; **no longer writes `changed_files`** — any value in the completion body is silently ignored. Sending it for backwards compatibility is tolerated.
- `lib/kanban_web/components/review_diff_panel.ex` — the review queue component that consumes this field.
- `lib/kanban/tasks/completion_validation.ex` — server-side validator (`changed_files` validation added in W720).
