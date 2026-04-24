# Multi-Agent Instructions

*Last Updated: April 24, 2026*

## Overview

Stride provides enhanced integration support for multiple AI coding assistants beyond Claude Code. While Claude Code uses contextual Skills for workflow enforcement, other AI assistants receive always-active code completion guidance through their native configuration formats.

**Core Principle:** Share Claude Code Skills across compatible platforms (GitHub Copilot, Cursor, Windsurf, Gemini, OpenCode, Codex CLI), and provide always-active code completion guidance for other AI assistants.

**Supported AI Assistants:** Claude Code (Skills), GitHub Copilot (Skills), Cursor (Skills), Windsurf (Skills), Gemini Code Assist (Skills), OpenCode (Skills), Codex CLI (Skills), Continue.dev, Kimi Code CLI (k2.5)

## Architecture

### Two-Tier Approach

**Claude Code Skills** (Contextual):
- Activate only when relevant (claiming, completing, creating tasks)
- Enforce workflow discipline with blocking validation
- Comprehensive content (1000+ lines per skill)
- Distributed via onboarding endpoint with embedded content

**Multi-Agent Instructions** (Always-Active):
- Guide code completion and inline suggestions
- Remind about critical validation rules
- Provide code patterns for common operations
- Concise content (200-400 lines due to token limits)
- Distributed as downloadable files from docs directory

### Benefits of This Approach

1. **Specialized for Each Assistant**: Each format optimized for its specific platform
2. **Token-Efficient**: Agents download only what they need
3. **Better Caching**: Separate files cached independently
4. **Easy Updates**: Update individual formats without changing entire endpoint
5. **Consistent Distribution**: All formats served from same GitHub docs directory

## Supported AI Assistants (7 Skills-Based + 2 Always-Active)

> Skills-based: Claude Code, GitHub Copilot, Cursor, Windsurf, Gemini CLI, OpenCode, Codex CLI. Always-active: Continue.dev, Kimi Code CLI.

### 1. Claude Code

**Installation Method:** Stride Marketplace Plugin

**Scope:** On-demand skill loading (invoked when needed)

**Skills Provided:** `stride-workflow` (recommended entry point), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`

> **🔌 REQUIRED: Install the Stride plugin from the marketplace.** Do NOT manually download skill files for Claude Code — use the plugin instead. The plugin provides the most up-to-date skills and is the only supported installation method. The `stride-workflow` orchestrator is the recommended entry point for all task work.

**Installation:**
```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

**Verify installation** by checking that Stride skills (e.g., `stride-claiming-tasks`, `stride-completing-tasks`) appear in your available skills list.

**IMPORTANT:** Claude Code users must install the Stride plugin rather than manually downloading skill files. The plugin manages skill installation, updates, and versioning automatically. Manual `.claude/skills/` downloads are for other compatible tools (GitHub Copilot, Cursor, OpenCode) that don't support the plugin system.

### 2. GitHub Copilot

**Installation Method:** Stride Copilot Plugin (via `copilot plugin install`)

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** `stride-workflow` (recommended entry point), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `hook-diagnostician`

> **🔌 RECOMMENDED: Install the Stride Copilot plugin.** This provides 7 skills (including the `stride-workflow` orchestrator) and 4 custom agents. The `stride-workflow` skill walks through the complete lifecycle in a single skill.

**Installation:**

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

**Plugin management:**

```bash
copilot plugin update stride-copilot       # Update to latest version
copilot plugin uninstall stride-copilot    # Remove plugin
copilot plugin list                        # View installed plugins
```

**IMPORTANT:** The stride-copilot plugin provides Copilot-adapted versions of all Stride skills with tool-agnostic language (no Claude Code-specific tool references). The plugin system handles skill and agent discovery automatically. For manual installation as a fallback, see the Manual Installation section below.

### 3. Cursor

**Files:** Multiple focused skills (4 total)

**Location:** `docs/multi-agent-instructions/SKILL.md`

**Compatible Tools:** Cursor, Claude Code

**Scope:** On-demand skill loading (invoked when needed)

**Token Limit:** ~2000-3000 tokens per skill (~100-150 lines each)

**Format:** YAML frontmatter + Markdown content

**Skills:**

1. **stride-creating-tasks** - Use when creating new Stride tasks or defects
2. **stride-completing-tasks** - Use when completing tasks and marking them done
3. **stride-claiming-tasks** - Use when claiming tasks from Stride boards
4. **stride-creating-goals** - Use when creating goals with nested tasks

