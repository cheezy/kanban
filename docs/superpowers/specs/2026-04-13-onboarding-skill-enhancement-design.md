# Design: Enhance Onboarding Endpoint Skills for Cursor, Windsurf, Continue.dev, and Kimi Code

**Date:** 2026-04-13
**Status:** Approved

## Problem

The API onboarding endpoint (`GET /api/agent/onboarding`) provides second-class skill support for Cursor, Windsurf, Continue.dev, and Kimi Code. These four platforms only reference 4 generic Claude Code skills and have no mention of:

- `stride-workflow` (the orchestrator added today)
- `stride-enriching-tasks` or `stride-subagent-workflow`
- The reframed automation notices, claiming gate, or verification checklist

Meanwhile, Copilot, Gemini, OpenCode, and Codex each have dedicated plugins with 6 skills + stride-workflow + 4 agents.

None of the four target platforms support dedicated plugin repos — they all use file-based skill discovery:

| Platform | Discovery Mechanism |
|----------|-------------------|
| Cursor | `.cursor/skills/<name>/SKILL.md` auto-discovery |
| Windsurf | `.windsurf/skills/<name>/SKILL.md` auto-discovery |
| Continue.dev | `.continue/skills/<name>/SKILL.md` (added Jan 2026) |
| Kimi Code | `AGENTS.md` append-mode (always-active instructions) |

## Approach

Host tool-agnostic SKILL.md files in this repo at `docs/multi-agent-instructions/skills/` and update the onboarding endpoint to provide platform-specific download instructions via curl commands.

## File Structure

```
docs/multi-agent-instructions/skills/
  stride-workflow/SKILL.md
  stride-claiming-tasks/SKILL.md
  stride-completing-tasks/SKILL.md
  stride-creating-tasks/SKILL.md
  stride-creating-goals/SKILL.md
  stride-enriching-tasks/SKILL.md
  stride-subagent-workflow/SKILL.md
```

Download URL pattern:
```
https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/<name>/SKILL.md
```

## Skill Content Adaptation

The 7 SKILL.md files are direct copies of the v1.7.0 stride plugin skills with minimal adaptations:

**Frontmatter:** `compatibility` field changed to `cursor, windsurf, continue, kimi`

**Content:** Minimal changes. The existing skills already have dual-path design:
- "Claude Code" path (subagent dispatch, automatic hooks)
- "Other Environments" path (manual exploration, manual hooks)

Cursor, Windsurf, Continue.dev, and Kimi Code agents follow the "Other Environments" path naturally. The only content change is adding "Kimi Code" where skills list "Other Environments (Cursor, Windsurf, Continue)."

The `stride-subagent-workflow` skill is Claude Code-specific but is still included so agents understand the concept even if they can't dispatch subagents.

**AGENTS.md enhancement for Kimi Code:** The existing flat instruction file at `docs/multi-agent-instructions/AGENTS.md` is enhanced with:
- stride-workflow orchestrator steps (condensed)
- Verification checklist (4 items)
- Reframed process-over-speed messaging

## Onboarding Endpoint Changes (`agent_json.ex`)

### Cursor section
- Replace "reference claude_code_skills section" with direct download instructions
- Add `skills_provided` list with all 7 skills
- Add `installation_unix`/`installation_windows` with curl commands for `.cursor/skills/<name>/SKILL.md`
- Remove `reference_section: "claude_code_skills"`

### Windsurf section
- Same as Cursor but paths use `.windsurf/skills/<name>/SKILL.md`
- Remove `reference_section: "claude_code_skills"`

### Continue.dev section
- Add `skills_provided` list with all 7 skills
- Add download instructions for `.continue/skills/<name>/SKILL.md`
- Keep existing `config.json` as supplemental

### Kimi Code section
- Enhanced AGENTS.md with orchestrator guidance, verification checklist, reframed messaging
- Updated description to reflect enhanced content

### Other sections
- `claude_code_skills.skills_included`: updated from 4 to 7 skills
- `memory_strategy.agent_specific_instructions`: Cursor, Windsurf, Kimi entries updated for 7 skills
- `usage_notes`: updated bullet points for all four platforms

## Test Updates

Update `agent_controller_test.exs` to verify:
- Cursor has `skills_provided` with 7 skills and curl-based installation commands
- Windsurf has `skills_provided` with 7 skills and curl-based installation commands
- Continue.dev has `skills_provided` with 7 skills and `.continue/skills/` paths
- Kimi Code description references enhanced content
- `claude_code_skills.skills_included` lists 7 skills
