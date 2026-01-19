# Multi-Agent Instructions

*Last Updated: January 9, 2026*

## Overview

Stride provides enhanced integration support for multiple AI coding assistants beyond Claude Code. While Claude Code uses contextual Skills for workflow enforcement, other AI assistants receive always-active code completion guidance through their native configuration formats.

**Core Principle:** Complement Claude Code Skills (contextual workflow enforcement) with always-active code completion guidance for other AI assistants.

**Supported AI Assistants:** GitHub Copilot, Cursor, Windsurf Cascade, Continue.dev, Google Gemini Code Assist

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

## Supported AI Assistants (5 Total)

### 1. GitHub Copilot

**File:** `.github/copilot-instructions.md`

**Location:** `docs/multi-agent-instructions/copilot-instructions.md`

**Scope:** Repository-scoped, always active

**Token Limit:** ~4000 tokens (~250 lines)

**Format:** Markdown with headings, lists, code blocks

**Download:**
```bash
curl -o .github/copilot-instructions.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/copilot-instructions.md
```

**Focus:**
- Very concise due to strict token limits
- Top 5 critical mistakes
- Essential code patterns
- Inline code completion hints

### 2. Cursor

**File:** `.cursorrules`

**Location:** `docs/multi-agent-instructions/cursorrules.txt`

**Scope:** Project-scoped, always active

**Token Limit:** ~8000 tokens (~400 lines)

**Format:** Plain text with clear section headers

**Download:**
```bash
curl -o .cursorrules \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt
```

**Focus:**
- More examples than Copilot due to higher token limit
- Detailed code patterns
- Comprehensive mistake catalog
- Hook execution details

### 3. Windsurf Cascade

**File:** `.windsurfrules`

**Location:** `docs/multi-agent-instructions/windsurfrules.txt`

**Scope:** Hierarchical, cascades from parent directories

**Token Limit:** ~8000 tokens (~400 lines)

**Format:** Plain text, similar to Cursor

**Download:**
```bash
curl -o .windsurfrules \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/windsurfrules.txt
```

**Focus:**
- Same core content as Cursor
- Can be placed in parent directory for multi-project use
- Cascading rules inheritance

**Placement Options:**
- Project root: `./project/.windsurfrules`
- Parent directory: `/parent/.windsurfrules` (affects all child projects)

### 4. Continue.dev

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

### 5. Google Gemini Code Assist

**File:** `GEMINI.md` (or `AGENT.md` for IntelliJ)

**Location:** `docs/multi-agent-instructions/GEMINI.md`

**Scope:** Project-scoped with hierarchical context support

**Token Limit:** ~8000 tokens (~400 lines)

**Format:** Markdown with headings, lists, code blocks

**Download:**
```bash
curl -o GEMINI.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md
```

**Alternative Locations:**
- Project root: `./GEMINI.md` or `./AGENT.md` (IntelliJ)
- Global: `~/.gemini/GEMINI.md` (applies to all projects)
- Component-level: Place in subdirectories for context override

**Focus:**
- Detailed code patterns with Markdown formatting
- Comprehensive mistake catalog
- Hook execution details
- Context file hierarchy support (subdirectories override parent)

## Content Strategy

### Core Content (All Formats)

All five instruction formats cover the same essential topics:

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

### Format-Specific Adaptations

**Copilot (Markdown):**
- Use headings, lists, code blocks
- Very concise due to token limits
- Focus on inline code completion hints

**Cursor (Plain Text):**
- Similar to Copilot but can be slightly longer
- Emphasize patterns for code generation

**Windsurf (Plain Text):**
- Similar to Cursor
- Can include slightly more context

**Continue.dev (JSON):**
- System message with core rules
- Custom context provider for external docs
- Can reference documentation files directly