**Download:**
```bash
# Create all skill directories and download (Claude-compatible paths)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .claude/skills/$skill
  curl -o .claude/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**IMPORTANT:** Cursor and Claude Code use a skill-based system for on-demand instruction loading. Skills are reusable instruction sets with YAML frontmatter metadata. The skill name (e.g., `stride-creating-tasks`) must match the directory name. Cursor automatically discovers skills in `.claude/skills/` (and `.cursor/skills/` or `.codex/skills/`) directories, making them compatible across both platforms. See [Cursor Skills Documentation](https://cursor.com/docs/context/skills) for details.

### 4. Windsurf Cascade

**Files:** Multiple focused skills (4 total)

**Location:** `docs/multi-agent-instructions/SKILL.md`

**Compatible Tools:** Windsurf, Claude Code

**Scope:** On-demand skill loading (invoked when needed)

**Token Limit:** ~2000-3000 tokens per skill (~100-150 lines each)

**Format:** YAML frontmatter + Markdown content

**Skills:**

1. **stride-creating-tasks** - Use when creating new Stride tasks or defects
2. **stride-completing-tasks** - Use when completing tasks and marking them done
3. **stride-claiming-tasks** - Use when claiming tasks from Stride boards
4. **stride-creating-goals** - Use when creating goals with nested tasks

**Download:**
```bash
# Create all skill directories and download (Windsurf-compatible paths)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .windsurf/skills/$skill
  curl -o .windsurf/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**IMPORTANT:** Windsurf and Claude Code use a skill-based system for on-demand instruction loading. Skills are reusable instruction sets with YAML frontmatter metadata. The skill name (e.g., `stride-creating-tasks`) must match the directory name. Windsurf automatically discovers skills in `.windsurf/skills/` directories, making them compatible with Claude Code. See [Windsurf Skills Documentation](https://docs.windsurf.com/windsurf/cascade/skills) for details.

### 5. Continue.dev

**File:** `.continue/config.json`

**Location:** `docs/multi-agent-instructions/continue-config.json`

**Scope:** Project-scoped JSON with context providers

**Token Limit:** Flexible (~100 lines JSON)

**Format:** JSON configuration with custom commands

**Download:**
```bash
mkdir -p .continue
curl -o .continue/config.json \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json
```

**Focus:**
- System message with core validation rules
- Custom context provider pointing to Stride documentation
- Custom slash commands for common workflows
- Can reference external documentation files

### 6. Google Gemini CLI

**Installation Method:** Stride Gemini Extension (install from GitHub)

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** `stride-workflow` (recommended entry point), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `hook-diagnostician`

> **🔌 RECOMMENDED: Install the Stride Gemini extension.** This provides 7 skills (including the `stride-workflow` orchestrator) and 4 custom agents. The `stride-workflow` skill walks through the complete lifecycle in a single skill.

**Installation:**

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

**Verify installation** by checking that Stride skills (e.g., `stride-claiming-tasks`, `stride-completing-tasks`) appear in your available skills list and custom agents (e.g., `task-explorer`, `task-reviewer`) are accessible.

**IMPORTANT:** The stride-gemini extension provides Gemini-adapted versions of all Stride skills with Gemini CLI tool names (grep_search, read_file, glob, etc.). It also includes a `GEMINI.md` bridge file that ensures Gemini reliably activates the right skill at each workflow point. For manual installation as a fallback, see the Manual Installation section below.

### 7. OpenCode

**Files:** Multiple focused skills (4 total)

**Location:** `docs/multi-agent-instructions/SKILL.md`

**Compatible Tools:** OpenCode, Claude Code

**Scope:** On-demand skill loading (invoked when needed)

**Token Limit:** ~2000-3000 tokens per skill (~100-150 lines each)

**Format:** YAML frontmatter + Markdown content

**Skills:**

1. **stride-creating-tasks** - Use when creating new Stride tasks or defects
2. **stride-completing-tasks** - Use when completing tasks and marking them done
3. **stride-claiming-tasks** - Use when claiming tasks from Stride boards
4. **stride-creating-goals** - Use when creating goals with nested tasks

**Download:**
```bash
# Create all skill directories and download (Claude-compatible paths)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .claude/skills/$skill
  curl -o .claude/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Windows (PowerShell):**
```powershell
# Create all skill directories and download (Claude-compatible paths)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .claude/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .claude/skills/$_/SKILL.md
}
```

**Alternative Locations:**
- Project-local: `.claude/skills/<skill-name>/SKILL.md` (recommended, works with both Claude Code and OpenCode)
- OpenCode-specific: `.opencode/skills/<skill-name>/SKILL.md` (OpenCode only)
- Global: `~/.config/opencode/skills/<skill-name>/SKILL.md` or `~/.claude/skills/<skill-name>/SKILL.md` (all projects)

**IMPORTANT:** OpenCode and Claude Code use a skill-based system for on-demand instruction loading. Skills are reusable instruction sets with YAML frontmatter metadata. The skill name (e.g., `stride-creating-tasks`) must match the directory name. OpenCode automatically discovers skills in both `.claude/skills/` and `.opencode/skills/` directories, making them compatible across both platforms. See [OpenCode Skills Documentation](https://opencode.ai/docs/skills/) for details.

**Focus:**
- Multiple focused skills instead of single monolithic skill (follows Claude Code pattern)
- On-demand loading reduces token usage (not always-active)
- YAML frontmatter with structured metadata
- Hierarchical skill discovery (project → global → .claude)
- Each skill focuses on specific workflow (creating, claiming, completing, goals)
- Compatible with both Claude Code and OpenCode via .claude/skills/ path
- Detailed code patterns with Markdown formatting per skill
- Comprehensive mistake catalog distributed across relevant skills

### 8. Codex CLI

**Installation Method:** Stride Codex Plugin (install script from GitHub)

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** `stride-workflow` (recommended entry point), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `hook-diagnostician`

> **🔌 RECOMMENDED: Install the Stride Codex plugin.** This provides 7 skills (including the `stride-workflow` orchestrator) and 4 custom agents. The `stride-workflow` skill walks through the complete lifecycle in a single skill.

**Installation (global — applies to all projects):**

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash
```

