# Stride Lite for GitHub Copilot

A lightweight companion plugin to [Stride](https://www.stridelikeaboss.com) — produces Stride-shaped **goal and task markdown documents on disk** from a free-text prompt plus an optional requirements directory. No API calls, no kanban setup, no auth files. Just markdown.

stride-lite-copilot is the GitHub Copilot CLI port of the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin. It provides the same field discipline (acceptance criteria, key files, pitfalls, testing strategy, dependencies) through Copilot's skill activation, with feature parity with stride-lite as the goal.

## Installation

Install via the Copilot CLI plugin command:

```bash
copilot plugin install https://github.com/cheezy/stride-lite-copilot
```

### Plugin management

```bash
copilot plugin list                              # confirm stride-lite-copilot is loaded
copilot plugin update stride-lite-copilot        # pull a newer release
copilot plugin uninstall stride-lite-copilot     # remove
```

After install, the four skills (described below) are discoverable by description match. There are no slash commands — type natural-language prompts and the Copilot agent routes them.

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

stride-lite-copilot reads a project-local `.stride_lite.md` config file at the repository root. The file has four canonical sections, each a fenced bash block whose body the harness runs at the corresponding lifecycle point:

```markdown
## email

your-email@example.com

## before_task

```bash
# commands to run before each task (e.g., `git pull origin main`)
```

## after_task

```bash
# commands to run after each task implementation (e.g., `mix test`, `mix format`)
```

## after_goal

```bash
# commands to run when the final task in a goal completes (e.g., `gh pr create`)
```
```

Generate the skeleton by activating `stride-lite-init` (see Skills below) or copy the example above. The `email` section is informational. The three hook sections are auto-fired by the harness via `hooks/hooks.json`:

| Hook | Fires on | Blocking | Purpose |
|---|---|:---:|---|
| `## before_task` | `PreToolUse` + subagent dispatch of `stride-lite-copilot:task-explorer` (Step 3 of the workflow) | yes | Pull latest code, install deps, ensure clean working tree |
| `## after_task` | `PreToolUse` + subagent dispatch of `stride-lite-copilot:task-reviewer` (Step 6) | yes | Run tests / lint / format before the reviewer evaluates the diff |
| `## after_goal` | `PostToolUse` + edit/write on a `goal.md` whose content contains `## Completion Summary` (Step 8) | advisory | Generate a PR, post artifacts, kick off a release pipeline |

You do NOT need `.stride_lite.md` to use the create/init skills — only the `stride-lite-workflow` orchestrator activates the hooks.

> **Copilot CLI hook caveat.** Copilot CLI does not currently emit a skill/agent dispatch event, so `## before_task` and `## after_task` are dormant under Copilot today. The `## after_goal` hook fires correctly via Copilot's edit/create tool matchers. The dormant hooks activate automatically when Copilot adds the equivalent intercept point — no plugin update required.

## Migration from stride-lite

Users coming from the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin can re-use their existing `.stride_lite.md` config — the file shape is byte-identical across both plugins.

Differences to expect:

- **No slash commands.** Claude Code stride-lite ships `/stride-lite:create-goal`, `/stride-lite:create-task`, `/stride-lite:init`. Copilot has no equivalent surface. Replace those slash calls with the natural-language activation phrases in the Skills section below.
- **Subagent identities renamed.** Cross-references in `.stride_lite.md` hooks, in your own scripts, or in CI to `stride-lite:task-explorer` / `stride-lite:task-reviewer` need to be renamed to `stride-lite-copilot:task-explorer` / `stride-lite-copilot:task-reviewer` for the Copilot port. The `.stride_lite.md` hook sections themselves are agnostic to the plugin name and need no change.
- **`hooks/hooks.json` matchers.** stride-lite uses Claude Code matcher names (`Agent`, `Edit`, `Write`); stride-lite-copilot adds the Copilot lowercase forms via regex alternation (`Edit|edit`, `Write|create`). Both runtimes are covered by the same hooks.json.
- **Dormant before_task/after_task on Copilot.** See the Copilot CLI hook caveat above. Under Claude Code these still fire normally.

The on-disk artifacts produced by both plugins (goal directories, task markdown files, the embedded task template) are byte-identical — a goal directory created by stride-lite can be driven by `stride-lite-copilot:stride-lite-workflow` and vice versa.

## License

[MIT](LICENSE) — Copyright (c) 2026 Jeff Morgan.
