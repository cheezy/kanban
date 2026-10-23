# Stride Development Guidelines

This file used to hold a second copy of the development-guidelines skill. The
two copies drifted apart, and this one ended up contradicting both the skill
agents load and the dark-mode contract. It now only points at the sources that
are kept current.

- **The skill.**
  [`.claude/skills/stride-development-guidelines/SKILL.md`](../../../.claude/skills/stride-development-guidelines/SKILL.md)
  is the version Claude Code loads. [CLAUDE.md](../../../CLAUDE.md) requires it
  before any edit in `lib/`, `test/` or `assets/`, and that includes work on a
  task claimed from the Stride API.
- **The standards it enforces.** [AGENTS.md](../../../AGENTS.md) holds the
  module design, UI, dark-mode, quality and security rules.
- **Colours and borders.** The [Dark Mode Contract](../../dark-mode-contract.md)
  owns the token table. Form-control borders use `var(--line-input)`, either
  through `<.input>` or inline; see
  [Form-control borders](../../dark-mode-contract.md#form-control-borders). Dimmed
  text uses `var(--ink-2)` or `var(--ink-3)` rather than an opacity utility.

## What `mix precommit` runs

The `precommit` alias in `mix.exs` runs these steps:

1. `compile --warning-as-errors`
2. `deps.unlock --unused`
3. `format`
4. `gettext.extract --check-up-to-date`
5. `dark_mode.scan`
6. `dark_mode.contrast --enforce`
7. `test`
8. `credo --strict`

It does **not** run the security audits, `sobelow` or coverage, so run those
separately:

- `mix deps.audit`, `mix hex.audit` and `mix hex.outdated` after you add or
  update a dependency.
- `mix sobelow --config` and `mix test --cover`. The `/precommit` slash command
  in `.claude/commands/precommit.md` runs both of them.