**Installation (current project only):**

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project
```

**Manual installation:**

```bash
git clone https://github.com/cheezy/stride-codex.git
cp -r stride-codex/skills/ .agents/skills/
cp -r stride-codex/agents/ .agents/agents/
cp stride-codex/AGENTS.md AGENTS.md
```

**Verify installation** by checking that Stride skills (e.g., `stride-claiming-tasks`, `stride-completing-tasks`) appear in your available skills list and custom agents (e.g., `task-explorer`, `task-reviewer`) are discoverable.

**Skill discovery paths:** Codex CLI discovers skills in `.agents/skills/<name>/SKILL.md` or `.codex/skills/<name>/SKILL.md`, and agents in `.agents/agents/<name>.md`.

**IMPORTANT:** Codex CLI has no automatic hook interception. The agent executes `.stride.md` hooks directly by reading the file and running each command via shell, one command at a time. The Stride skills provide the exact execution pattern. For manual installation as a fallback, see the Manual Installation section below.

### 9. Kimi Code CLI (k2.5)

**File:** `AGENTS.md`

**Location:** `docs/multi-agent-instructions/AGENTS.md`

**Compatible Tools:** Kimi Code CLI (k2.5)

**Scope:** Project-scoped, always-active (append-mode)

**Token Limit:** ~8000-10000 tokens (~400-500 lines)

**Format:** Markdown

**Download:**
```bash
# If AGENTS.md exists, append Stride instructions
echo '\n\n# === Stride Integration Instructions ===' >> AGENTS.md
curl -s https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md

# If AGENTS.md doesn't exist, create it
curl -o AGENTS.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md
```

**Windows (PowerShell):**
```powershell
# If AGENTS.md exists, append Stride instructions
"`n`n# === Stride Integration Instructions ===" | Add-Content AGENTS.md
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" | Select-Object -ExpandProperty Content | Add-Content AGENTS.md

