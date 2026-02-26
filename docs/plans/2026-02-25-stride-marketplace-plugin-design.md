# Stride Marketplace Plugin + Streamlined Onboarding

**Date:** 2026-02-25

## Context

A user's Claude Code instance refused to create Stride skill files during onboarding. The onboarding endpoint (`GET /api/agent/onboarding`) returns a large JSON response that instructs Claude to:

1. Write `.stride_auth.md` (contains API token placeholder)
2. Write `.stride.md` (contains executable hook scripts)
3. Write 4 skill files to `~/.claude/skills/`

Claude's safety training flags this as a security risk — fetching remote content and writing it as executable/sensitive files to the user's machine. The refusal occurred at the file-writing step (fetching succeeded).

**The fix:** Publish Stride skills as a proper Claude Code marketplace plugin (a blessed, trusted installation path), and update the onboarding endpoint to provide agent-type-specific instructions instead of embedding ~1,560 lines of skill content.

## Design: Three Deliverables

### Deliverable 1: `cheezy/stride` GitHub Repository (Plugin)

A new public GitHub repo containing the 4 Stride skills as a Claude Code plugin. This is the actual plugin that gets installed.

**Repository structure:**
```
stride/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── stride-claiming-tasks/
│   │   └── SKILL.md
│   ├── stride-completing-tasks/
│   │   └── SKILL.md
│   ├── stride-creating-tasks/
│   │   └── SKILL.md
│   └── stride-creating-goals/
│       └── SKILL.md
├── README.md
└── LICENSE
```

**`.claude-plugin/plugin.json`:**
```json
{
  "name": "stride",
  "description": "Task lifecycle skills for Stride kanban: claiming, completing, creating tasks and goals",
  "version": "1.0.0",
  "author": {
    "name": "Jeff Morgan",
    "email": "<your-email>"
  },
  "homepage": "https://github.com/cheezy/stride",
  "repository": "https://github.com/cheezy/stride",
  "license": "MIT",
  "keywords": ["stride", "kanban", "tasks", "ai-agents", "workflow"]
}
```

**Skill content source:** Extract the 4 skills from the existing installed files at `~/.claude/skills/stride-*/SKILL.md`. These are already fully formed with YAML frontmatter. One modification needed: update the "Handling Stale Skills" sections in `stride-claiming-tasks` and `stride-completing-tasks` to reference `/plugin update stride` instead of re-installing from the onboarding endpoint.

**Stale skills sections to update (in claiming and completing skills):**
```markdown
## Before (current):
**When you see `skills_update_required`:**
1. Call `GET /api/agent/onboarding`
2. Re-install all skills from `claude_code_skills.available_skills`
3. Retry your original action

## After (updated):
**When you see `skills_update_required`:**
1. Run `/plugin update stride` to get the latest skills
2. Retry your original action
```

### Deliverable 2: `cheezy/stride-marketplace` GitHub Repository

A new public GitHub repo that serves as a Claude Code marketplace catalog, following the exact pattern of `obra/superpowers-marketplace`.

**Repository structure:**
```
stride-marketplace/
├── .claude-plugin/
│   └── marketplace.json
├── README.md
└── LICENSE
```

**`.claude-plugin/marketplace.json`:**
```json
{
  "name": "stride-marketplace",
  "owner": {
    "name": "Jeff Morgan",
    "email": "<your-email>"
  },
  "metadata": {
    "description": "Stride task management skills for AI agents",
    "version": "1.0.0"
  },
  "plugins": [
    {
      "name": "stride",
      "source": {
        "source": "url",
        "url": "https://github.com/cheezy/stride.git"
      },
      "description": "Task lifecycle skills for Stride kanban: claiming, completing, creating tasks and goals",
      "version": "1.0.0",
      "strict": true
    }
  ]
}
```

**README.md should include:**
```markdown
# Stride Marketplace

Stride task management skills for AI agents.

## Installation

Add this marketplace to Claude Code:
/plugin marketplace add cheezy/stride-marketplace

## Available Plugins

### Stride
Install:
/plugin install stride@stride-marketplace

What you get:
- stride-claiming-tasks - Proper task claiming with hook execution
- stride-completing-tasks - Proper task completion with validation hooks
- stride-creating-tasks - Comprehensive task specification enforcement
- stride-creating-goals - Goal and batch creation with dependency management
```

### Deliverable 3: Update Onboarding Endpoint in Kanban Project

**File:** `lib/kanban_web/controllers/api/agent_json.ex`

#### Change 1: Replace STEP_7_INSTALL_SKILLS (lines 85-131)

**Current:** Instructions to write 4 skill files to `~/.claude/skills/` using the Write tool.

**Replace with:**
```elixir
STEP_7_INSTALL_SKILLS: %{
  order: 7,
  action: "Install Stride skills plugin",
  condition: "ONLY for Claude Code. Other AI assistants skip this step.",
  if_not_claude_code: "Skip to STEP_8_NOTIFY_USER",
  if_claude_code: "Install the Stride marketplace and plugin using slash commands",
  installation_steps: [
    "1. Run: /plugin marketplace add cheezy/stride-marketplace",
    "2. Run: /plugin install stride@stride-marketplace",
    "3. The 4 Stride skills will be automatically available"
  ],
  verification: "The skills will appear in your skill list automatically after installation",
  note_skills_version: "Plugin version tracks skill versions automatically"
}
```

