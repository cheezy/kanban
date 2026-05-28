---
name: stride-lite-create-task
description: Use to turn a user prompt + an optional requirements directory into a single written task markdown file at `<output-dir>/tasks/<slug>.md` (default `docs/implementation/PENDING/tasks/<slug>.md`). The output is rendered with the same per-task markdown template as the `stride-lite-create-goal` skill, never POSTed to any API. Activate when the user asks to create a single Stride-shaped task, write a one-off task markdown file, or generate a task spec from a free-text prompt — optionally with `--requirements-dir <path>` (default `docs/requirements`) or `--output-dir <path>` (default `docs/implementation/PENDING`). Terminal state is the written file; the skill does not push the user toward any follow-up action.
skills_version: "1.0"
---

# stride-lite-create-task

Surface skill for the single-task flow. Mirrors the orchestration shape of `stride-lite-create-goal` but produces exactly one markdown file at `<output-dir>/tasks/<slug>.md` from a single dispatch of the `create-decomposer` subagent in `mode=task`.

## What this skill does

```
parse_args  ->  load_requirements_dir  ->  create-decomposer (mode=task)
            ->  slugify (task title)    ->  resolve_output_path (kind=file, ext=md)
            ->  render single task markdown to <output-dir>/tasks/<slug>.md
```

Every step routes through a `lib/` helper or the `create-decomposer` subagent — the skill itself contains no slugification, path-resolution, or arg-parsing logic of its own.

## What this skill does NOT do

- **Never POSTs to the Stride API.** Writes one markdown file to disk and prints a summary.
- **Never writes to `<output-dir>/<slug>/`** (the goal-flow shape). The single-task output lives at `<output-dir>/tasks/<slug>.md` so it can sit alongside any number of goal directories without colliding.
- **Never overwrites an existing task file.** `resolve_output_path` suffixes `-2`, `-3`, ... on collision.
- **Never bypasses the lib/ helpers.** Every step uses its designated helper so behavior is testable in isolation.
- **Never diverges the task template** from the per-task template in `stride-lite-create-goal/SKILL.md`. The two skills MUST render identical task markdown — single-task output and per-task files inside a goal directory should be indistinguishable in shape.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `<prompt>` | required | One or more positional args; concatenated by `parse_args`. |
| `--requirements-dir <path>` | `docs/requirements` | Passed verbatim to `load_requirements_dir`. Missing directories are non-fatal. |
| `--output-dir <path>` | `docs/implementation/PENDING` | Passed verbatim to `resolve_output_path` as `base_dir`, prefixed with `/tasks` before resolution. The skill `mkdir -p`s `<output-dir>/tasks/` before writing. |

The defaults match the create-goal skill so the two surfaces share an output root and `tasks/` is a sibling of each goal directory.

## Flow

### Step 1 — Parse arguments

Source `lib/parse_args.md`:

```bash
eval "$(parse_args "$@")"
# Now in scope: $PROMPT, $REQUIREMENTS_DIR, $OUTPUT_DIR
```

If `parse_args` exits non-zero, surface its stderr and stop. Do NOT proceed with defaults — the user invoked the skill incorrectly.

### Step 2 — Load requirements

```bash
REQUIREMENTS_TEXT="$(load_requirements_dir "$REQUIREMENTS_DIR")"
```

Non-fatal for missing directories — empty stdout when the directory does not exist. The agent handles thin or empty requirements text.

### Step 3 — Dispatch create-decomposer in mode=task

Dispatch `create-decomposer` (defined at `stride-lite-copilot/agents/create-decomposer.agent.md`) with:

| Input | Value |
|---|---|
| `prompt` | `$PROMPT` |
| `requirements_text` | `$REQUIREMENTS_TEXT` |
| `mode` | `task` |

The agent returns a single fenced ```yaml document with root shape:

```yaml
kind: task
decomposition_notes: "..."
task:
  title: "..."
  # ... task fields ...