# If AGENTS.md doesn't exist, create it
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" -OutFile AGENTS.md
```

**Alternative Locations:**
- Project root: `./AGENTS.md` (project-specific)
- Append-mode: Content added to existing AGENTS.md

**IMPORTANT:** Kimi Code CLI (k2.5) uses AGENTS.md for always-active instructions. If you have existing content in AGENTS.md, use append-mode to add Stride instructions. The file is loaded automatically when Kimi starts.

**Focus:**
- Always-active instructions (loaded on startup)
- Append-mode for merging with existing content
- Detailed code patterns with Markdown formatting
- Comprehensive mistake catalog
- Hook execution details
- No manual invocation needed

## Content Strategy

### Core Content (All Formats)

All seven instruction formats cover the same essential topics:

1. **Hook Execution Mandate**
   - All four hooks and their purpose
   - Blocking vs non-blocking behavior
   - Execute after_doing BEFORE calling complete endpoint

2. **Top 5 Critical Mistakes**
   - Don't specify identifiers when creating tasks
   - verification_steps must be array of objects, not strings
   - testing_strategy fields must be arrays
   - type must be exactly "work", "defect", or "goal"
   - Execute after_doing hook before calling completion endpoint

3. **Essential Field Requirements**
   - key_files prevents merge conflicts
   - dependencies control execution order
   - testing_strategy must have arrays for unit/integration/manual tests
   - verification_steps as objects with step_type, step_text, expected_result

4. **Code Patterns**
   - Claiming a task with hook execution
   - Completing a task with validation
   - Creating a task with all required fields
   - Creating goals with nested tasks
   - Batch creation of multiple goals

5. **Documentation Links**
   - Onboarding endpoint URL
   - Task Writing Guide URL
   - API Reference URL
   - Hook Execution Guide URL

6. **Completion Validation Requirements (G65)**
   - `explorer_result` required on every `/complete` call — dispatched-subagent shape or self-reported skip with enum reason
   - `reviewer_result` required on every `/complete` call — same two shapes as `explorer_result`
   - `workflow_steps` required on every `/complete` call — six-entry telemetry array (one per phase)
   - Skip-reason enum: `no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`
   - 40-character non-whitespace minimum on `summary` fields
   - Rolling out via `:strict_completion_validation` feature flag (currently grace mode, 422 rejection once flipped)

### Format-Specific Adaptations

**GitHub Copilot (YAML + Markdown Skills):**
- YAML frontmatter with structured metadata
- Rich formatting with headings, lists, code blocks in body
- Skill-based on-demand loading reduces token usage
- Installed in .claude/skills/<skill-name>/ directories
- Claude-compatible (shared skill system)
- Automatic skill discovery

**Cursor (YAML + Markdown Skills):**
- YAML frontmatter with structured metadata
- Rich formatting with headings, lists, code blocks in body
- Skill-based on-demand loading reduces token usage
- Installed in .claude/skills/<skill-name>/ (or .cursor/skills/ or .codex/skills/) directories
- Claude-compatible (shared skill system)
- Automatic skill discovery

**Windsurf (YAML + Markdown Skills):**
- YAML frontmatter with structured metadata
- Rich formatting with headings, lists, code blocks in body
- Skill-based on-demand loading reduces token usage
- Installed in .windsurf/skills/<skill-name>/ directories
- Claude-compatible (shared skill system)
- Automatic skill discovery

**Continue.dev (JSON):**
- System message with core rules
- Custom context provider for external docs
- Can reference documentation files directly

**Gemini CLI (Extension with Skills + Custom Agents):**
- YAML frontmatter with name and description fields
- Rich formatting with headings, lists, code blocks in body
- 6 skills + 4 custom agents via stride-gemini extension
- Custom agents for exploration, review, decomposition, and diagnostics
- GEMINI.md bridge file for reliable skill activation
- Installed via `gemini extensions install https://github.com/cheezy/stride-gemini`

**OpenCode (YAML + Markdown):**
- YAML frontmatter with structured metadata
- Rich formatting with headings, lists, code blocks in body
- Skill-based on-demand loading reduces token usage
- Similar depth to Cursor/Windsurf/Gemini formats
- Installed in .opencode/skills/stride/ or ~/.config/opencode/skills/stride/
- Claude-compatible via .claude/skills/stride/ path

**Codex CLI (Plugin with Skills + Custom Agents):**
- YAML frontmatter with name and description fields
- Rich formatting with headings, lists, code blocks in body
- 7 skills + 4 custom agents via stride-codex plugin
- Custom agents for exploration, review, decomposition, and diagnostics
- Installed via `curl -fsSL .../install.sh | bash` (global or `--project`)
- Discovered in `.agents/skills/` or `.codex/skills/` (agents in `.agents/agents/`)
- Manual hook execution — no automatic interception in Codex CLI

