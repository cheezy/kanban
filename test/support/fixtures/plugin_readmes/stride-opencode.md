## Installation

Installation is **two separate steps** — the plugin and the skills/agents are distributed in the same repository but loaded by OpenCode through different mechanisms.

### Step 1 — Install the plugin (for automatic hook execution)

Add the plugin to your project's `opencode.json` or global `~/.config/opencode/opencode.json`:

```json
{
  "plugin": ["github:cheezy/stride-opencode"]
}
```

OpenCode installs plugins automatically using **Bun** at startup, caching them under `~/.cache/opencode/node_modules/`. See [OpenCode's plugins docs](https://opencode.ai/docs/plugins/) for details.

> **npm package status:** The `opencode-stride` npm package is not currently published. Use the `github:cheezy/stride-opencode` reference above. If you need pinning, add a ref: `github:cheezy/stride-opencode#v1.43.0` (branch, tag, or commit SHA). OpenCode's docs only document npm package names in `"plugin"`, but Bun resolves `github:owner/repo` references as npm-install targets, so this works.

Alternatively, if you prefer not to auto-install, clone the repo into a local plugin directory:

```bash
# Project-local plugin
git clone https://github.com/cheezy/stride-opencode.git .opencode/plugins/stride-opencode

# Or user-global plugin
git clone https://github.com/cheezy/stride-opencode.git ~/.config/opencode/plugins/stride-opencode
```

Once installed, the plugin tells you when a newer release exists — see [Plugin update notice](#plugin-update-notice) below.

### Step 2 — Install the skills and subagents (for the workflow itself)

**Important:** OpenCode does NOT auto-discover skills or agents from inside an installed plugin. They must live on disk at the documented paths below, regardless of whether the plugin is installed via `github:` or locally.

Clone the repo and copy the skills/agents into your project:

```bash
# Clone once somewhere
git clone https://github.com/cheezy/stride-opencode.git /tmp/stride-opencode

# Copy the 7 skills (each is a directory with a SKILL.md)
mkdir -p .opencode/skills
cp -R /tmp/stride-opencode/skills/. .opencode/skills/

# Copy the 5 subagent markdown files
mkdir -p .opencode/agents
cp /tmp/stride-opencode/agents/*.md .opencode/agents/

# Copy the 2 native commands (/create-tasks, /create-goals)
mkdir -p .opencode/commands
cp /tmp/stride-opencode/commands/*.md .opencode/commands/

# Copy the project-level AGENTS.md (orientation for the main agent)
cp /tmp/stride-opencode/AGENTS.md AGENTS.md
```

For a **global** install (available to every project), mirror the same copy into `~/.config/opencode/`:

```bash
mkdir -p ~/.config/opencode/skills ~/.config/opencode/agents ~/.config/opencode/commands
cp -R /tmp/stride-opencode/skills/. ~/.config/opencode/skills/
cp /tmp/stride-opencode/agents/*.md ~/.config/opencode/agents/
cp /tmp/stride-opencode/commands/*.md ~/.config/opencode/commands/
```

Per [OpenCode's skills docs](https://opencode.ai/docs/skills/), skills are also discovered from `.claude/skills/` and `.agents/skills/` — so a project that already uses the Claude Code stride plugin will pick these up from the same `.claude/skills/` directory without a separate copy.

### Step 3 — Create the Stride config files (one-time per project)

Create `.stride_auth.md` and `.stride.md` at your project root (see [Setup](#setup) below).