#### Change 2: Replace claude_code_skills section (lines 279-1841)

**Current:** ~1,560 lines embedding complete skill content as strings in the JSON response.

**Replace with compact reference:**
```elixir
claude_code_skills: %{
  description: "Stride skills are distributed as a Claude Code marketplace plugin.",
  installation:
    "Run these two commands: /plugin marketplace add cheezy/stride-marketplace && /plugin install stride@stride-marketplace",
  plugin_repository: "https://github.com/cheezy/stride",
  marketplace_repository: "https://github.com/cheezy/stride-marketplace",
  skills_included: [
    "stride-claiming-tasks",
    "stride-completing-tasks",
    "stride-creating-tasks",
    "stride-creating-goals"
  ]
}
```

#### Change 3: Update SETUP_COMPLETION_CONFIRMATION (lines 149-163)

Replace the `~/.claude/skills/` file paths with plugin installation confirmation:
```elixir
FILES_THAT_SHOULD_EXIST: [
  ".stride_auth.md (with API token placeholder)",
  ".stride.md (with hook definitions)",
  ".gitignore (containing .stride_auth.md)",
  "Stride plugin installed (Claude Code only - via /plugin install stride@stride-marketplace)"
]
```

#### Change 4: Keep multi_agent_instructions section unchanged

Non-Claude-Code agents (Cursor, Windsurf, Continue, etc.) don't have marketplace support. Their instructions should remain as-is since they still need a way to get skill content.

#### Change 5: Update skills staleness detection

The `skills_update_required` response field should tell Claude Code users to run `/plugin update stride` instead of re-fetching the onboarding endpoint. Check where this is generated (likely in the task controller or a plug) and update the `action` text.

## Implementation Steps

### Step 1: Create `cheezy/stride` repo
```bash
gh repo create cheezy/stride --public --description "Task lifecycle skills for Stride kanban"
```
- Create `.claude-plugin/plugin.json`
- Create `skills/` directory with 4 SKILL.md files (copy from `~/.claude/skills/stride-*/SKILL.md`)
- Update stale skills sections in claiming and completing skills
- Add README.md and LICENSE (MIT)
- Push initial commit

### Step 2: Create `cheezy/stride-marketplace` repo
```bash
gh repo create cheezy/stride-marketplace --public --description "Stride task management skills for AI agents"
```
- Create `.claude-plugin/marketplace.json` pointing to `cheezy/stride.git`
- Add README.md and LICENSE (MIT)
- Push initial commit

### Step 3: Test plugin installation
```bash
# Remove existing local skills
rm -rf ~/.claude/skills/stride-claiming-tasks
rm -rf ~/.claude/skills/stride-completing-tasks
rm -rf ~/.claude/skills/stride-creating-tasks
rm -rf ~/.claude/skills/stride-creating-goals

# Install via marketplace
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace

# Verify skills are available
# Start a new Claude Code session and check skill list
```

### Step 4: Update agent_json.ex
- Apply Changes 1-5 described above
- Run `mix test` to ensure existing tests pass
- Run `mix credo --strict` for code quality

### Step 5: Update CLAUDE.md knowledge base
- Update the "Stride System Knowledge Base" section in `~/.claude/CLAUDE.md` to reference plugin installation instead of manual skill file creation
- Update any references to `~/.claude/skills/stride-*` paths

### Step 6: End-to-end verification
- Start fresh Claude Code session
- Fetch `GET /api/agent/onboarding`
- Verify response no longer contains embedded skill content
- Verify plugin installation instructions are present
- Verify non-Claude-Code agent instructions still work
- Claim and complete a test task to verify full workflow

## Key Files

| File | Action |
|------|--------|
| `lib/kanban_web/controllers/api/agent_json.ex` | Major edit — replace ~1,560 lines |
| `~/.claude/skills/stride-claiming-tasks/SKILL.md` | Source for plugin skill content |
| `~/.claude/skills/stride-completing-tasks/SKILL.md` | Source for plugin skill content |
| `~/.claude/skills/stride-creating-tasks/SKILL.md` | Source for plugin skill content |
| `~/.claude/skills/stride-creating-goals/SKILL.md` | Source for plugin skill content |
| `~/.claude/CLAUDE.md` | Update Stride knowledge base section |

## Reference: Superpowers Marketplace Pattern

This design follows the exact pattern used by `obra/superpowers-marketplace`:

- **Marketplace repo** (`superpowers-marketplace`) contains only `.claude-plugin/marketplace.json` + README
- **Plugin repo** (`superpowers`) contains `.claude-plugin/plugin.json` + `skills/` directory
- **marketplace.json** references plugin repos via `source.url` (GitHub .git URL)
- **Users install with:** `/plugin marketplace add obra/superpowers-marketplace` then `/plugin install superpowers@superpowers-marketplace`
- **Updates via:** `/plugin update superpowers`

## What This Solves

1. **No more security refusal** — `/plugin install` is a blessed Claude Code operation
2. **Version management** — Users get updates via `/plugin update stride`
3. **Smaller onboarding response** — Drops ~1,560 lines of embedded skill content
4. **Cursor compatibility** — Can add `.cursor-plugin/plugin.json` later for Cursor support
5. **Professional distribution** — Users install via documented marketplace commands
