# Stride Lite for Copilot — Agent Guidelines

Project guidelines for AI agents working **on** the stride-lite-copilot plugin codebase (not for agents *using* the plugin's skills — that audience is served by the surface skills' SKILL.md files).

## What this plugin is

A GitHub Copilot CLI plugin that turns a free-text prompt plus an optional requirements directory into Stride-shaped markdown documents on disk, then drives those documents through a file-based task lifecycle. It is the Copilot port of the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin — same on-disk contract, same field discipline, same `.stride_lite.md` config shape, adapted for Copilot's skill activation and hook intercept points. Four skills are planned (the three create/init flows plus the `stride-lite-workflow` orchestrator), three subagents (`create-decomposer`, `task-explorer`, `task-reviewer`), four `lib/` helpers, and a `hooks/` enforcement layer (`hooks.json` + `stride-lite-hook.sh` + `stride-lite-hook.ps1`) registered with Copilot's PreToolUse/PostToolUse harness so the three `.stride_lite.md` hooks auto-fire at the right lifecycle intercept points. There is no kanban server, no claim/complete loop — the `.stride_lite.md` hooks ARE executed (by the Copilot harness) but everything happens locally against the file tree.

## Repository layout

```
stride-lite-copilot/
  plugin.json                    ← Copilot plugin manifest (name, version, license, agents/skills/hooks pointers)
  hooks/
    hooks.json                   ← Copilot PreToolUse/PostToolUse handler registration (cross-platform)
    stride-lite-hook.sh          ← bash executor for macOS/Linux
    stride-lite-hook.ps1         ← PowerShell executor for Windows (behavior-equivalent to .sh)
  skills/
    stride-lite-create-goal/SKILL.md   ← goal-flow orchestrator
    stride-lite-create-task/SKILL.md   ← single-task-flow orchestrator
    stride-lite-init/SKILL.md          ← .stride_lite.md scaffold flow
    stride-lite-workflow/SKILL.md      ← eight-step task lifecycle orchestrator
  agents/
    create-decomposer.agent.md   ← subagent: prompt + requirements + mode → fenced YAML
    task-explorer.agent.md       ← subagent: reads a task file, appends-or-replaces ## Exploration Report section in place
    task-reviewer.agent.md       ← subagent: reads a task file + git diff, appends-or-replaces ## Review Report section in place
  lib/
    parse_args.md                ← extract prompt + --requirements-dir + --output-dir
    load_requirements_dir.md     ← read a directory, concatenate text files
    slugify.md                   ← normalize a title into a filesystem-safe slug
    resolve_output_path.md       ← produce a unique <base>/<slug>(.<ext>)? path
  commands/                      ← (reserved — Copilot has no Claude Code-style slash commands; W929 confirms the final invocation surface)
  test/                          ← smoke.sh end-to-end harness
  fixtures/                      ← sample-requirements.md + expected-output/ for smoke.sh
  docs/                          ← long-form research notes (port-specific, not user-facing)
  README.md                      ← user-facing intro and skill activation reference
  CHANGELOG.md                   ← versioned change log
  AGENTS.md                      ← this file
  LICENSE                        ← MIT
  .gitignore                     ← OS/editor cruft + .stride/ orchestrator marker
```

All `lib/*.md` files document a single pure helper with a Contract table, Spec/Rules, Reference Implementation (bash), Examples, and Edge Cases. The reference implementations are normative — when you ship a runtime that needs an executable helper, transliterate the bash from these docs without renaming functions or changing the exit-code semantics.

**Differences from stride-lite (Claude Code):**

- Manifest is at the repo root (`plugin.json`) instead of `.claude-plugin/plugin.json`.
- `agents/` files use the `.agent.md` extension and Copilot YAML frontmatter (`tools:` array, etc.).
- `commands/` may be empty: Copilot has no Claude Code-style slash commands; skills are activated by matching the user's natural-language prompt against the skill's description block. The final shape of the invocation surface is settled by W929.
- `hooks/hooks.json` uses Copilot's PreToolUse/PostToolUse matcher names (the actual matcher strings may differ from Claude Code's `Agent`/`Edit`/`Write`). W928 documents the chosen intercept points.

## Module boundaries