**Gemini (Markdown):**
- Rich formatting with headings, lists, code blocks
- Similar depth to Cursor/Windsurf formats
- Supports hierarchical context (subdirectories override parent)
- Can use either GEMINI.md or AGENT.md filename

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
        "file_path": ".github/copilot-instructions.md",
        "description": "GitHub Copilot instructions",
        "download_url": "https://raw.githubusercontent.com/.../copilot-instructions.md",
        "installation_unix": "curl -o .github/copilot-instructions.md [url]",
        "installation_windows": "Invoke-WebRequest -Uri \"[url]\" -OutFile ...",
        "token_limit": "~4000 tokens (~250 lines)"
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
├── copilot-instructions.md    # 9KB
├── cursorrules.txt            # 15KB
├── windsurfrules.txt          # 15KB
├── continue-config.json       # 4KB
└── GEMINI.md                  # 15KB
```

Total size: ~58KB of instruction content

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
2. Agent identifies its type (Copilot, Cursor, Windsurf, Continue.dev, Gemini)
3. Agent extracts the `download_url` for its format
4. Agent executes the appropriate `installation_unix` or `installation_windows` command
5. Instruction file is placed in the correct location

### Manual Installation

Developers can manually download instruction files. **IMPORTANT:** These commands will overwrite existing configuration files. If you have existing custom configurations, consider backing them up first or manually merging the Stride instructions.

**Check for existing files first:**
```bash
# Check which files already exist
ls -la .github/copilot-instructions.md .cursorrules .windsurfrules .continue/config.json GEMINI.md AGENT.md 2>/dev/null
```

**Backup existing files (recommended):**
```bash
# Backup existing configuration before installing
[ -f .github/copilot-instructions.md ] && cp .github/copilot-instructions.md .github/copilot-instructions.md.backup
[ -f .cursorrules ] && cp .cursorrules .cursorrules.backup
[ -f .windsurfrules ] && cp .windsurfrules .windsurfrules.backup
[ -f .continue/config.json ] && cp .continue/config.json .continue/config.json.backup
[ -f GEMINI.md ] && cp GEMINI.md GEMINI.md.backup
[ -f AGENT.md ] && cp AGENT.md AGENT.md.backup
```

**Download Stride instructions:**

**GitHub Copilot:**
```bash
curl -o .github/copilot-instructions.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/copilot-instructions.md
```

**Cursor:**
```bash
curl -o .cursorrules \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt
```

**Windsurf:**
```bash
curl -o .windsurfrules \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/windsurfrules.txt
```

**Continue.dev:**
```bash
mkdir -p .continue
curl -o .continue/config.json \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json
```

**Google Gemini Code Assist:**
```bash
curl -o GEMINI.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md
```

Alternative for IntelliJ users:
```bash
curl -o AGENT.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md
```

For global installation (applies to all projects):
```bash
mkdir -p ~/.gemini
curl -o ~/.gemini/GEMINI.md \
  https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md
```

**Merging with existing configuration:**

If you have existing custom instructions, you may want to manually merge them:

1. **Download to a temporary location:**
   ```bash
   curl -o /tmp/stride-copilot-instructions.md \
     https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/copilot-instructions.md
   ```

2. **Manually review and merge** the Stride-specific sections into your existing file, or

3. **Append Stride instructions** to your existing configuration (for formats that support it):
   ```bash
   # For text-based formats like Cursor/Windsurf
   echo "\n\n# === Stride Integration Instructions ===" >> .cursorrules
   curl -s https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt >> .cursorrules
   ```

### Windows Installation

**PowerShell:**

**IMPORTANT:** These commands will overwrite existing files. Back up first if you have custom configurations.

**Check for existing files:**
```powershell
Get-Item .github/copilot-instructions.md, .cursorrules, .windsurfrules, .continue/config.json, GEMINI.md, AGENT.md -ErrorAction SilentlyContinue
```

**Backup existing files (recommended):**
```powershell
if (Test-Path .github/copilot-instructions.md) { Copy-Item .github/copilot-instructions.md .github/copilot-instructions.md.backup }
if (Test-Path .cursorrules) { Copy-Item .cursorrules .cursorrules.backup }
if (Test-Path .windsurfrules) { Copy-Item .windsurfrules .windsurfrules.backup }
if (Test-Path .continue/config.json) { Copy-Item .continue/config.json .continue/config.json.backup }
if (Test-Path GEMINI.md) { Copy-Item GEMINI.md GEMINI.md.backup }
if (Test-Path AGENT.md) { Copy-Item AGENT.md AGENT.md.backup }
```

**Download Stride instructions:**
```powershell
# GitHub Copilot
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/copilot-instructions.md" -OutFile .github/copilot-instructions.md

# Cursor
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt" -OutFile .cursorrules

# Windsurf
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/windsurfrules.txt" -OutFile .windsurfrules

# Continue.dev
New-Item -ItemType Directory -Force -Path .continue
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json" -OutFile .continue/config.json

# Google Gemini Code Assist
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md" -OutFile GEMINI.md

# Or for IntelliJ users
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md" -OutFile AGENT.md

# For global installation
New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.gemini
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/GEMINI.md" -OutFile $env:USERPROFILE\.gemini\GEMINI.md
```

**Appending to existing configuration:**
```powershell
# For text-based formats like Cursor/Windsurf
"`n`n# === Stride Integration Instructions ===" | Add-Content .cursorrules
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt" | Select-Object -ExpandProperty Content | Add-Content .cursorrules
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
| **Target Assistants** | Claude Code only | Copilot, Cursor, Windsurf, Continue.dev, Gemini |
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
