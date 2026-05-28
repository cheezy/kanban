# slugify

Pure function that turns an arbitrary free-text prompt into a filesystem-safe slug. Used by both surface skills (`stride-lite-create-goal` and `stride-lite-create-task`) to derive an artifact directory or file name from a user prompt. Mirrors the canonical `sti_slugify` algorithm from `stride-ideation/lib/filename.sh` (lines 27-44) so that prompts produce identical slugs across the two plugin families.

## Contract

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `input` | string | yes | The free-text prompt; whitespace, punctuation, and mixed case are expected |

**Returns:** the normalized slug on stdout, no trailing newline (use `printf '%s'`, not `echo`).

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Slug produced; written to stdout |
| 1 | Input was empty, OR input normalized to an empty string (e.g. only punctuation) |

## Slug rules

The slug is the result of applying these transformations in order to `input`:

1. **Lowercase** every character (`tr '[:upper:]' '[:lower:]'`).
2. **Replace any character outside `[a-z0-9-]` with a single dash** (`sed -E 's/[^a-z0-9-]+/-/g'`). Replace, never delete — preserves word boundaries so `"Add Notifications!"` becomes `add-notifications`, not `addnotifications`.
3. **Collapse runs of dashes** to a single dash (`s/-+/-/g`).
4. **Trim leading and trailing dashes** (`s/^-//; s/-$//`).

The result MUST match `^[a-z0-9]+(-[a-z0-9]+)*$` — lowercase alphanumerics separated by single dashes, with no leading or trailing dash. If after step 4 the result is the empty string, exit 1.

The slug MUST be deterministic: identical input always yields identical output regardless of locale, $TZ, or invocation context. No random suffixes, no timestamps, no PID embedding — those concerns belong to `resolve_output_path`, not to slugification.

## Pitfalls

- **Do not use `String.to_atom`-style conversions on user input.** The slug must remain a plain string. Atoms (in Elixir) or symbols (in Ruby) on user input leak memory and create attack surface.
- **Do not silently delete non-alphanumeric characters.** Replacement-with-dash preserves word boundaries; deletion fuses adjacent words and produces unreadable slugs.
- **Do not depend on locale-sensitive case folding.** Use ASCII lowercase only (`tr '[:upper:]' '[:lower:]'` against ASCII input). Non-ASCII characters fall through the `[^a-z0-9-]+` replacement step and become dashes.
- **Do not emit a trailing newline.** Callers concatenate the slug into paths (`"${dir%/}/${slug}/"`); a trailing `\n` corrupts the path.

## Reference implementation

```bash
slugify() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "slugify: empty input" >&2
    return 1
  fi
  local lowered
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  local replaced
  replaced="$(printf '%s' "$lowered" \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$replaced" ]; then
    echo "slugify: slug normalized to empty string" >&2
    return 1
  fi
  printf '%s' "$replaced"
}
```

## Examples

| Input | Output | Exit |
|---|---|---|
| `Add real-time notifications` | `add-real-time-notifications` | 0 |
| `  Multiple   spaces & symbols!! ` | `multiple-spaces-symbols` | 0 |
| `Café résumé` | `caf-r-sum` | 0 |
| `UPPERCASE` | `uppercase` | 0 |
| `___under_scores___` | `under-scores` | 0 |
| `42-already-a-slug` | `42-already-a-slug` | 0 |
| (empty string) | (stderr: "empty input") | 1 |
| `!!!` | (stderr: "slug normalized to empty string") | 1 |

## Edge cases

- **Empty input** — exit 1 with `"slugify: empty input"` on stderr. Callers must handle this case explicitly; do not paper over it with a default slug.
- **All-punctuation input** — after step 4 the slug is empty. Exit 1 with `"slug normalized to empty string"` on stderr. Same caller contract as empty input.
- **Numeric-only input** — `"123"` becomes `"123"`. Valid slug. No special handling.
- **Non-ASCII input** — characters outside `[a-z0-9-]` collapse to dashes. `"Café"` becomes `"caf"`. Callers wanting Unicode-aware transliteration must preprocess before invoking `slugify`.
- **Very long input** — no built-in length cap. Callers that need one (most filesystems cap component length at 255 bytes) must truncate after slugification, ensuring the truncation does not leave a trailing dash.