- **`skills/<name>/SKILL.md` files orchestrate.** They wire `lib/` helpers and the `create-decomposer` subagent together. They never duplicate logic that lives in `lib/`.
- **`agents/<name>.agent.md` files produce structured output.** `create-decomposer` receives a prompt, requirements text, and a `mode` flag, and returns a single fenced ```yaml document. The other two append-or-replace named sections in a target task file. None of them call APIs, ask the user clarifying questions, or have access to a codebase beyond their input.
- **`lib/*.md` files are pure helpers.** Each documents one function. They have no side effects beyond writing to stdout/stderr.

When extending the plugin, add new helpers under `lib/`, new agents under `agents/`, and new skills under `skills/`. Do not move logic across these boundaries.

## Hard rules for agents working on this codebase

- **Never add Stride API calls.** Stride Lite's contract is "no network." If a feature seems to require an API call, it belongs in the full Stride plugin (`stride/` or `stride-copilot/`), not here.
- **Never change the default paths** without coordinating with the README, the surface skills, both create skill files, AND the `stride-lite-workflow` SKILL.md's terminal-move step in the same commit. The two defaults plus the workflow's archive sibling are the cross-skill contract:
  - `--requirements-dir` defaults to `docs/requirements`.
  - `--output-dir` defaults to `docs/implementation/PENDING` (the "in flight" location).
  - `docs/implementation/IMPLEMENTED` (the archive location populated by `stride-lite-workflow`'s terminal PENDING→IMPLEMENTED move at goal close-out, ported from stride-lite v0.10.0). Both `--output-dir` and the archive base must move together if either changes; otherwise the workflow's `/PENDING/` substring substitution breaks silently.
- **Never diverge the task markdown template** between `stride-lite-create-goal/SKILL.md` and `stride-lite-create-task/SKILL.md`. The two skills MUST render task markdown identically. The template is reproduced verbatim in both files so divergence is visible in code review.
- **Never raise the plugin version** without a matching CHANGELOG entry and a `plugin.json` bump in the same commit.
- **Never list more than 8 child tasks in a goal.** The `create-decomposer` agent enforces this cap; downstream tools (the surface skills) reject decomposer output that violates it.
- **Never drift from stride-lite's behavior on the on-disk markdown.** Feature parity means output parity: the smoke test fixtures (`fixtures/sample-requirements.md` + `fixtures/expected-output/`) port from stride-lite verbatim and any divergence requires a documented intentional change in CHANGELOG.

## Conventions

- **All filenames are kebab-case** (`stride-lite-hook.sh`, `task-explorer.agent.md`). The exception is `lib/*.md` files, where snake_case mirrors the bash function name they document.
- **Markdown templates use angle-bracket placeholders** (`<task.title>`, `<key_files[0].file_path>`) — these are documentation, not runnable code. Implementing runtimes substitute the values at render time.
- **Empty values render as `(none)`** rather than disappearing from the output. Reviewability is the goal of the markdown layer.
- **Code fences are language-tagged** (`` ```bash ``, `` ```yaml ``, `` ```markdown ``). Untagged fences are reserved for raw output blocks where no language fits.

## What NOT to add

- **No Elixir/Phoenix-specific guidance.** Stride Lite is project-agnostic. The full Stride plugin has Phoenix conventions baked in; this plugin does not.
- **No multi-harness fallbacks beyond Copilot.** This is the Copilot variant. If a Cursor/Continue/Windsurf path is needed, it belongs in its own sibling plugin (`stride-lite-cursor`, etc.), not bolted onto this one.
- **No server-mediated lifecycle.** stride-lite-copilot has no kanban server, no claim/complete API. The `hooks/` directory holds a Copilot-level enforcement layer (`hooks.json` + `stride-lite-hook.sh` + `stride-lite-hook.ps1`) that auto-fires the three `.stride_lite.md` hooks (`before_task` on subagent dispatch, `after_task` on reviewer dispatch, `after_goal` on the goal.md write that appends `## Completion Summary`). The workflow skill body does not execute hooks directly — the harness does, so the enforcement survives skill amendments.
- **No API client.** A `curl` invocation, a Stride client wrapper, or an HTTP library import is a contract violation. The whole point of this plugin is "no network."
