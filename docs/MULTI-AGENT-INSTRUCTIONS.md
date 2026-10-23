# Multi-Agent Instructions

*Last Updated: October 22, 2026*

## Overview

Stride works with many AI coding assistants, not only Claude Code. Each one gets the Stride workflow in the form its tool loads best:

- **A Stride plugin for the tool**, where one exists: Claude Code, GitHub Copilot CLI, Gemini CLI, OpenCode, Codex CLI and Pi. The plugin is the maintained source of the Stride skills and agents for that tool.
- **Seven Stride skills downloaded into the tool's skills folder**: Cursor, Windsurf and Continue.dev. The files come from `docs/multi-agent-instructions/skills/` in this repository.
- **An always-active instructions file**: Kimi Code CLI reads `docs/multi-agent-instructions/AGENTS.md`.

**Core Principle:** Install the Stride plugin for your tool when there is one. Use the downloadable skills or the `AGENTS.md` file only for tools that have no plugin.

**Supported AI Assistants:** Claude Code, GitHub Copilot CLI, Cursor, Windsurf, Continue.dev, Gemini CLI, OpenCode, Codex CLI, Kimi Code CLI (k2.5) and Pi.

The onboarding endpoint, `GET /api/agent/onboarding`, carries the same install instructions as data: Claude Code under `claude_code_skills`, and every other tool, Pi included, under `multi_agent_instructions.formats`. See [GET /api/agent/onboarding](api/get_agent_onboarding.md).

## Architecture

### Two-Tier Approach

**Stride plugins** (per tool):
- Claude Code, GitHub Copilot CLI, Gemini CLI, OpenCode, Codex CLI and Pi each have a Stride plugin in its own repository
- Each plugin carries the seven Stride skills, adapted to its tool, plus subagents or their equivalent
- Updated by updating the plugin

**Downloadable instruction files** (this repository):
- Seven skill files for Cursor, Windsurf and Continue.dev, plus an optional Continue.dev `config.json`
- One always-active `AGENTS.md` for Kimi Code CLI
- Served from the `main` branch on GitHub, so a change reaches new downloads as soon as it is pushed

### Benefits of This Approach

1. **Specialized for Each Assistant**: Each tool gets the format it loads natively
2. **Token-Efficient**: The onboarding response links to the files instead of embedding them, so an agent downloads only its own format
3. **One Source per Tool**: A plugin owns its tool's skills; the downloadable files cover only the tools without a plugin
4. **Easy Updates**: Updating a downloadable file needs no change to the onboarding endpoint

### Orchestrator-First Pattern (All Assistants)

For any Stride task work, the entry point is the `stride-workflow` skill. Every task should be claimed, explored, implemented, reviewed, and completed through that single lifecycle: **claim → explore → implement → review → complete**. The supporting skills (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) document API contracts and per-phase rules, but they are dispatched from inside `stride-workflow`, not invoked directly. The motivation for moving enforcement out of prose and into gates is recorded in [`docs/stride-plugin-enforcement-recommendations.md`](stride-plugin-enforcement-recommendations.md). How far each tool can enforce the pattern depends on its runtime:

| Platform | How the pattern is enforced |
|---|---|
| Claude Code (`stride` plugin) | A `PreToolUse` hook on the `Skill` tool blocks a sub-skill unless the orchestrator's activation marker is present |
| Gemini CLI (`stride-gemini` extension) | A `BeforeTool` hook on `activate_skill` runs the same marker check |
| OpenCode (`stride-opencode` plugin) | A TypeScript skill gate in the plugin |
| GitHub Copilot CLI (`stride-copilot`), Codex CLI (`stride-codex`), Pi (`stride-pi`) | Described in each plugin's README, which is the current reference for its hooks and gates |
| Cursor / Windsurf / Continue.dev (`docs/multi-agent-instructions/skills/*`) | No runtime gate. Each `SKILL.md` marks the sub-skills INTERNAL in its `description:` and opens with a STOP block |
| Continue.dev `config.json` (optional) | No skill matcher. An orchestrator-first paragraph in its `systemMessage` |
| Kimi Code CLI (`docs/multi-agent-instructions/AGENTS.md`) | No matcher. An `Orchestrator-First Pattern` section near the top of the always-active file |

