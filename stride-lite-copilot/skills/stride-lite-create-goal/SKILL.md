---
name: stride-lite-create-goal
description: Use to turn a user prompt + an optional requirements directory into a written goal directory under `docs/implementation/PENDING/<slug>/` containing one `goal.md` and one `taskN.md` per child task — rendered as readable markdown that mirrors the Stride goal/task field contracts, never POSTed to any API. Activate when the user asks to create a Stride-shaped goal, decompose a prompt into a goal, write a goal directory, or break an initiative into Stride-shaped tasks on disk — optionally with `--requirements-dir <path>` (default `docs/requirements`) or `--output-dir <path>` (default `docs/implementation/PENDING`). Terminal state is the written files; the skill does not push the user toward any follow-up action.
skills_version: "1.0"
---

# stride-lite-create-goal

Surface skill that drives the end-to-end create-goal flow for the stride-lite plugin: parse the invocation, load any requirements text, dispatch the `create-decomposer` subagent in `mode=goal`, slugify, resolve a unique output directory, and write a `goal.md` plus one `taskN.md` per child task. The output is plain markdown intended for human review — this skill never calls the Stride API.

## What this skill does

A single end-to-end run:

```
parse_args  ->  load_requirements_dir  ->  create-decomposer (mode=goal)
            ->  slugify (goal title)    ->  resolve_output_path (kind=dir)
            ->  render goal.md + taskN.md to <output-dir>/<slug>/
```

Every step uses a `lib/` helper or the `create-decomposer` subagent. The skill itself contains no slugification, path-resolution, or arg-parsing logic of its own — it ONLY orchestrates.

## What this skill does NOT do

- **Never POSTs to the Stride API.** Output is plain markdown on disk. The user (or a follow-up tool) decides whether to land the goal in Stride.
- **Never overwrites an existing goal directory.** `resolve_output_path` handles collisions by suffixing `-2`, `-3`, etc.
- **Never asks the user clarifying questions mid-flow.** The prompt and the requirements directory are the entire input. If they are insufficient, the `create-decomposer` agent makes conservative choices and documents them in `decomposition_notes`.
- **Never bypasses the lib/ helpers.** Every step routes through the helper it was designed for so that behavior is independently testable.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `<prompt>` | required | One or more positional args; concatenated by `parse_args`. |
| `--requirements-dir <path>` | `docs/requirements` | Passed verbatim to `load_requirements_dir`. Missing directories are non-fatal. |
| `--output-dir <path>` | `docs/implementation/PENDING` | Passed verbatim to `resolve_output_path` as `base_dir`. The skill `mkdir -p`s the resolved directory before writing. |

## Flow

### Step 1 — Parse arguments

Source the `lib/parse_args.md` contract: pass the full argv to the helper, then eval the three assignment lines it emits:

```bash
eval "$(parse_args "$@")"
# Now in scope: $PROMPT, $REQUIREMENTS_DIR, $OUTPUT_DIR
```

If `parse_args` exits non-zero (missing flag value or empty prompt), surface its stderr to the user and stop. Do NOT proceed with defaults — the user invoked the skill incorrectly.

### Step 2 — Load requirements

Call `load_requirements_dir` with the resolved `$REQUIREMENTS_DIR`:

```bash
REQUIREMENTS_TEXT="$(load_requirements_dir "$REQUIREMENTS_DIR")"
```

`load_requirements_dir` is non-fatal for missing directories — empty stdout when the directory does not exist or contains no readable files. The skill continues either way; the agent handles thin or empty requirements text.

### Step 3 — Dispatch the create-decomposer subagent

Dispatch `create-decomposer` (defined at `stride-lite-copilot/agents/create-decomposer.agent.md`) with three inputs:

| Input | Value |
|---|---|
| `prompt` | `$PROMPT` |
| `requirements_text` | `$REQUIREMENTS_TEXT` |
| `mode` | `goal` |

The agent returns a **single fenced ```yaml document** matching the schema in `create-decomposer.md`. Parse the fenced YAML and reject any output that does not contain exactly one fenced `yaml` block. Required root structure for `mode=goal`:

```yaml
kind: goal
decomposition_notes: "..."
goal:
  title: "..."
  # ... goal fields ...
  tasks:
    - title: "..."
      # ... task fields ...
