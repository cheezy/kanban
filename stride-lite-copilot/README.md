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

> **Pending v0.2.0+.** The four planned skills mirror the stride-lite surface: `stride-lite-create-goal`, `stride-lite-create-task`, `stride-lite-init`, and `stride-lite-workflow`. Each is invoked by matching the user's natural-language prompt against the skill's description block. README documentation of the activation phrases lands in v0.2.0+.

## Configuration

> **Pending v0.2.0+.** stride-lite-copilot reads the same `.stride_lite.md` config file as stride-lite — four sections (`email`, `before_task`, `after_task`, `after_goal`), auto-fired at the right lifecycle intercept points by Copilot's hook harness. Setup instructions land in v0.2.0+.

## Migration from stride-lite

> **Pending v0.2.0+.** Users coming from the Claude Code stride-lite plugin can re-use their existing `.stride_lite.md` config; the file shape is identical across both plugins. The differences are in the invocation surface (Copilot has no Claude Code-style slash commands — skills are activated by natural-language prompt instead) and the hook intercept points (Copilot's harness has its own PreToolUse/PostToolUse names). Migration guidance lands in v0.2.0+.

## License

[MIT](LICENSE) — Copyright (c) 2026 Jeff Morgan.