```

Validation gates BEFORE writing the file:

- `kind` MUST equal `task`. A `kind: goal` response is a contract violation by the agent — surface the error and stop. Do NOT fall back to writing a goal directory.
- `task` MUST be present and MUST have non-empty `acceptance_criteria`, `patterns_to_follow`, `pitfalls`, and `testing_strategy`.
- `task` MUST have the four operational keys present as YAML lists: `security_considerations`, `integration_points`, `technology_requirements`, `logging_requirements`. Empty lists are allowed — they render as `- (none)` per the template's empty-value contract — but missing keys are rejected.

### Step 4 — Slugify

```bash
SLUG="$(slugify "$(yq '.task.title' <<<"$YAML")")"
```

Exit on slugify failure (empty input or all-punctuation title).

### Step 5 — Resolve the output path

Use `kind=file, ext=md` with the base joined to `tasks/`:

```bash
TASK_BASE="${OUTPUT_DIR%/}/tasks"
TASK_PATH="$(resolve_output_path "$TASK_BASE" "$SLUG" file md)"
```

The resolver guarantees `$TASK_PATH` does not exist at the moment of return; collision suffixing (`-2`, `-3`, ...) is handled by the helper. Create the parent directory after resolving:

```bash
mkdir -p "$(dirname "$TASK_PATH")"
```

### Step 6 — Render and write the task file

Render the task using the **identical** template from `stride-lite-create-goal/SKILL.md` (the per-task `taskN.md` template). Reproduce the same section order and the same `- (none)` rendering for empty lists. Write to `$TASK_PATH`. Use `[ -e ]` defense — the file must not already exist (the resolver guarantees this, but defense in depth is cheap).

#### Task template (reproduced verbatim from stride-lite-create-goal)

```markdown
# <task.title>

> Type: <task.type> · Complexity: <task.complexity> · Priority: <task.priority>

## Description

<task.description>

## Why

<task.why>

## What

<task.what>

## Where

<task.where_context>

## Acceptance criteria

<task.acceptance_criteria>

## Patterns to follow

<task.patterns_to_follow>

## Pitfalls

- <task.pitfalls[0]>
- <task.pitfalls[1]>
- ...

## Security considerations

- <task.security_considerations[0]>
- <task.security_considerations[1]>
- ...

## Integration points

- <task.integration_points[0]>
- <task.integration_points[1]>
- ...

## Technology requirements

- <task.technology_requirements[0]>
- <task.technology_requirements[1]>
- ...

## Logging requirements

- <task.logging_requirements[0]>
- <task.logging_requirements[1]>
- ...

## Key files

| File | Note |
|---|---|
| `<key_files[0].file_path>` | <key_files[0].note> |
| `<key_files[1].file_path>` | <key_files[1].note> |

## Verification steps

1. **<verification_steps[0].step_type>** — <verification_steps[0].step_text> → expected: <verification_steps[0].expected_result>
2. **<verification_steps[1].step_type>** — <verification_steps[1].step_text> → expected: <verification_steps[1].expected_result>

## Testing strategy

- **Coverage target:** <testing_strategy.coverage_target>
- **Unit tests:**
  - <testing_strategy.unit_tests[0]>
- **Integration tests:**
  - <testing_strategy.integration_tests[0]>
- **Manual tests:**
  - <testing_strategy.manual_tests[0]>
- **Edge cases:**
  - <testing_strategy.edge_cases[0]>
```

**Why reproduce the template here.** If the create-goal skill template is ever extended (an additional field, a reordered section, a different empty-value convention), the same change MUST be applied to this skill in the same commit. Co-locating the template text here makes the divergence detectable in code review rather than discovered later by a confused human comparing two outputs. The two template blocks MUST be byte-equivalent — extract the fenced markdown block from each file and diff them; the diff must be empty.

### Step 7 — Print the result

```
Task written to <TASK_PATH>
```

That is the entire output. The skill does not chain into any follow-up.

## Pitfalls

- **Do not diverge the task template** from the per-task template defined in `stride-lite-create-goal/SKILL.md`. If you find yourself adding a section that doesn't appear in the create-goal task template, stop — make the change in BOTH skills in the same commit.
- **Do not write to `<output-dir>/<slug>/` for single-task mode.** That shape is reserved for goals. The single-task output is always a file at `<output-dir>/tasks/<slug>.md`.
- **Do not hardcode `docs/implementation/PENDING`.** Always route through `$OUTPUT_DIR` after `parse_args`. The `--output-dir` flag MUST work.
- **Do not POST to any API.** No `curl https://...`, no Stride client, no other network call. The skill writes one markdown file and prints a summary.

## Edge cases

- **Empty requirements directory** — `load_requirements_dir` returns empty stdout; the agent decomposes from the prompt alone and notes the absence in `decomposition_notes`. Proceed.
- **Decomposer returns `kind: goal`** — validation gate fails in Step 3; surface a `kind` mismatch error and stop. Do not silently switch to the goal-flow output shape.
- **Slug collides with an existing file** — `resolve_output_path` returns `<slug>-2.md`, `<slug>-3.md`, ... The user is informed via the final stdout print.
- **`--output-dir` points at a non-existent base** — the helper returns the candidate path; the skill `mkdir -p`s `$(dirname "$TASK_PATH")` in Step 5. No special handling needed.
- **`--output-dir` is an absolute path** — supported transparently by `resolve_output_path`.
- **Decomposer output has no fenced `yaml` block** — surface a parser error and stop.
