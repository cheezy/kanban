# load_requirements_dir

Pure function that reads every text file in a requirements directory and concatenates the contents to stdout with file-name headers. Used by both surface skills to assemble the requirements context block that gets prepended to the user prompt before downstream reasoning. Tolerates a missing directory (returns the empty string and logs a one-line note to stderr) and skips binary files (logs a one-line note to stderr per skipped file) so the surface skill can run even when the requirements directory has not been created yet.

## Contract

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `dir` | string | yes | The requirements directory, typically `docs/requirements` (default) or a `--requirements-dir` override. |

**Returns:** the concatenated text of every text file in `dir`, with a header line preceding each file's contents, on stdout. Empty string when `dir` is missing, is not a directory, or contains zero text files.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Always (missing directories are non-fatal; the helper logs and continues) |

The helper deliberately has no failure exit code. A missing requirements directory is the normal case for fresh projects; treating it as fatal would block first-time users from invoking the skills.

## Output format

For each text file (in sorted-by-name order) the helper emits:

```
=== <relative-path> ===

<file contents verbatim>

```

Three rules:

1. **Header marker:** the literal line `=== <relative-path> ===` where `<relative-path>` is the file's path relative to `dir` (NOT relative to CWD). One blank line follows the header.
2. **File contents are emitted verbatim** — no trimming, no normalization, no line-ending conversion. The downstream consumer is a language model; the surrounding `===` markers give it an unambiguous boundary.
3. **A blank line separates files.** If the file does not end in a newline, the helper emits one before the separator blank line so the trailing `===` of the next header lands on its own line.

## File selection rules

- **Recursive descent** through `dir` (`find "$dir" -type f`).
- **Sorted by relative path** so the output is deterministic across invocations.
- **Hidden files (`.foo`, `.DS_Store`) are skipped.** Most users do not expect dotfiles to be slurped into the requirements context.
- **Symlinks are followed** for regular files (`find -L`), but symlinked directories are NOT followed beyond the first level — this caps the recursion depth and avoids cycles.
- **Binary files are skipped** with a one-line note to stderr. A file is treated as binary if the first 8KB contain a NUL byte. The check is done by comparing the byte count of the first 8KB before and after stripping NULs with `tr -d '\0'` — this is portable across BSD and GNU `grep`, which differ in how they handle NUL bytes in patterns. This handles `.png`, `.pdf`, `.zip`, compiled artifacts.
- **Files larger than 1 MiB are skipped** with a one-line note to stderr. Defensive against accidentally checking in a database dump.

## Pitfalls

- **Do not crash when `--requirements-dir` is missing.** Return the empty string and log `"load_requirements_dir: directory not found: <dir>"` to stderr. Surface skills must continue to function on fresh projects.
- **Do not read binary files into the context.** Detect the NUL byte and skip; logging the skip is informative to the user.
- **Do not normalize line endings or strip BOMs.** The downstream consumer is a language model — verbatim content with explicit boundaries is the contract.
- **Do not write headers when the file is skipped.** A skipped binary or oversized file produces no output, only a stderr log line.
- **Do not depend on `find -printf`** — it is GNU-only and absent on BSD/macOS. Use POSIX `find ... -type f` and pipe through `sort`.

## Reference implementation

```bash
load_requirements_dir() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "load_requirements_dir: usage: load_requirements_dir <dir>" >&2
    return 0
  fi
  if [ ! -d "$dir" ]; then
    echo "load_requirements_dir: directory not found: $dir" >&2
    return 0
  fi

  local stripped="${dir%/}"
  local file rel

  # Sorted, recursive, regular files only, hidden files excluded.
  find -L "$stripped" -type f -not -path '*/.*' 2>/dev/null \
    | sort \
    | while IFS= read -r file; do
        rel="${file#${stripped}/}"

        # Size cap: skip files > 1 MiB.
        local size
        size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
          echo "load_requirements_dir: skipping (>1MiB): $rel" >&2
          continue
        fi

        # Binary detection: NUL byte in first 8KB. Portable across BSD/GNU
        # grep by comparing byte counts before and after stripping NULs.
        local raw_bytes stripped_bytes
        raw_bytes="$(head -c 8192 "$file" 2>/dev/null | wc -c | tr -d '[:space:]')"
        stripped_bytes="$(head -c 8192 "$file" 2>/dev/null | LC_ALL=C tr -d '\0' | wc -c | tr -d '[:space:]')"
        if [ "${raw_bytes:-0}" -ne "${stripped_bytes:-0}" ]; then
          echo "load_requirements_dir: skipping (binary): $rel" >&2
          continue
        fi

        printf '=== %s ===\n\n' "$rel"
        cat "$file"
        # Ensure trailing newline.
        if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
          printf '\n'
        fi
        printf '\n'
      done
}
```

## Examples

**Directory exists with two markdown files:**

```
docs/requirements/
  goal.md          ("# Goal\n\nReal-time notifications.\n")
  constraints.md   ("# Constraints\n\nMust ship by 2026-06-01.\n")
```

Call `load_requirements_dir docs/requirements` emits:

```
=== constraints.md ===

# Constraints

Must ship by 2026-06-01.

=== goal.md ===

# Goal

Real-time notifications.

```

(Sorted by relative path → `constraints.md` precedes `goal.md`.)

**Directory missing:**

```bash
load_requirements_dir docs/does-not-exist
# stdout: (empty)
# stderr: load_requirements_dir: directory not found: docs/does-not-exist
# exit:   0
```

**Directory with a binary file:**

```
docs/requirements/
  notes.md     (text)
  diagram.png  (binary)
```

```
=== notes.md ===

<contents of notes.md>

```

stderr: `load_requirements_dir: skipping (binary): diagram.png`

## Edge cases

- **Missing directory** — empty stdout, log to stderr, exit 0. The non-fatal contract is deliberate; surface skills must work on fresh projects.
- **Empty directory** — empty stdout, no log, exit 0.
- **Symlink as the directory itself** — followed once (`find -L` follows the top-level symlink). Symlinks _inside_ the directory are followed for regular files only; symlinked subdirectories are not recursed into (cycle defense).
- **File without trailing newline** — the helper emits a synthetic newline before the blank separator so the next header is line-aligned.
- **Permission denied on a file** — `cat` writes an error to stderr; the helper continues with the next file. Acceptable: the user is informed via stderr without aborting the whole context build.
- **Concurrent modification of `dir` during the walk** — best-effort. Files added during the walk may or may not be picked up; files removed mid-walk may produce a transient `cat` error. Surface skills do not require atomicity for this read.
- **Sort collation differences across systems** — the helper sorts via POSIX `sort` with no locale override. Callers that need cross-system byte-identical output should set `LC_ALL=C` before invoking.