The same orchestrator-first guidance also appears in the historical files `copilot-instructions.md`, `GEMINI.md`, `cursorrules.txt`, `windsurfrules.txt` and the single-file `SKILL.md` in `docs/multi-agent-instructions/`. Nothing serves those files any more and they are no longer maintained; see [File Locations](#file-locations).

## Supported AI Assistants (7 Skills-Based + 2 Always-Active)

> The counts in this heading are historical. Today ten assistants are covered: six through a Stride plugin (Claude Code, GitHub Copilot CLI, Gemini CLI, OpenCode, Codex CLI, Pi), three through the downloadable skills (Cursor, Windsurf, Continue.dev), and one through the always-active `AGENTS.md` (Kimi Code CLI).

Every route installs the same seven skills: `stride-workflow` (the entry point), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks` and `stride-subagent-workflow`.

### 1. Claude Code

**Installation Method:** Stride Marketplace Plugin

**Scope:** On-demand skill loading (invoked when needed), plus subagents and hooks that run your `.stride.md` commands automatically

**Skills Provided:** the seven Stride skills, with `stride-workflow` as the entry point

**Agents Provided:** `task-explorer`, `task-reviewer`, `task-decomposer`, `task-enricher`, `hook-diagnostician`, `task-runner`

> **REQUIRED: Install the Stride plugin from the marketplace.** Do NOT manually download skill files for Claude Code. The plugin keeps the skills current and is the only supported installation method.

**Installation:**
```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

**Verify installation** by checking that the Stride skills (e.g., `stride-workflow`, `stride-claiming-tasks`) appear in your available skills list.

**IMPORTANT:** Claude Code users must install the Stride plugin rather than manually downloading skill files. The plugin manages skill installation, updates, and versioning automatically.

### 2. GitHub Copilot

**Installation Method:** Stride Copilot Plugin (GitHub Copilot CLI)

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** the seven Stride skills, adapted for Copilot, with `stride-workflow` as the entry point

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `task-enricher`, `hook-diagnostician`

> **RECOMMENDED: Install the Stride Copilot plugin.**

**Installation from the Stride Copilot marketplace:**

```bash
copilot plugin marketplace add cheezy/stride-copilot-marketplace
copilot plugin install stride-copilot
```

**Or directly from the repository** (the command the onboarding endpoint gives):

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

**Plugin management:**

```bash
copilot plugin update stride-copilot       # Update to latest version
copilot plugin uninstall stride-copilot    # Remove plugin
copilot plugin list                        # View installed plugins
```

**IMPORTANT:** The stride-copilot plugin provides Copilot-adapted versions of the Stride skills with tool-agnostic language. The plugin system handles skill and agent discovery. See the [stride-copilot README](https://github.com/cheezy/stride-copilot) for how it runs your hooks.

### 3. Cursor

**Files:** Seven skills, one `SKILL.md` per skill

**Location:** `docs/multi-agent-instructions/skills/<skill-name>/SKILL.md`

**Compatible Tools:** Cursor

**Scope:** On-demand skill loading (invoked when needed)

**Format:** YAML frontmatter + Markdown content

**Skills:** `stride-workflow` (start here), `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`

**Download** (the same command as `multi_agent_instructions.formats.cursor.installation_unix` in the onboarding response):
```bash
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  mkdir -p .cursor/skills/$skill
  curl -sL https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$skill/SKILL.md \
    -o .cursor/skills/$skill/SKILL.md
done
```

**IMPORTANT:** Cursor discovers skills in `.cursor/skills/` directories. The skill name (e.g., `stride-workflow`) must match the directory name. The onboarding response also lists `.claude/skills/<skill-name>/SKILL.md` and `~/.cursor/skills/<skill-name>/SKILL.md` as locations Cursor reads. See [Cursor Skills Documentation](https://cursor.com/docs/context/skills) for details. Cursor has no Stride plugin, so these files run no hooks for you: the skills tell the agent to run your `.stride.md` commands itself.

### 4. Windsurf Cascade

**Files:** Seven skills, one `SKILL.md` per skill

**Location:** `docs/multi-agent-instructions/skills/<skill-name>/SKILL.md`

**Compatible Tools:** Windsurf

**Scope:** On-demand skill loading (invoked when needed)

**Format:** YAML frontmatter + Markdown content

**Skills:** the same seven skills as Cursor

**Download** (the same command as `multi_agent_instructions.formats.windsurf.installation_unix`):
```bash
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  mkdir -p .windsurf/skills/$skill
  curl -sL https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$skill/SKILL.md \
    -o .windsurf/skills/$skill/SKILL.md
done
```

**IMPORTANT:** Windsurf discovers skills in `.windsurf/skills/` directories, or globally in `~/.codeium/windsurf/skills/`. The skill name must match the directory name. See [Windsurf Skills Documentation](https://docs.windsurf.com/windsurf/cascade/skills) for details. As with Cursor, the agent runs your `.stride.md` hooks itself.

### 5. Continue.dev

**Files:** Seven skills, plus an optional `config.json`

**Location:** `docs/multi-agent-instructions/skills/<skill-name>/SKILL.md` and `docs/multi-agent-instructions/continue-config.json`

**Scope:** On-demand skill loading, plus an optional project config with a system message, context providers and slash commands

**Download the skills** (the same command as `multi_agent_instructions.formats.continue.installation_unix`):
```bash
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  mkdir -p .continue/skills/$skill
  curl -sL https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$skill/SKILL.md \
    -o .continue/skills/$skill/SKILL.md
done
```

**Optional supplemental config** (`multi_agent_instructions.formats.continue.supplemental_config`). This overwrites `.continue/config.json`, so back up or merge an existing one first:
```bash
mkdir -p .continue
curl -o .continue/config.json \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json
```

**Focus of the config:**
- System message with core validation rules
- Context providers pointing to Stride documentation
- Slash commands for claiming, completing and creating tasks

### 6. Google Gemini CLI

**Installation Method:** Stride Gemini Extension (install from GitHub)

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** the seven Stride skills, adapted for Gemini CLI, with `stride-workflow` as the entry point

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `task-enricher`, `hook-diagnostician`

> **RECOMMENDED: Install the Stride Gemini extension.**

**Installation:**

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

**Verify installation** by checking that Stride skills (e.g., `stride-workflow`, `stride-claiming-tasks`) appear in your available skills list and custom agents (e.g., `task-explorer`, `task-reviewer`) are accessible.

**IMPORTANT:** The stride-gemini extension provides Gemini-adapted versions of the Stride skills with Gemini CLI tool names (grep_search, read_file, glob, etc.). It also includes a `GEMINI.md` context file and hooks that run your `.stride.md` commands. The [stride-gemini README](https://github.com/cheezy/stride-gemini) has the full steps.

### 7. OpenCode

**Installation Method:** Stride OpenCode Plugin

**Scope:** On-demand skill loading + subagents + automatic hook execution

**Skills Provided:** the seven Stride skills, adapted for OpenCode

**Agents Provided:** `task-explorer`, `task-reviewer`, `task-decomposer`, `task-enricher`, `hook-diagnostician`

Installation is two steps, because OpenCode loads plugins and skills through different mechanisms.

**Step 1 — the plugin** (runs your hooks). Add it to the project's `opencode.json`, or the global `~/.config/opencode/opencode.json`:

```json
{
  "plugin": ["github:cheezy/stride-opencode"]
}
```

**Step 2 — the skills and agents.** OpenCode does not discover skills inside an installed plugin, so copy them into the project:

```bash
src=$(mktemp -d) && git clone https://github.com/cheezy/stride-opencode.git "$src/stride-opencode" && \
  mkdir -p .opencode/skills .opencode/agents && \
  cp -R "$src/stride-opencode/skills/." .opencode/skills/ && \
  cp "$src/stride-opencode/agents/"*.md .opencode/agents/
```

The fresh `mktemp -d` directory and the `&&` chain mean nothing is copied unless the clone succeeded into a directory no one else could have prepared.

For a global install, copy into `~/.config/opencode/skills/` and `~/.config/opencode/agents/` instead. The [stride-opencode README](https://github.com/cheezy/stride-opencode) has the full steps, including its commands and `AGENTS.md`.

### 8. Codex CLI

**Installation Method:** Stride Codex Plugin

**Scope:** On-demand skill loading (activated when needed) + custom agents

**Skills Provided:** the seven Stride skills, adapted for Codex CLI, with `stride-workflow` as the entry point

**Custom Agents:** `task-explorer`, `task-reviewer`, `task-decomposer`, `task-enricher`, `hook-diagnostician`

> **RECOMMENDED: Install the Stride Codex plugin.**

**Installation from the Stride Codex marketplace:**

```bash
codex plugin marketplace add cheezy/stride-codex-marketplace
codex plugin install stride-codex
```

**Installation with the install script (global — applies to all projects):**

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

**Windows (PowerShell):**

Requires PowerShell 5.1+ or PowerShell Core 7+ and Git for Windows on `PATH`.

```powershell
# Global install (all projects)
irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 | iex

# Or project-local install (scriptblock wrapper required to pass -Project)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1))) -Project
```

**Verify installation** by checking that Stride skills (e.g., `stride-workflow`, `stride-claiming-tasks`) appear in your available skills list and custom agents (e.g., `task-explorer`, `task-reviewer`) are discoverable.

**Skill discovery paths:** Codex CLI discovers skills in `.agents/skills/<name>/SKILL.md` or `.codex/skills/<name>/SKILL.md`, and agents in `.agents/agents/<name>.md`.

**IMPORTANT:** How Codex runs your `.stride.md` hooks depends on how you installed the plugin: a script or manual install into `.agents/` needs the hook handler registered by hand. The [stride-codex README](https://github.com/cheezy/stride-codex) covers both cases.

### 9. Kimi Code CLI (k2.5)

**File:** `AGENTS.md`

**Location:** `docs/multi-agent-instructions/AGENTS.md`

**Compatible Tools:** Kimi Code CLI (k2.5)

**Scope:** Project-scoped, always-active (append-mode)

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

### 10. Pi

**Installation Method:** Stride Pi plugin (install script from GitHub)

**Skills Provided:** the seven Stride skills, plus four skills that stand in for subagents (`stride-task-explorer`, `stride-task-reviewer`, `stride-task-decomposer`, `stride-hook-diagnostician`)

Download the install script, read it, then run it:

```bash
curl -fsSLo stride-pi-install.sh https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh
less stride-pi-install.sh
```

**Installation (global):**

```bash
bash stride-pi-install.sh
```

**Installation (current project only):**

```bash
bash stride-pi-install.sh --project
```

The onboarding response carries the same download, read and run steps under `multi_agent_instructions.formats.pi`; the [stride-pi README](https://github.com/cheezy/stride-pi) is the reference.

## Content Strategy

### Core Content (All Formats)

The downloadable skills and `AGENTS.md` cover the same essential topics:

1. **Hook Execution Mandate**
   - The five hooks (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`) and their purpose. Among the seven skills, `after_goal` is covered by `stride-workflow` (Step 9) and `stride-completing-tasks`
   - Every hook is blocking, with a 600-second timeout reported by the server
   - Execute after_doing and before_review BEFORE calling the complete endpoint

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
   - `workflow_steps` sent on every `/complete` call — six-entry telemetry array (one per phase)
   - Skip-reason enum: `no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`
   - 40-character non-whitespace minimum on `summary` fields
   - Controlled by the `:strict_completion_validation` setting: strict (a missing or invalid result gets `422`) by default in production, grace (a warning, and the request succeeds) by default elsewhere. `STRIDE_STRICT_COMPLETION_VALIDATION=true` or `=false` overrides the default

### Format-Specific Adaptations

**GitHub Copilot CLI (plugin):**
- Copilot-adapted skills and custom agents from the stride-copilot plugin
- Installed and discovered by the Copilot CLI plugin system

**Cursor (downloaded skills):**
- YAML frontmatter with structured metadata
- Rich formatting with headings, lists, code blocks in body
- Skill-based on-demand loading reduces token usage
- Installed in `.cursor/skills/<skill-name>/` directories

**Windsurf (downloaded skills):**
- Same files as Cursor
- Installed in `.windsurf/skills/<skill-name>/` directories

**Continue.dev (downloaded skills + JSON):**
- Same skill files, installed in `.continue/skills/<skill-name>/`
- Optional `config.json` with a system message, context providers and slash commands

**Gemini CLI (extension with skills + custom agents):**
- Gemini-adapted skills and 5 custom agents from the stride-gemini extension
- `GEMINI.md` context file for reliable skill activation
- Installed via `gemini extensions install https://github.com/cheezy/stride-gemini`

**OpenCode (plugin + copied skills):**
- The plugin runs your hooks; the skills and agents are copied into `.opencode/skills/` and `.opencode/agents/` (or `~/.config/opencode/`)

**Codex CLI (plugin with skills + custom agents):**
- Codex-adapted skills and 5 custom agents from the stride-codex plugin
- Installed from the Stride Codex marketplace or with `install.sh` (global or `--project`)
- Discovered in `.agents/skills/` or `.codex/skills/` (agents in `.agents/agents/`)

**Kimi Code CLI (k2.5) (Markdown):**
- Always-active instructions loaded on startup
- Append-mode for merging with existing AGENTS.md content
- Installed in project root: ./AGENTS.md
- No manual invocation needed

**Pi (plugin):**
- Pi-adapted skills, installed globally or per project by the stride-pi install script

## Distribution Architecture

### Onboarding Endpoint Structure

The `/api/agent/onboarding` endpoint includes the `multi_agent_instructions` section. Its `formats` map has one entry per tool: `copilot`, `cursor`, `windsurf`, `continue`, `gemini`, `opencode`, `codex` and `kimi`. Plugin tools carry the plugin's repository and install commands; download tools carry the download commands. An abridged example:

```json
{
  "version": "1.0",
  "api_base_url": "https://www.stridelikeaboss.com",
  "claude_code_skills": { "...": "..." },
  "multi_agent_instructions": {
    "description": "Always-active code completion guidance for AI assistants other than Claude Code...",
    "note": "Claude Code users should use the claude_code_skills section above...",
    "installation_warning": "IMPORTANT: The installation commands will overwrite existing configuration files...",
    "formats": {
      "copilot": {
        "description": "Stride Copilot Plugin — ...",
        "plugin_repo": "https://github.com/cheezy/stride-copilot",
        "skills_provided": ["stride-claiming-tasks", "..."],
        "custom_agents": ["task-explorer", "..."],
        "installation_unix": "copilot plugin install https://github.com/cheezy/stride-copilot",
        "installation_windows": "copilot plugin install https://github.com/cheezy/stride-copilot",
        "update": "copilot plugin update stride-copilot",
        "uninstall": "copilot plugin uninstall stride-copilot",
        "note": "...",
        "fallback_note": "..."
      },
      "cursor": {
        "file_path": ".cursor/skills/<skill-name>/SKILL.md (7 skills total)",
        "skills_provided": ["stride-workflow", "..."],
        "installation_unix": "for skill in stride-workflow ...; do ... curl -sL .../docs/multi-agent-instructions/skills/$skill/SKILL.md ...; done",
        "installation_windows": "...",
        "safe_installation": { "...": "..." }
      }
    },
    "usage_notes": ["..."],
    "safe_installation": ["..."]
  }
}
```

### File Locations

The downloadable files live in `docs/multi-agent-instructions/`:
```
docs/multi-agent-instructions/
├── skills/
│   ├── stride-workflow/SKILL.md            # Served: Cursor, Windsurf, Continue.dev
│   ├── stride-claiming-tasks/SKILL.md      # Served
│   ├── stride-completing-tasks/SKILL.md    # Served
│   ├── stride-creating-tasks/SKILL.md      # Served
│   ├── stride-creating-goals/SKILL.md      # Served
│   ├── stride-enriching-tasks/SKILL.md     # Served
│   └── stride-subagent-workflow/SKILL.md   # Served
├── continue-config.json                    # Served: Continue.dev (optional)
├── AGENTS.md                               # Served: Kimi Code CLI
├── stride-development-guidelines/SKILL.md  # Contributors to this repository; not served to agents
├── SKILL.md                                # Historical: not served, not maintained
├── copilot-instructions.md                 # Historical: not served, not maintained
├── GEMINI.md                               # Historical: not served, not maintained
├── cursorrules.txt                         # Historical: not served, not maintained
└── windsurfrules.txt                       # Historical: not served, not maintained
```

"Served" means the onboarding response links to the file. The historical files predate the per-tool plugins and the per-skill downloads; they are kept so existing links still resolve, and [the docs index](README.md) lists them under Historical records.

### Served skill copies and the plugins

The seven files under `docs/multi-agent-instructions/skills/` are **self-contained snapshots** of the Stride skills for tools that have no plugin. They are not mirrors of any plugin:

- The plugins are the maintained source. A plugin's skills change with each plugin release, and some of them are split across several files that the download loop above does not fetch.
- Nothing copies plugin changes into these snapshots. When a change to the API or the workflow matters to Cursor, Windsurf or Continue.dev users, edit the snapshot here directly, in the same change.
- `test/kanban_web/controllers/api/agent_controller_test.exs` checks that the `stride-completing-tasks` and `stride-workflow` snapshots and `AGENTS.md` still name the completion fields (`explorer_result`, `reviewer_result`, `workflow_steps`) and `strict_completion_validation`, and that the `stride-completing-tasks` snapshot names the five skip reasons. It does not compare any snapshot with a plugin.
- The files are fetched from the `main` branch on GitHub, so an edit reaches new downloads once it is pushed.

### Endpoint Optimization

The onboarding response links to the instruction files instead of embedding their content. An agent downloads only the format for its own tool, and updating a file needs no change to the endpoint.

## Installation for Developers

### Automatic Installation (Recommended)

When AI agents fetch the onboarding endpoint, they can install their own format:

1. Agent fetches `/api/agent/onboarding`
2. Agent identifies its tool (Copilot, Cursor, Windsurf, Continue.dev, Gemini, OpenCode, Codex CLI, Kimi, Pi)
3. Agent reads its entry in `multi_agent_instructions.formats`
4. Agent runs that entry's `installation_unix` or `installation_windows` command
5. The plugin or the files land in the right place
   - For Cursor, Windsurf and Continue.dev: the seven skill directories under `.cursor/skills/`, `.windsurf/skills/` or `.continue/skills/`
   - For Kimi: Appends to existing AGENTS.md or creates new file
   - For OpenCode: the entry adds the plugin to `opencode.json` and copies the skills and agents into `.opencode/`, as in [Section 7](#7-opencode)

Claude Code installs from `claude_code_skills`; see [Section 1](#1-claude-code).

### Manual Installation

Developers can manually install the plugin or download the instruction files. **IMPORTANT:** The download commands overwrite existing files. If you have existing custom configurations, consider backing them up first or manually merging the Stride instructions.

**Check for existing files first:**
```bash
# Check which files already exist
ls -la .continue/config.json AGENTS.md 2>/dev/null
ls -d .cursor/skills/stride-* .windsurf/skills/stride-* .continue/skills/stride-* 2>/dev/null
```

**Backup existing files (recommended):**
```bash
# Backup existing configuration before installing
[ -f .continue/config.json ] && cp .continue/config.json .continue/config.json.backup
[ -f AGENTS.md ] && cp AGENTS.md AGENTS.md.backup
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  for dir in .cursor .windsurf .continue; do
    [ -f $dir/skills/$skill/SKILL.md ] && cp $dir/skills/$skill/SKILL.md $dir/skills/$skill/SKILL.md.backup
  done
done
```

**Download Stride instructions:**

**GitHub Copilot (Recommended — use the plugin):**

```bash
copilot plugin marketplace add cheezy/stride-copilot-marketplace
copilot plugin install stride-copilot
```

> This installs the seven skills and five custom agents. See [Section 2: GitHub Copilot](#2-github-copilot) for details.

**Cursor, Windsurf and Continue.dev (the seven skills):**
```bash
# Set DIR to .cursor, .windsurf or .continue
DIR=.cursor
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  mkdir -p $DIR/skills/$skill
  curl -sL https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$skill/SKILL.md \
    -o $DIR/skills/$skill/SKILL.md
done
```

**Continue.dev (optional config):**
```bash
mkdir -p .continue
curl -o .continue/config.json \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json
```

**Google Gemini CLI (Recommended — use the extension):**

> Install the stride-gemini extension for the seven skills and five custom agents. See [Section 6: Google Gemini CLI](#6-google-gemini-cli) for instructions.

**Claude Code:**

> Claude Code users should install the Stride plugin instead of manually downloading skills. See [Section 1: Claude Code](#1-claude-code) for plugin installation instructions.

**OpenCode:**

> Install the stride-opencode plugin and copy its skills and agents. See [Section 7: OpenCode](#7-opencode).

**Codex CLI (Recommended — use the plugin):**

```bash
# Global install (all projects)
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash

# Or project-local install
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project
```

> This installs the seven skills and five custom agents. See [Section 8: Codex CLI](#8-codex-cli) for details, including the marketplace route.

**Kimi Code CLI (k2.5):**
```bash
# If AGENTS.md exists, append Stride instructions
echo '\n\n# === Stride Integration Instructions ===' >> AGENTS.md
curl -s https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md

# If AGENTS.md doesn't exist, create it
curl -o AGENTS.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md
```

**Pi:**

> See [Section 10: Pi](#10-pi).

**Merging with existing configuration:**

If you have existing custom instructions, you may want to manually merge them:

1. **For skill-based formats**, skills are stored in separate directories and don't conflict with existing configuration. **Claude Code users** should use the Stride plugin instead (see [Section 1](#1-claude-code))

2. **For Continue.dev (JSON)**, manually merge the Stride instructions into your existing `.continue/config.json` file

### Windows Installation

**PowerShell:**

**IMPORTANT:** These commands will overwrite existing files. Back up first if you have custom configurations.

**Check for existing files:**
```powershell
Get-Item .continue/config.json, AGENTS.md -ErrorAction SilentlyContinue
Get-Item .cursor/skills/stride-*, .windsurf/skills/stride-*, .continue/skills/stride-* -ErrorAction SilentlyContinue
```

**Backup existing files (recommended):**
```powershell
if (Test-Path .continue/config.json) { Copy-Item .continue/config.json .continue/config.json.backup }
if (Test-Path AGENTS.md) { Copy-Item AGENTS.md AGENTS.md.backup }
foreach ($skill in @('stride-workflow','stride-claiming-tasks','stride-completing-tasks','stride-creating-tasks','stride-creating-goals','stride-enriching-tasks','stride-subagent-workflow')) {
  foreach ($dir in @('.cursor','.windsurf','.continue')) {
    if (Test-Path $dir/skills/$skill/SKILL.md) { Copy-Item $dir/skills/$skill/SKILL.md $dir/skills/$skill/SKILL.md.backup }
  }
}
```

**Download Stride instructions:**
```powershell
# GitHub Copilot: use the plugin (recommended)
# copilot plugin marketplace add cheezy/stride-copilot-marketplace
# copilot plugin install stride-copilot

# Cursor, Windsurf and Continue.dev: the seven skills (set $dir to .cursor, .windsurf or .continue)
$dir = '.cursor'
foreach ($s in @('stride-workflow','stride-claiming-tasks','stride-completing-tasks','stride-creating-tasks','stride-creating-goals','stride-enriching-tasks','stride-subagent-workflow')) {
  New-Item -ItemType Directory -Force -Path "$dir/skills/$s" | Out-Null
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$s/SKILL.md" -OutFile "$dir/skills/$s/SKILL.md"
}

# Continue.dev: optional config
New-Item -ItemType Directory -Force -Path .continue
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json" -OutFile .continue/config.json

# Google Gemini CLI: use the extension
# gemini extensions install https://github.com/cheezy/stride-gemini

# Claude Code: Use the plugin instead (see Section 1: Claude Code)
# /plugin marketplace add cheezy/stride-marketplace
# /plugin install stride@stride-marketplace

# OpenCode: add "github:cheezy/stride-opencode" to opencode.json, then copy the
# skills and agents (see Section 7: OpenCode)
git clone https://github.com/cheezy/stride-opencode.git
New-Item -ItemType Directory -Force -Path .opencode/skills, .opencode/agents
Copy-Item -Recurse stride-opencode/skills/* .opencode/skills/
Copy-Item stride-opencode/agents/*.md .opencode/agents/

# Codex CLI (use the plugin installer — global install to $env:USERPROFILE\.agents\)
irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 | iex

# Or project-local Codex install (scriptblock wrapper required to pass -Project through irm | iex)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1))) -Project

# Kimi Code CLI (k2.5)
# If AGENTS.md exists, append Stride instructions
"`n`n# === Stride Integration Instructions ===" | Add-Content AGENTS.md
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" | Select-Object -ExpandProperty Content | Add-Content AGENTS.md

# If AGENTS.md doesn't exist, create it
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/AGENTS.md" -OutFile AGENTS.md
```

**Appending to existing configuration:**
```powershell
# Skill-based formats keep each skill in its own directory and don't conflict with existing configuration
# For Claude Code, use the Stride plugin instead of manual skill downloads
```

## Maintenance

### Updating Instructions

To update the downloadable content:

1. Edit the appropriate file in `docs/multi-agent-instructions/`
2. Run `mix test test/kanban_web/controllers/api/agent_controller_test.exs test/kanban/docs_relative_links_test.exs`
3. Commit and push changes to GitHub
4. Updated content is available via the download URLs once it reaches `main`
5. No changes to onboarding endpoint needed, unless a file is added, removed or renamed

A plugin's skills are updated in that plugin's own repository and release, not here.

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

| Feature | Stride plugins (Claude Code, Copilot, Gemini, OpenCode, Codex, Pi) | Downloaded skills and AGENTS.md (Cursor, Windsurf, Continue.dev, Kimi) |
|---------|-------------------|-------------------------|
| **Activation** | Contextual (on-demand skills) | On-demand skills; Kimi's `AGENTS.md` is always active |
| **Distribution** | The tool's plugin or extension system | Files downloaded from this repository |
| **Workflow Enforcement** | Runtime gates and hooks where the tool allows them | Guidance only; the agent runs the hooks itself |
| **Update Frequency** | With each plugin release | When the files here change |
| **Source** | The plugin's repository | `docs/multi-agent-instructions/` |

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
- [Getting Started with AI Agents](GETTING-STARTED-WITH-AI.md#configuring-your-ai-agent) - Installing the plugin for each tool
- [Stride Skills Plan](STRIDE-SKILLS-PLAN.md) - How the Claude Code skills were planned and implemented
- [Task Writing Guide](TASK-WRITING-GUIDE.md) - How to write effective tasks
- [AI Workflow](AI-WORKFLOW.md) - Complete workflow for AI agents
- [Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md) - How to execute hooks properly
