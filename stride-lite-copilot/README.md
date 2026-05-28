# Stride Lite for GitHub Copilot

> **Scaffold release (v0.1.0).** This is the metadata foundation for the GitHub Copilot port of [stride-lite](https://github.com/cheezy/stride-lite). The skills, agents, and hooks are populated by subsequent releases under goal G200 — see [CHANGELOG.md](CHANGELOG.md).

A lightweight companion plugin to [Stride](https://www.stridelikeaboss.com) — produces Stride-shaped **goal and task markdown documents on disk** from a free-text prompt plus an optional requirements directory. No API calls, no kanban setup, no auth files. Just markdown.

stride-lite-copilot is the GitHub Copilot CLI port of the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin. It provides the same field discipline (acceptance criteria, key files, pitfalls, testing strategy, dependencies) through Copilot's skill and custom-agent systems, with feature parity as the goal.

## Installation

> **Pending v0.2.0+.** Install instructions land once the plugin contents (skills, agents, hooks) are populated.

```bash
copilot plugin install https://github.com/cheezy/stride-lite-copilot
```

## Skills

stride-lite-copilot exposes four skills — invoke them by matching natural-language prompts against the skill description blocks. Copilot has no Claude Code-style slash commands; the agent reads your prompt, matches against the four `SKILL.md` description blocks, and activates the best fit. The descriptions are tuned so the matcher reliably routes user intent to the right skill.

### `stride-lite-create-goal` — decompose a prompt into a multi-task goal directory

Activate when you want to break a free-text initiative into 1–8 ordered, Stride-shaped tasks on disk. Produces `<output-dir>/<slug>/goal.md` + one `taskN.md` per child task.

Activation phrases:

- "Create a Stride-shaped goal for adding real-time notifications."
- "Decompose 'Add board comments' into a goal under docs/implementation/PENDING."
- "Break this initiative into Stride-shaped tasks on disk: <prompt>."
- "Write a goal directory for <prompt> using my docs/requirements docs."

Default flags: `--requirements-dir docs/requirements`, `--output-dir docs/implementation/PENDING`.

### `stride-lite-create-task` — render a single one-off task markdown file

Activate when the work is genuinely one task and a full goal decomposition would be overkill. Produces `<output-dir>/tasks/<slug>.md`.

Activation phrases:

- "Create a single Stride-shaped task for fixing the login button typo."
- "Write a one-off task markdown file: <prompt>."
- "Generate a Stride task spec from this prompt — just one task, no goal."

Same default flags as `stride-lite-create-goal`. The per-task markdown template is byte-identical to the one in the goal flow (enforced by AGENTS.md cross-skill contract).

### `stride-lite-init` — scaffold the `.stride_lite.md` hook config

Activate when you want to create the project-local `.stride_lite.md` config file (four canonical sections: `## email`, `## before_task`, `## after_task`, `## after_goal`). The skill writes the scaffold and prints a success message; it does NOT execute the hook sections itself (that's `stride-lite-workflow`'s job).

Activation phrases:

- "Initialize stride-lite-copilot in this project."
- "Create the `.stride_lite.md` config file."
- "Scaffold the stride-lite hook configuration."
- "Set up the `.stride_lite.md` skeleton — overwrite the existing one if any." (passes `--force`)

Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied.

### `stride-lite-workflow` — drive a goal through the full eight-step lifecycle

Activate ONLY when you supply BOTH (a) explicit intent to work the goal end-to-end AND (b) a path to a goal directory. Without both signals the skill stays dormant — single-task requests and inspection requests should NOT activate it.

Activation phrases (intent + path):

- "Work the docs/implementation/PENDING/add-notifications goal."
- "Drive the add-notifications goal to completion."
- "Resume the add-notifications goal at docs/implementation/PENDING/add-notifications/."
- "Process all tasks in docs/implementation/PENDING/<slug>/."

The workflow iterates each `taskN.md` in numeric order: select-next → `## before_task` hook → dispatch `stride-lite-copilot:task-explorer` → implement → `## after_task` hook → dispatch `stride-lite-copilot:task-reviewer` → review-loop (cap 3) → append `## Completion Summary` → next task. On the final task it also writes the goal-level `## Completion Summary` to `goal.md`, fires `## after_goal`, and moves the directory from `PENDING/` to `IMPLEMENTED/`.

## Configuration

> **Pending v0.2.0+.** stride-lite-copilot reads the same `.stride_lite.md` config file as stride-lite — four sections (`email`, `before_task`, `after_task`, `after_goal`), auto-fired at the right lifecycle intercept points by Copilot's hook harness. Setup instructions land in v0.2.0+.

## Migration from stride-lite

> **Pending v0.2.0+.** Users coming from the Claude Code stride-lite plugin can re-use their existing `.stride_lite.md` config; the file shape is identical across both plugins. The differences are in the invocation surface (Copilot has no Claude Code-style slash commands — skills are activated by natural-language prompt instead) and the hook intercept points (Copilot's harness has its own PreToolUse/PostToolUse names). Migration guidance lands in v0.2.0+.

## License

[MIT](LICENSE) — Copyright (c) 2026 Jeff Morgan.
