# resolve_output_path

Pure function that resolves a unique output path under a caller-supplied base directory, suffixing `-2`, `-3`, ... when the target already exists. Used by both surface skills to land each invocation's artifacts in a fresh directory or file without ever overwriting prior work. Mirrors the collision-suffix invariant of `sti_unique_path` from `stride-ideation/lib/filename.sh` (lines 237-262), but with a simpler path template that targets either a `<base>/<slug>/` directory or a `<base>/<slug>.<ext>` file rather than a timestamped artifact name.

## Contract

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `base_dir` | string | yes | The caller-supplied root, typically `docs/implementation/PENDING` (default) or an `--output-dir` override. Trailing slashes are tolerated and stripped. |
| `slug` | string | yes | A normalized slug from [`slugify`](slugify.md). Required to match `^[a-z0-9]+(-[a-z0-9]+)*$`; caller is responsible. |
| `kind` | enum | yes | One of `dir` (resolve a `<base>/<slug>/` directory) or `file` (resolve a `<base>/<slug>.<ext>` file). |
| `ext` | string | when `kind=file` | The file extension, no leading dot (e.g. `md`, `json`). Ignored when `kind=dir`. |

**Returns:** the resolved path on stdout, no trailing newline. The path is guaranteed to NOT exist at the moment of return.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Path resolved and written to stdout |
| 1 | Bad usage (missing parameter, invalid `kind`, missing `ext` when `kind=file`) |
| 2 | Refused: more than 1000 collisions detected (defensive cap) |

## Path templates

- `kind=dir`  → `<base_dir>/<slug>/` (no trailing slash on the path itself; the caller `mkdir -p`s)
- `kind=file` → `<base_dir>/<slug>.<ext>`

When the initial candidate already exists, the helper appends `-N` to the slug (NOT to the extension) and probes:

- `kind=dir`  → `<base_dir>/<slug>-2/`, `<base_dir>/<slug>-3/`, ...
- `kind=file` → `<base_dir>/<slug>-2.<ext>`, `<base_dir>/<slug>-3.<ext>`, ...

The counter starts at 2 (NOT 1) so that the first collision yields `<slug>-2`, matching the existing stride-ideation convention. A single file at `<base>/<slug>.<ext>` and another at `<base>/<slug>-2.<ext>` means the next attempt yields `<slug>-3.<ext>`.

## Invariants

- **The hard invariant is "never overwrite an existing file or directory."** The returned path MUST NOT exist at the moment the helper writes it to stdout. Callers race-create the artifact between the probe and the create; that race is acceptable (downstream `mkdir -p` and `set -o noclobber` writers detect it).
- **`base_dir` is a parameter, NOT a hardcoded constant.** Callers wire the `--output-dir` flag (default `docs/implementation/PENDING`) through to this helper. Hardcoding the base inside the helper breaks the `--output-dir` override.
- **The helper MUST NOT create the path** — it only resolves. Creation is the caller's responsibility, deliberately, so the helper remains pure and testable.

## Pitfalls

- **Do not silently overwrite an existing goal directory.** Always probe and bump the suffix until a free name is found.
- **Do not hardcode `docs/implementation/PENDING` inside the resolver.** Pass it in via `base_dir` so `--output-dir` works.
- **Do not iterate without an upper bound.** A symlink loop or a filesystem with millions of suffixed siblings can spin forever. Cap at 1000 and exit 2 if exceeded.
- **Do not interpret `base_dir` as an absolute path on Windows by accident.** Bash treats `C:/...` as a relative path under `C`. Either reject absolute Windows paths in `parse_args`, or document that callers must use POSIX paths.

## Reference implementation

```bash
resolve_output_path() {
  local base_dir="${1:-}"
  local slug="${2:-}"
  local kind="${3:-}"
  local ext="${4:-}"

  if [ -z "$base_dir" ] || [ -z "$slug" ] || [ -z "$kind" ]; then
    echo "resolve_output_path: usage: resolve_output_path <base_dir> <slug> <dir|file> [<ext>]" >&2
    return 1
  fi
  if [ "$kind" != "dir" ] && [ "$kind" != "file" ]; then
    echo "resolve_output_path: kind must be 'dir' or 'file', got '$kind'" >&2
    return 1
  fi
  if [ "$kind" = "file" ] && [ -z "$ext" ]; then
    echo "resolve_output_path: ext is required when kind=file" >&2
    return 1
  fi

  local stripped="${base_dir%/}"
  local candidate
  if [ "$kind" = "dir" ]; then
    candidate="${stripped}/${slug}"
  else
    candidate="${stripped}/${slug}.${ext}"
  fi
  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  local n=2
  while :; do
    if [ "$kind" = "dir" ]; then
      candidate="${stripped}/${slug}-${n}"
    else
      candidate="${stripped}/${slug}-${n}.${ext}"
    fi
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$(( n + 1 ))
    if [ "$n" -gt 1000 ]; then
      echo "resolve_output_path: refusing to scan past -1000 collisions" >&2
      return 2
    fi
  done
}
```

## Examples

Assume `base_dir=docs/implementation/PENDING` and only the paths below exist.

| Existing | Call | Result |
|---|---|---|
| (none) | `resolve_output_path docs/impl/goals add-notifs dir` | `docs/impl/goals/add-notifs` |
| `docs/impl/goals/add-notifs/` | `resolve_output_path docs/impl/goals add-notifs dir` | `docs/impl/goals/add-notifs-2` |
| `add-notifs/`, `add-notifs-2/` | `resolve_output_path docs/impl/goals add-notifs dir` | `docs/impl/goals/add-notifs-3` |
| (none) | `resolve_output_path docs/impl/goals add-notifs file md` | `docs/impl/goals/add-notifs.md` |
| `add-notifs.md` | `resolve_output_path docs/impl/goals add-notifs file md` | `docs/impl/goals/add-notifs-2.md` |
| `add-notifs.md`, `add-notifs-2.md` | `resolve_output_path docs/impl/goals add-notifs file md` | `docs/impl/goals/add-notifs-3.md` |

`--output-dir` override:

```bash
resolve_output_path /tmp/scratch quick-test dir
# -> /tmp/scratch/quick-test
```

## Edge cases

- **`base_dir` does not yet exist** — the helper returns the candidate path anyway; it is the caller's job to `mkdir -p "$(dirname "$candidate")"` (for `kind=file`) or `mkdir -p "$candidate"` (for `kind=dir`) before writing.
- **`base_dir` is an absolute path** — supported. `resolve_output_path /tmp/scratch foo dir` yields `/tmp/scratch/foo`.
- **`base_dir` is a symlink to a directory** — supported. The probe follows the symlink. Race condition: if the symlink is swapped between probe and create, the caller's write may land somewhere unexpected. Acceptable for the threat model.
- **Slug contains an extension-like suffix** — e.g. `slug=add.md`, `kind=file`, `ext=md` yields `add.md.md`. This is correct; the caller should not pass a slug containing a dot when `kind=file`.
- **More than 1000 collisions** — exit 2 with `"refusing to scan past -1000 collisions"` on stderr. Indicates either a runaway script or a deliberately adversarial filesystem; callers should surface the error rather than retry.
- **`slug` is the empty string** — undefined behavior. Callers MUST validate via `slugify` first; the resolver does not re-validate.