**Kimi Code CLI (k2.5) (Markdown):**
- Always-active instructions loaded on startup
- Append-mode for merging with existing AGENTS.md content
- Rich formatting with headings, lists, code blocks
- Similar depth to Cursor/Windsurf/Gemini/OpenCode formats
- Installed in project root: ./AGENTS.md
- No manual invocation needed

## Distribution Architecture

### Onboarding Endpoint Structure

The `/api/agent/onboarding` endpoint includes the `multi_agent_instructions` section:

```json
{
  "version": "1.0",
  "api_base_url": "https://www.stridelikeaboss.com",
  "claude_code_skills": { ... },
  "multi_agent_instructions": {
    "description": "Always-active code completion guidance...",
    "note": "Claude Code users should use claude_code_skills above...",
    "formats": {
      "copilot": {
        "file_path": ".claude/skills/<skill-name>/SKILL.md (4 skills total)",
        "description": "GitHub Copilot automatically discovers Claude Code skills",
        "compatible_tools": ["GitHub Copilot", "Claude Code"],
        "reference_section": "claude_code_skills",
        "note": "GitHub Copilot automatically discovers skills in .claude/skills/ directories...",
        "installation_unix": "# GitHub Copilot users: Use Claude Code skill installation...",
        "installation_windows": "# GitHub Copilot users: Use Claude Code skill installation...",
        "token_limit": "~2000-3000 tokens per skill (~100-150 lines each)"
      },
      ...
    }
  }
}
```

### File Locations

All multi-agent instruction files are stored in:
```
docs/multi-agent-instructions/
├── SKILL.md                   # 9KB (shared by Windsurf, Cursor, GitHub Copilot, Gemini, Claude Code, OpenCode)
├── continue-config.json       # 4KB
└── AGENTS.md                  # 15KB (Kimi Code CLI k2.5)
```

Total size: ~28KB of instruction content

### Endpoint Optimization

**Before optimization:**
- Onboarding endpoint: 132KB
- All instruction content embedded in JSON

**After optimization:**
- Onboarding endpoint: 79KB (40% reduction)
- Instructions served as separate downloadable files
- Agents download only what they need

## Installation for Developers

### Automatic Installation (Recommended)

When AI agents fetch the onboarding endpoint, they should automatically download the appropriate instruction file based on their type:

1. Agent fetches `/api/agent/onboarding`
2. Agent identifies its type (Copilot, Cursor, Windsurf, Continue.dev, Gemini, OpenCode, Codex CLI, Kimi)
3. Agent extracts the `download_url` for its format
4. Agent executes the appropriate `installation_unix` or `installation_windows` command
5. Instruction file is placed in the correct location
   - For OpenCode: Creates `.opencode/skills/stride/` directory structure
   - For Kimi: Appends to existing AGENTS.md or creates new file

### Manual Installation

Developers can manually download instruction files. **IMPORTANT:** These commands will overwrite existing configuration files. If you have existing custom configurations, consider backing them up first or manually merging the Stride instructions.

**Check for existing files first:**
```bash
# Check which files already exist
ls -la .continue/config.json AGENTS.md 2>/dev/null
ls -la .claude/skills/stride-*/SKILL.md .windsurf/skills/stride-*/SKILL.md .gemini/skills/stride-*/SKILL.md 2>/dev/null
```

**Backup existing files (recommended):**
```bash
# Backup existing configuration before installing
[ -f .continue/config.json ] && cp .continue/config.json .continue/config.json.backup
[ -f AGENTS.md ] && cp AGENTS.md AGENTS.md.backup
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  [ -f .claude/skills/$skill/SKILL.md ] && cp .claude/skills/$skill/SKILL.md .claude/skills/$skill/SKILL.md.backup
  [ -f .windsurf/skills/$skill/SKILL.md ] && cp .windsurf/skills/$skill/SKILL.md .windsurf/skills/$skill/SKILL.md.backup
  [ -f .gemini/skills/$skill/SKILL.md ] && cp .gemini/skills/$skill/SKILL.md .gemini/skills/$skill/SKILL.md.backup
done
```

**Download Stride instructions:**

**GitHub Copilot (Recommended — use the plugin):**

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