```

Validation gates BEFORE writing any file:

- `kind` MUST equal `goal`.
- `goal.tasks` MUST have 1 to 8 entries inclusive. If 0 or > 8, surface a parser error and stop.
- Each task MUST have a non-empty `acceptance_criteria`, `patterns_to_follow`, `pitfalls`, and `testing_strategy` (the four review-queue-scored fields).
- Each task MUST have the four operational keys present in the YAML (`security_considerations`, `integration_points`, `technology_requirements`, `logging_requirements`), each as a list. Empty lists are allowed — they render as `- (none)` per the template's empty-value contract — but missing keys are rejected.

If any gate fails, do NOT write files. Surface the validation error to the user with the specific failing task index and field, and stop.

### Step 4 — Slugify

Call `lib/slugify.md` with the goal title:

```bash
SLUG="$(slugify "$(yq '.goal.title' <<<"$YAML")")"
```

If `slugify` exits non-zero (empty input or all-punctuation title), surface the error and stop.

### Step 5 — Resolve the output directory

Call `lib/resolve_output_path.md` with `kind=dir`:

```bash
GOAL_DIR="$(resolve_output_path "$OUTPUT_DIR" "$SLUG" dir)"
```

The helper guarantees `$GOAL_DIR` does not exist at the moment of return. Suffixing (`-2`, `-3`, ...) is handled by the helper. Create the directory after resolving:

```bash
mkdir -p "$GOAL_DIR"
```

### Step 6 — Render and write the goal.md

Render the parsed YAML's `goal` section (minus `tasks`) plus the root-level `decomposition_notes` into the `goal.md` template (defined below). Write to `$GOAL_DIR/goal.md`. Use `set -o noclobber` or `[ -e ]` defense — the file must not already exist (the resolver guarantees the directory is fresh, but defense in depth is cheap).

### Step 7 — Render and write each taskN.md

For each task in `goal.tasks` (index `i`, 0-based), render the task template (defined below) to `$GOAL_DIR/task<N>.md` where `N` is `i + 1` (1-based for human-friendly file names: `task1.md`, `task2.md`, ...).

### Step 8 — Print the result

Print to stdout:

```
Goal written to <GOAL_DIR>/
  goal.md
  task1.md
  task2.md
  ...
```

That is the entire output. The skill does not chain into any follow-up. The user may run a separate tool to POST the directory to Stride; this skill never does.

## Markdown templates

### goal.md template

```markdown
# <goal.title>

## Why

<goal.why>

## What

<goal.what>

## Description

<goal.description>

## Acceptance criteria

<goal.acceptance_criteria>

## Pitfalls

- <goal.pitfalls[0]>
- <goal.pitfalls[1]>
- ...

## Decomposition notes

<decomposition_notes>

## Tasks

1. [<goal.tasks[0].title>](task1.md)
2. [<goal.tasks[1].title>](task2.md)
...
```

The "Tasks" section is a relative-link index so a reviewer can navigate from the goal to each child task and back via the surrounding directory.

### taskN.md template

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

Render-time rules:

- **Empty lists render as `- (none)`** rather than disappearing. A task with no pitfalls renders `## Pitfalls\n\n- (none)`. The four operational sections (`Security considerations`, `Integration points`, `Technology requirements`, `Logging requirements`) follow the same empty-list contract — they always appear in the rendered file, with `- (none)` when their source list is empty.
- **All required fields appear in the rendered file** even when empty. The point of these markdown docs is reviewability — silent omission of a field is worse than printing it empty.

## Pitfalls

- **Do not bypass lib/ helpers.** Every step uses its designated helper so behavior is testable. Inlining slugification, path resolution, or arg parsing into this skill defeats the lib/ split.
- **Do not omit required fields from the markdown templates.** Render every field on the contract — empty values are explicit (`(none)`); silent omission is not.
- **Do not overwrite an existing goal directory.** `resolve_output_path` is the only correct way to pick `$GOAL_DIR`. Direct `mkdir docs/implementation/PENDING/$slug` bypasses the suffix logic.
- **Do not POST to any API.** No `curl https://...`, no Stride API client, no other network call. The skill writes to disk and prints a summary. That is its entire side effect.

## Edge cases

- **Empty requirements directory** — `load_requirements_dir` returns the empty string; the agent decomposes from the prompt alone and notes the absence in `decomposition_notes`. Proceed.
- **Decomposer returns 0 tasks** — validation gate fails in Step 3; surface the error and stop. Do not write a goal directory with no tasks.
- **Decomposer returns more than 8 tasks** — validation gate fails; surface the error citing the agent's own 8-task hard cap from `create-decomposer.md`. Do not truncate silently.
- **Slug collides with existing directory** — `resolve_output_path` returns `<slug>-2`, `<slug>-3`, ... The user is informed via the final stdout print.
- **`--output-dir` points at a non-existent base** — the helper returns the candidate path; the skill `mkdir -p`s `$GOAL_DIR` in Step 5. No special handling needed.
- **`--output-dir` is an absolute path** — supported transparently by `resolve_output_path`.
- **Decomposer output has no fenced `yaml` block** — surface a parser error citing "no fenced yaml block found" and stop. Do not attempt to write files from a malformed agent response.
- **Decomposer output is `kind: task` when `mode=goal` was requested** — surface a `kind` mismatch error and stop. This is the agent's own contract violation.
