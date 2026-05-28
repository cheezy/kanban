# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-05-27

### Added

- Initial scaffold for the GitHub Copilot port of [stride-lite](https://github.com/cheezy/stride-lite): `plugin.json`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `LICENSE`, `.gitignore`, and the empty subdirectory tree (`lib/`, `agents/`, `skills/`, `hooks/`, `test/`, `fixtures/`, `docs/`).
- `plugin.json` follows the `stride-copilot` manifest shape (root-level, not `.claude-plugin/plugin.json`), with `name=stride-lite-copilot`, `version=0.1.0`, `license=MIT`, and the `agents` / `skills` / `hooks` pointer fields populated for Copilot's plugin loader.
- Four skills (`stride-lite-create-goal`, `stride-lite-create-task`, `stride-lite-init`, `stride-lite-workflow`), three subagents (`create-decomposer.agent.md`, `task-explorer.agent.md`, `task-reviewer.agent.md`), four `lib/` markdown helpers, and a `hooks/` enforcement layer (`hooks.json` + `stride-lite-copilot-hook.sh` + `stride-lite-copilot-hook.ps1`) ported from stride-lite under W924–W928.

### Removed

- No `commands/` directory. GitHub Copilot CLI has no Claude Code-style slash command surface; skill activation is done by natural-language prompt matching against the four `SKILL.md` description blocks. README documents the activation phrases for each skill.

### Backward compatibility

Initial release — no prior version of stride-lite-copilot exists. Behavior parity with `stride-lite` is the goal of subsequent releases; this 0.1.0 entry only establishes the metadata foundation.

### Source

W923–W929 under goal G200. Tasks W930 (smoke tests + hook test harness), W931 (README/AGENTS/CHANGELOG finalization for the Copilot CLI install + migration story), and W932 (GitHub repo creation + marketplace decision) follow.
