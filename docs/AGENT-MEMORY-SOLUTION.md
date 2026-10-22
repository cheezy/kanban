# How Agents Remember Stride Context

## The Problem

AI agents forget how to work with Stride between sessions because:
- Sessions are stateless
- Agents don't retain memory across conversations
- Different agents (Claude Code, GitHub Copilot, Cursor, Windsurf, Continue.dev, Gemini CLI, OpenCode, Codex CLI, Kimi Code CLI, Pi and others) have different memory mechanisms

## The Solution

A **multi-layered approach** that works for every agent in every project. The
most durable layer is a Stride plugin or skill set for the agent's own tool:
its skills load whenever the agent works on a Stride task, so nothing has to be
remembered. The onboarding endpoint covers everything else.

### Layer 1: The Onboarding Endpoint (Universal)

**URL:** `https://www.stridelikeaboss.com/api/agent/onboarding`

The endpoint needs no token.

**What it provides:**
- A mandatory setup checklist (`MANDATORY_SETUP_CHECKLIST`)
- File templates for `.stride.md` and `.stride_auth.md` (`file_templates`)
- The workflow, the hooks and the API endpoints
- Per-tool installation instructions (`claude_code_skills`, `multi_agent_instructions`)
- Agent-specific memory instructions (`memory_strategy`)
- Common mistakes to avoid
- A quick reference card
- A session initialization checklist

**How agents use it:**
```bash
# At the start of EVERY session
curl https://www.stridelikeaboss.com/api/agent/onboarding
```

**Why it works:**
- Platform-agnostic (works with any HTTP client)
- Self-contained (all info in one place)
- Progressive detail (quick reference + full guides)
- The server writes nothing to your machine: the agent decides which files to create

### Layer 2: Project Configuration (Platform-Specific)

