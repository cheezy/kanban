# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-05-27

### Added

- Initial scaffold for the GitHub Copilot port of [stride-lite](https://github.com/cheezy/stride-lite): `plugin.json`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `LICENSE`, `.gitignore`, and the empty subdirectory tree (`lib/`, `agents/`, `skills/`, `hooks/`, `commands/`, `test/`, `fixtures/`, `docs/`).
- `plugin.json` follows the `stride-copilot` manifest shape (root-level, not `.claude-plugin/plugin.json`), with `name=stride-lite-copilot`, `version=0.1.0`, `license=MIT`, and the `agents` / `skills` / `hooks` pointer fields populated for Copilot's plugin loader.

### Backward compatibility

Initial release — no prior version of stride-lite-copilot exists. Behavior parity with `stride-lite` is the goal of subsequent releases; this 0.1.0 entry only establishes the metadata foundation.

### Source

W923. Scaffold-only release; the `lib/` helpers, `agents/` subagents, `skills/` orchestrators, and `hooks/` enforcement layer are filled in by subsequent tasks (W924 through W932) under goal G200.
