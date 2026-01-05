# How Agents Remember Stride Context

## The Problem

AI agents forget how to work with Stride between sessions because:
- Sessions are stateless
- Agents don't retain memory across conversations
- Different agents (Claude, Cursor, Windsurf, etc.) have different memory mechanisms

## The Solution

A **multi-layered approach** that works for ALL agents in ALL projects:

### Layer 1: The Onboarding Endpoint (Universal)

**URL:** `https://www.stridelikeaboss.com/api/agent/onboarding`

**What it provides:**
- Complete workflow documentation
- File templates (.stride.md, .stride_auth.md)
- Agent-specific memory instructions
- Common mistakes to avoid
- Quick reference card
- Session initialization checklist

**How agents use it:**
```bash
# At the start of EVERY session
curl https://www.stridelikeaboss.com/api/agent/onboarding
```

**Why it works:**
- Platform-agnostic (works with any HTTP client)
- Self-contained (all info in one place)
- Progressive detail (quick reference + full guides)
- No file writing (secure, trustworthy)

### Layer 2: Project Configuration (Platform-Specific)

Each agent platform has a way to load context automatically:

#### Claude Code
```json
// .claudeproject
{
  "contextFiles": [".stride.md", ".stride_auth.md", "docs/AI-WORKFLOW.md"]
}
```

```markdown
<!-- AGENTS.md -->
## STRIDE TASK MANAGEMENT
[Essential workflow summary]
```

#### Cursor
```
# .cursorrules
Include .stride.md for workflow hooks
```

#### Windsurf
```
# cascade.md or .windsurfrules
[Stride workflow documentation]
```

#### Aider
```yaml
# .aider.conf.yml
read_files:
  - .stride.md
```

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

The onboarding endpoint provides URLs to:
- AI-WORKFLOW.md - Complete workflow guide
- TASK-WRITING-GUIDE.md - Task creation requirements
- AGENT-HOOK-EXECUTION-GUIDE.md - Hook execution details
- AGENT-CAPABILITIES.md - Capability matching
- REVIEW-WORKFLOW.md - Review vs auto-complete

## How to Use This System

### First Time Using Stride (Any Agent)

1. **Fetch onboarding:**
   ```bash
   curl https://www.stridelikeaboss.com/api/agent/onboarding > .stride_onboarding.json
   ```

2. **Create required files:**
   - Copy `.stride.md` from `file_templates.stride_md`
   - Copy `.stride_auth.md` from `file_templates.stride_auth_md`
   - Add your API token to `.stride_auth.md`
   - Add `.stride_auth.md` to `.gitignore`

3. **Read documentation:**
   - Follow links in `required_reading` section
   - Study `good_example` in `task_creation_requirements`

4. **Configure your platform:**
   - Find your agent in `memory_strategy.agent_specific_instructions`
   - Follow the platform-specific steps

5. **Claim first task:**
   ```bash
   curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://www.stridelikeaboss.com/api/tasks/claim
   ```

**Time:** 15-20 minutes

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
   - Workflow: claim → before_doing → work → after_doing → complete → [continue or stop]

4. **Continue working:**
   ```bash
   curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://www.stridelikeaboss.com/api/tasks/claim
   ```

**Time:** 2-3 minutes

## What's in the Onboarding Response

### New Sections (Added for Agent Memory)

1. **memory_strategy** - How to remember across sessions
   - Universal approach (fetch this endpoint)
   - Platform-specific instructions (Claude, Cursor, Windsurf, etc.)
   - Example configuration snippets

2. **session_initialization** - Checklist for starting a session
   - 5 steps with commands and rationale
   - Progressive from setup to claiming tasks

3. **first_session_vs_returning** - Different paths for experience level
   - First-time: detailed 8-step process
   - Returning: quick 5-step refresh

4. **common_mistakes_agents_make** - Learn from errors
   - 8 critical mistakes with fixes
   - Consequences clearly explained

5. **quick_reference_card** - Ultra-condensed essentials
   - Workflow, files, endpoints, hooks
   - For experienced agents who just need a reminder

### Existing Sections (Already There)

- **critical_first_steps** - File creation requirements
- **overview** - What Stride is
- **quick_start** - Getting started
- **file_templates** - .stride.md and .stride_auth.md content
- **workflow** - API endpoints
- **hooks** - Hook system details
- **api_reference** - Complete API documentation
- **required_reading** - Documentation URLs
- **task_creation_requirements** - How to write good tasks
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
- Easy to update (modify agent_json.ex)

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