Each agent platform has a way to load Stride context automatically. The
current install steps for every tool are in
[Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md) and
[Getting Started with AI Agents](GETTING-STARTED-WITH-AI.md#configuring-your-ai-agent).

#### Claude Code

Install the Stride plugin. Its skills load on demand and its hooks run your
`.stride.md` commands for you:

```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

You can also add a short Stride section to the project's `AGENTS.md`. The
onboarding response carries an example under
`memory_strategy.agent_specific_instructions.claude_code.example_agents_md_section`:

```markdown
<!-- AGENTS.md -->
## STRIDE TASK MANAGEMENT
[Essential workflow summary]
```

#### Cursor

Install the seven Stride skills into `.cursor/skills/`. Cursor discovers them
there and loads them when a Stride task comes up:

```bash
for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do
  mkdir -p .cursor/skills/$skill
  curl -sL https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/skills/$skill/SKILL.md \
    -o .cursor/skills/$skill/SKILL.md
done
```

#### Windsurf

Install the same seven skills into `.windsurf/skills/`: run the Cursor loop
above with `.windsurf/skills` in place of `.cursor/skills`.

#### Aider

```yaml
# .aider.conf.yml
read:
  - .stride.md
```

The onboarding response's Aider steps call this list `read_files`; check the
key against your Aider version. Never add `.stride_auth.md` to a list an agent
reads into a shared context.

### Layer 3: Local Files (Required)

Every project using Stride needs:

**`.stride.md`** (version controlled)
- Contains hook scripts (before_doing, after_doing, etc.)
- Get template from onboarding endpoint

**`.stride_auth.md`** (gitignored!)
- Contains API token
- Get template from onboarding endpoint
- MUST add to .gitignore

### Layer 4: Documentation References

The onboarding endpoint's `required_reading.guides` lists three guides to read
before creating tasks:
- TASK-WRITING-GUIDE.md - Task creation requirements
- AI-WORKFLOW.md - Complete workflow guide
- AGENT-CAPABILITIES.md - Capability matching

Its `resources` section links the rest, including
AGENT-HOOK-EXECUTION-GUIDE.md (hook execution details) and REVIEW-WORKFLOW.md
(review vs auto-complete).

## How to Use This System

### First Time Using Stride (Any Agent)

1. **Install the Stride plugin or skills for your tool** (see Layer 2).

2. **Fetch onboarding:**
   ```bash
   curl https://www.stridelikeaboss.com/api/agent/onboarding > .stride_onboarding.json
   ```

3. **Create required files:**
   - Copy `.stride.md` from `file_templates.stride_md`
   - Copy `.stride_auth.md` from `file_templates.stride_auth_md`
   - Add your API token to `.stride_auth.md`
   - Add `.stride_auth.md` to `.gitignore`

4. **Read documentation:**
   - Follow links in `required_reading` section
   - Study `good_example` in `task_creation_requirements`

5. **Configure your platform:**
   - Find your agent in `memory_strategy.agent_specific_instructions`
   - Follow the platform-specific steps

6. **Claim first task:** run the `before_doing` hook, then send its result with
   the claim. The claim is a `POST` with a JSON body; see
   [POST /api/tasks/claim](api/post_tasks_claim.md).
   ```bash
   curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
     -H "Authorization: Bearer stride_dev_xxx" \
     -H "Content-Type: application/json" \
     -d '{"agent_name": "My Agent", "before_doing_result": {"exit_code": 0, "output": "Already up to date.", "duration_ms": 850}}'
   ```

**Time:** 15-20 minutes

With a Stride plugin installed, the agent's `stride-workflow` skill makes the
claim and runs the hooks; you do not send this request yourself.

### Starting a New Session (Returning Agent)

1. **Quick refresh:**
   ```bash
   curl https://www.stridelikeaboss.com/api/agent/onboarding | \
     jq '.quick_reference_card'
   ```

2. **Verify setup:**
   ```bash
   test -f .stride.md && \
   test -f .stride_auth.md && \
   grep -q '.stride_auth.md' .gitignore
   ```

3. **Review workflow if needed:**
   - Check `first_session_vs_returning.returning_agent`
   - Workflow: before_doing → claim → work → after_doing → before_review → complete → [continue or stop]

4. **Continue working:** run `before_doing`, then claim with a `POST` carrying
   `before_doing_result`, exactly as in step 6 above.

**Time:** 2-3 minutes

## What's in the Onboarding Response

### New Sections (Added for Agent Memory)

1. **memory_strategy** - How to remember across sessions
   - Universal approach (fetch this endpoint)
   - Platform-specific instructions under `agent_specific_instructions` (Claude Code, Cursor, Windsurf, Gemini, Aider, Cline, Copilot, OpenCode, Codex, Kimi and a generic entry)
   - Example configuration snippets

2. **session_initialization** - Checklist for starting a session
   - 5 steps with commands and rationale
   - Progressive from setup to claiming tasks. Its last step shows a bare
     `curl` to the claim URL; the claim is a `POST` with `before_doing_result`,
     as in step 6 above.

3. **first_session_vs_returning** - Different paths for experience level
   - First-time: detailed 8-step process
   - Returning: quick 5-step refresh

4. **common_mistakes_agents_make** - Learn from errors
   - 9 critical mistakes with fixes
   - Consequences clearly explained

5. **quick_reference_card** - Ultra-condensed essentials
   - Workflow, files, endpoints, hooks
   - For experienced agents who just need a reminder

### Existing Sections (Already There)

- **MANDATORY_SETUP_CHECKLIST** - File creation requirements, step by step
- **version**, **skills_version** - The payload's version and its skills version
- **api_schema** - Field reference: request formats, hook and result shapes, task fields and validation modes
- **overview** - What Stride is
- **quick_start** - Getting started
- **file_templates** - .stride.md and .stride_auth.md content
- **claude_code_skills** - Installing the Claude Code plugin
- **workflow** - API endpoints
- **hooks** - Hook system details
- **api_reference** - Complete API documentation
- **required_reading** - Documentation URLs
- **task_creation_requirements** - How to write good tasks
- **multi_agent_instructions** - Installation for other AI coding tools
- **resources** - All documentation links

## Why This Works

### Universal
- Works with ANY AI agent (not just Claude)
- Works in ANY project (not just Stride codebase)
- Standard HTTP + JSON (no special dependencies)

### Comprehensive
- Progressive detail (quick reference to full guides)
- Multiple entry points (first-time vs returning)
- Platform-specific instructions included

### Self-Documenting
- Tells agents HOW to remember
- Explains WHY each step matters
- Shows common mistakes to avoid

### Secure
- No file writing from server
- Agents control what goes in their projects
- Secrets management explicitly covered

### Maintainable
- Single source of truth (the endpoint)
- Version controlled (in Stride codebase)
- Easy to update: the payload is built in `lib/kanban_web/controllers/api/agent_json.ex`, with its larger sections in `lib/kanban_web/controllers/api/agent/` (for example `setup_docs.ex` and `multi_agent_instructions.ex`)

## For Developers

If you're building a project that uses Stride, here's what to tell your agents:

```markdown
This project uses Stride for task management.

At the start of each session, fetch:
https://www.stridelikeaboss.com/api/agent/onboarding

Follow the instructions for your agent platform.
```

That's it. The endpoint handles the rest.

## Summary

**The core insight:** Instead of trying to inject memory into agents, we provide a **fetch-at-startup pattern** that works universally.

**The implementation:** An enhanced onboarding endpoint that:
1. Teaches agents how to remember
2. Provides platform-specific instructions
3. Includes progressive detail for all experience levels
4. Documents common mistakes
5. Offers quick reference for returning agents

**The result:** Agents remember how to work with Stride, regardless of platform or project.