> This installs the full set of 6 skills + 4 custom agents. See [Section 2: GitHub Copilot](#2-github-copilot) for details.

**GitHub Copilot (Fallback — manual download of 4 generic skills):**

```bash
# Install 4 basic Stride skills (project-local, .github/skills/ paths)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .github/skills/$skill
  curl -o .github/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Cursor:**
```bash
# Install all 4 Stride skills (project-local, Claude-compatible)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .claude/skills/$skill
  curl -o .claude/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Windsurf:**
```bash
# Install all 4 Stride skills (project-local, Windsurf-compatible)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .windsurf/skills/$skill
  curl -o .windsurf/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Continue.dev:**
```bash
mkdir -p .continue
curl -o .continue/config.json \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json
```

**Google Gemini CLI (Recommended — use the extension):**

> Install the stride-gemini extension for the full set of 6 skills + 4 custom agents. See [Section 6: Google Gemini CLI](#6-google-gemini-cli) for instructions.

**Google Gemini CLI (Fallback — manual download of 4 generic skills):**

```bash
# Install 4 basic Stride skills (Gemini-compatible paths)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .gemini/skills/$skill
  curl -o .gemini/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

For user-level installation (applies to all projects):
```bash
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p ~/.gemini/skills/$skill
  curl -o ~/.gemini/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Claude Code:**

> Claude Code users should install the Stride plugin instead of manually downloading skills. See [Section 1: Claude Code](#1-claude-code) for plugin installation instructions.

**OpenCode:**
```bash
# Install all 4 Stride skills (project-local, Claude-compatible)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p .claude/skills/$skill
  curl -o .claude/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

For global installation (applies to all projects):
```bash
# Global installation (works with OpenCode)
for skill in stride-creating-tasks stride-completing-tasks stride-claiming-tasks stride-creating-goals; do
  mkdir -p ~/.claude/skills/$skill
  curl -o ~/.claude/skills/$skill/SKILL.md \
    https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md
done
```

**Codex CLI (Recommended — use the plugin):**

```bash
# Global install (all projects)
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash

# Or project-local install
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project
```

> This installs the full set of 7 skills + 4 custom agents. See [Section 8: Codex CLI](#8-codex-cli) for details.

**Kimi Code CLI (k2.5):**
```bash
# If AGENTS.md exists, append Stride instructions
echo '\n\n# === Stride Integration Instructions ===' >> AGENTS.md
curl -s https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md

# If AGENTS.md doesn't exist, create it
curl -o AGENTS.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md
```

**Merging with existing configuration:**

If you have existing custom instructions, you may want to manually merge them:

1. **For skill-based formats like GitHub Copilot/Cursor/Windsurf/Gemini/OpenCode**, skills are stored in separate directories and don't conflict with existing configuration. **Claude Code users** should use the Stride plugin instead (see [Section 1](#1-claude-code))

2. **For Continue.dev (JSON)**, manually merge the Stride instructions into your existing `.continue/config.json` file

### Windows Installation

**PowerShell:**

**IMPORTANT:** These commands will overwrite existing files. Back up first if you have custom configurations.

**Check for existing files:**
```powershell
Get-Item .continue/config.json, AGENTS.md -ErrorAction SilentlyContinue
Get-Item .claude/skills/stride-*/SKILL.md, .windsurf/skills/stride-*/SKILL.md, .gemini/skills/stride-*/SKILL.md -ErrorAction SilentlyContinue
```

**Backup existing files (recommended):**
```powershell
if (Test-Path .continue/config.json) { Copy-Item .continue/config.json .continue/config.json.backup }
if (Test-Path AGENTS.md) { Copy-Item AGENTS.md AGENTS.md.backup }
foreach ($skill in @('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals')) {
  if (Test-Path .claude/skills/$skill/SKILL.md) { Copy-Item .claude/skills/$skill/SKILL.md .claude/skills/$skill/SKILL.md.backup }
  if (Test-Path .windsurf/skills/$skill/SKILL.md) { Copy-Item .windsurf/skills/$skill/SKILL.md .windsurf/skills/$skill/SKILL.md.backup }
  if (Test-Path .gemini/skills/$skill/SKILL.md) { Copy-Item .gemini/skills/$skill/SKILL.md .gemini/skills/$skill/SKILL.md.backup }
}
```

**Download Stride instructions:**
```powershell
# GitHub Copilot: Use the plugin (recommended)
# copilot plugin install https://github.com/cheezy/stride-copilot

# GitHub Copilot (fallback — manual download of 4 generic skills)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .github/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .github/skills/$_/SKILL.md
}

# Cursor (skill-based installation)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .claude/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .claude/skills/$_/SKILL.md
}

# Windsurf (skill-based installation)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .windsurf/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .windsurf/skills/$_/SKILL.md
}

# Continue.dev
New-Item -ItemType Directory -Force -Path .continue
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json" -OutFile .continue/config.json

# Google Gemini CLI: Use the extension (recommended)
# gemini extensions install https://github.com/cheezy/stride-gemini

# Google Gemini CLI (fallback — manual download of 4 generic skills)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .gemini/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .gemini/skills/$_/SKILL.md
}

# For user-level installation (applies to all projects)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.gemini\skills\$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile $env:USERPROFILE\.gemini\skills\$_\SKILL.md
}

# Claude Code: Use the plugin instead (see Section 1: Claude Code)
# /plugin marketplace add cheezy/stride-marketplace
# /plugin install stride@stride-marketplace

# OpenCode (skill-based installation)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path .claude/skills/$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile .claude/skills/$_/SKILL.md
}

# For global installation (works with OpenCode)
@('stride-creating-tasks', 'stride-completing-tasks', 'stride-claiming-tasks', 'stride-creating-goals') | ForEach-Object {
  New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.claude\skills\$_
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/SKILL.md" -OutFile $env:USERPROFILE\.claude\skills\$_\SKILL.md
}

# Kimi Code CLI (k2.5)
# If AGENTS.md exists, append Stride instructions
"`n`n# === Stride Integration Instructions ===" | Add-Content AGENTS.md
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" | Select-Object -ExpandProperty Content | Add-Content AGENTS.md

# If AGENTS.md doesn't exist, create it
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" -OutFile AGENTS.md
```

**Appending to existing configuration:**
```powershell
# For skill-based formats like GitHub Copilot/Cursor/Windsurf/Gemini/OpenCode, skills are stored in separate directories and don't conflict with existing configuration
# For Claude Code, use the Stride plugin instead of manual skill downloads
```

## Maintenance

### Updating Instructions

To update instruction content:

1. Edit the appropriate file in `docs/multi-agent-instructions/`
2. Test locally to ensure content is valid
3. Commit and push changes to GitHub
4. Updated content is immediately available via download URLs
5. No changes to onboarding endpoint needed

### Version Control

- All instruction files are version-controlled in the repository
- Changes tracked in git history
- Developers can see diff when instructions change
- Can roll back to previous versions if needed

### Monitoring

**Success Metrics:**
- Reduction in common mistakes (identifier specification, verification_steps format)
- Faster task creation (fewer API rejections)
- Higher completion success rate
- Reduced need for documentation lookups

## Comparison with Claude Code Skills

| Feature | Claude Code Skills | Multi-Agent Instructions |
|---------|-------------------|-------------------------|
| **Activation** | Contextual (on-demand) | Always-active |
| **Content Size** | 1000+ lines per skill | 200-400 lines total |
| **Distribution** | Embedded in endpoint | Downloadable files |
| **Workflow Enforcement** | Blocking validation | Guidance only |
| **Target Assistants** | Claude Code (via plugin) | GitHub Copilot, Cursor, Windsurf, Gemini, OpenCode, Codex CLI (Skills); Continue.dev, Kimi (Always-active) |
| **Update Frequency** | With endpoint changes | Independent file updates |
| **Token Cost** | High (comprehensive) | Low (concise) |

## Future Enhancements

### Short Term (1-3 months)
- Gather feedback from developers using different assistants
- Refine content based on real usage patterns
- Add language-specific examples (Elixir, Python, JavaScript)

### Medium Term (3-6 months)
- Framework-specific patterns (Phoenix, React, etc.)
- Database schema guidance
- Assistant-specific optimizations

### Long Term (6-12 months)
- Dynamic content based on project characteristics
- Integration with IDE-specific features
- Support for additional AI assistants

## Related Documentation

- [Onboarding Endpoint](api/get_agent_onboarding.md) - Complete API documentation
- [Stride Has Skills](STRIDE-HAS-SKILLS.md) - Claude Code Skills documentation
- [Task Writing Guide](TASK-WRITING-GUIDE.md) - How to write effective tasks
- [AI Workflow](AI-WORKFLOW.md) - Complete workflow for AI agents
- [Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md) - How to execute hooks properly
