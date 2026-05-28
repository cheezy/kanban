# parse_args

Pure function that extracts the user prompt, the `--requirements-dir` flag, and the `--output-dir` flag from the argv supplied to a surface skill. Returns three sourceable assignment lines on stdout (`PROMPT=...`, `REQUIREMENTS_DIR=...`, `OUTPUT_DIR=...`) so callers can `eval` or `source <(...)` the result without further parsing. Defaults follow the contract: `--requirements-dir` defaults to `docs/requirements` and `--output-dir` defaults to `docs/implementation/PENDING`. Pattern mirrors the `while/case` arg-parsing loop in `stride-ideation/lib/run_smoke_test.sh`.

## Contract

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `argv` | positional + flagged | yes | Free-form argv as supplied by the surface skill. Positional args concatenate (space-joined) into `PROMPT`; flags are extracted ahead of positionals. |

**Returns:** three lines on stdout, each `KEY=value` shell-quoted via `printf '%q'`:

```
PROMPT=<single-quoted prompt>
REQUIREMENTS_DIR=<single-quoted path>
OUTPUT_DIR=<single-quoted path>
```

Callers source the result:

```bash
eval "$(parse_args "$@")"
echo "$PROMPT"           # → the user prompt
echo "$REQUIREMENTS_DIR" # → resolved requirements directory
echo "$OUTPUT_DIR"       # → resolved output directory
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | argv parsed; three assignments on stdout |
| 1 | A recognized flag was supplied without a value (e.g. `--requirements-dir` at the end of argv) |
| 2 | Prompt is empty (no positional args, or all positionals consumed by flag values) |

## Recognized flags

| Flag | Default | Notes |
|---|---|---|
| `--requirements-dir <path>` | `docs/requirements` | Directory passed to `load_requirements_dir`. May be absolute or relative. Not validated for existence here — `load_requirements_dir` handles missing dirs non-fatally. |
| `--output-dir <path>` | `docs/implementation/PENDING` | Directory passed to `resolve_output_path` as `base_dir`. May be absolute or relative. Not validated for existence here — callers `mkdir -p` after resolving. |

Flag form: `--name value` only. The fused form `--name=value` is NOT supported (keeps the parser simple; surface skills control their own invocation). Unknown flags are passed through to the prompt — they become part of the positional concatenation — so users typing prose containing a literal `--` token are not silently swallowed.

## Defaults

The defaults MUST be the literal strings `docs/requirements` and `docs/implementation/PENDING` — relative paths from the project root. The caller is responsible for `cd`-ing to the project root before invoking the skill; the helper does NOT resolve to an absolute path.

Why these specific defaults are non-negotiable:

- `docs/requirements` is where requirements docs land (produced by ideation skills in sibling plugins and consumed by the surface skills here). Changing it breaks the implicit contract across the plugin families.
- `docs/implementation/PENDING` is where `stride-lite-create-goal` lands its goal directories. The path includes `implementation/` to distinguish goal artifacts from raw requirements; downstream tooling (post-processing scripts, CI, archival, and the `stride-lite-workflow` terminal PENDING→IMPLEMENTED archive move) keys on this directory shape.

## Pitfalls

- **Do not default `--requirements-dir` to anything other than `docs/requirements`.** Cross-skill contract.
- **Do not default `--output-dir` to anything other than `docs/implementation/PENDING`.** Same contract.
- **Do not consume the prompt as a flag value if the user puts the flag first.** The parser must peek at the next token before consuming.
- **Do not silently drop unknown flags.** Either treat them as part of the prompt (current contract) or exit non-zero — but never delete them.
- **Do not assume `bash`-only shell.** Use `[ ... ]` not `[[ ... ]]` where portable. The surface skills invoke this via `bash -c '. lib/parse_args.sh; parse_args "$@"' _ "$@"`; the leading `_` is the conventional `$0` placeholder.
- **Do not interpret the prompt.** Concatenation is verbatim; quoting is the caller's responsibility.

## Reference implementation

```bash
parse_args() {
  local requirements_dir="docs/requirements"
  local output_dir="docs/implementation/PENDING"
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --requirements-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --requirements-dir requires a value" >&2
          return 1
        fi
        requirements_dir="$2"
        shift 2
        ;;
      --output-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --output-dir requires a value" >&2
          return 1
        fi
        output_dir="$2"
        shift 2
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local prompt=""
  if [ "${#positional[@]}" -gt 0 ]; then
    prompt="${positional[*]}"
  fi

  if [ -z "$prompt" ]; then
    echo "parse_args: prompt is required (supply at least one positional argument)" >&2
    return 2
  fi

  printf 'PROMPT=%q\n' "$prompt"
  printf 'REQUIREMENTS_DIR=%q\n' "$requirements_dir"
  printf 'OUTPUT_DIR=%q\n' "$output_dir"
}
```

## Examples

**Prompt only — both flags default:**

```bash
parse_args "Add real-time notifications"
# PROMPT=Add\ real-time\ notifications
# REQUIREMENTS_DIR=docs/requirements
# OUTPUT_DIR=docs/implementation/PENDING
```

**Prompt + `--requirements-dir` override:**

```bash
parse_args --requirements-dir /tmp/reqs "Add notifs"
# PROMPT=Add\ notifs
# REQUIREMENTS_DIR=/tmp/reqs
# OUTPUT_DIR=docs/implementation/PENDING
```

**Prompt + `--output-dir` override:**

```bash
parse_args "Add notifs" --output-dir build/goals
# PROMPT=Add\ notifs
# REQUIREMENTS_DIR=docs/requirements
# OUTPUT_DIR=build/goals
```

**Both flags + multi-word prompt with flags interspersed:**

```bash
parse_args --output-dir /tmp/out "Refactor" --requirements-dir /tmp/r "the auth"
# PROMPT=Refactor\ the\ auth
# REQUIREMENTS_DIR=/tmp/r
# OUTPUT_DIR=/tmp/out
```

**Empty argv:**

```bash
parse_args
# stderr: parse_args: prompt is required (supply at least one positional argument)
# exit:   2
```

**Flag without value:**

```bash
parse_args "Add notifs" --requirements-dir
# stderr: parse_args: --requirements-dir requires a value
# exit:   1
```

**Absolute `--output-dir`:**

```bash
parse_args "Quick test" --output-dir /tmp/scratch
# PROMPT=Quick\ test
# REQUIREMENTS_DIR=docs/requirements
# OUTPUT_DIR=/tmp/scratch
```

**`--output-dir` pointing at a path that does not yet exist:**

```bash
parse_args "Quick test" --output-dir docs/2026Q4/goals
# PROMPT=Quick\ test
# REQUIREMENTS_DIR=docs/requirements
# OUTPUT_DIR=docs/2026Q4/goals
```

`parse_args` does not validate that the directory exists; `resolve_output_path` will `mkdir -p` upstream of writing.

## Edge cases

- **Flag appears multiple times** — the LAST occurrence wins. Earlier occurrences are silently overwritten. This matches the conventional shell expectation for repeated flags.
- **Prompt is the literal string `--`** — treated as a positional argument (a one-character prompt). The parser does not implement the `--` "end of options" convention; surface skills do not need it.
- **`--requirements-dir ""`** (empty-string value) — accepted; `load_requirements_dir` will then log "directory not found: " and return empty stdout. Non-fatal, intentional.
- **`--output-dir ""`** — accepted; `resolve_output_path` will then probe paths starting with `/` (because `${empty%/}/${slug}` yields `/${slug}`). Surface skills should reject this case before calling `resolve_output_path` if they care.
- **Prompt contains characters that need quoting** — `printf '%q'` produces a shell-safe encoding (e.g. `it's` becomes `it\'s`). Callers using `eval "$(parse_args ...)"` get the correctly-quoted value.
- **Prompt contains a newline** — preserved by `printf '%q'` as `$'\n'`-style escaping. Callers receive the prompt verbatim after sourcing.
