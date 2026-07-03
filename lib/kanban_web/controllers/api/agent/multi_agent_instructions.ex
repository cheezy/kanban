defmodule KanbanWeb.API.Agent.MultiAgentInstructions do
  @moduledoc """
  The `multi_agent_instructions` block of the agent onboarding payload
  (per-tool plugin installation instructions), extracted verbatim from
  `KanbanWeb.API.AgentJSON` (W1442). Pure data.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  @doc "Per-tool installation instructions map for the onboarding payload."
  def instructions do
    %{
      description:
        "Always-active code completion guidance for AI assistants other than Claude Code. These provide essential Stride integration patterns without the contextual workflow enforcement of Claude Code Skills.",
      note:
        "Claude Code users should use the claude_code_skills section above for comprehensive workflow enforcement. Other AI assistants should download the appropriate format below.",
      installation_warning:
        "IMPORTANT: The installation commands will overwrite existing configuration files. If you have existing custom configurations, back them up first or append Stride instructions to your existing file. See usage_notes below for safer installation approaches.",
      formats: %{
        copilot: %{
          description:
            "Stride Copilot Plugin — provides 6 Copilot-adapted skills and 4 custom agents via copilot plugin install",
          plugin_repo: "https://github.com/cheezy/stride-copilot",
          skills_provided: [
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          custom_agents: [
            "task-explorer",
            "task-reviewer",
            "task-decomposer",
            "hook-diagnostician"
          ],
          installation_unix: "copilot plugin install https://github.com/cheezy/stride-copilot",
          installation_windows: "copilot plugin install https://github.com/cheezy/stride-copilot",
          update: "copilot plugin update stride-copilot",
          uninstall: "copilot plugin uninstall stride-copilot",
          note:
            "The stride-copilot plugin provides Copilot-adapted versions of all 6 Stride skills with tool-agnostic language and 4 custom agents. Install via copilot plugin install for automatic skill and agent discovery. See https://github.com/cheezy/stride-copilot for details.",
          fallback_note:
            "For manual installation of 7 generic skills as a fallback, install Claude Code skills from the claude_code_skills section above to .claude/skills/ — GitHub Copilot discovers them automatically."
        },
        cursor: %{
          file_path: ".cursor/skills/<skill-name>/SKILL.md (7 skills total)",
          description:
            "Stride skills for Cursor — 7 skills including the stride-workflow orchestrator, downloaded into .cursor/skills/ for auto-discovery. Skills now include G65 completion-validation guidance: `explorer_result`, `reviewer_result`, and `workflow_steps` are required fields on `/api/tasks/:id/complete`. See the stride-completing-tasks skill for the full schema.",
          compatible_tools: ["Cursor", "Claude Code"],
          skills_provided: [
            "stride-workflow",
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          installation_unix:
            "for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do mkdir -p .cursor/skills/$skill && curl -sL #{@docs_base_url}/docs/multi-agent-instructions/skills/$skill/SKILL.md -o .cursor/skills/$skill/SKILL.md; done",
          installation_windows:
            "$skills = @('stride-workflow','stride-claiming-tasks','stride-completing-tasks','stride-creating-tasks','stride-creating-goals','stride-enriching-tasks','stride-subagent-workflow'); foreach ($s in $skills) { New-Item -ItemType Directory -Force -Path \".cursor/skills/$s\" | Out-Null; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/skills/$s/SKILL.md\" -OutFile \".cursor/skills/$s/SKILL.md\" }",
          note:
            "Cursor automatically discovers skills in .cursor/skills/ directories. These 7 skills include the stride-workflow orchestrator (complete task lifecycle), enforcement gates (claiming gate, verification checklist), and reframed process-over-speed messaging. See https://cursor.com/docs/context/skills for details.",
          token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
          alternative_locations: [
            "Recommended: .cursor/skills/<skill-name>/SKILL.md (Cursor auto-discovers)",
            "Also works: .claude/skills/<skill-name>/SKILL.md (cross-compatible with Claude Code)",
            "Global: ~/.cursor/skills/<skill-name>/SKILL.md"
          ],
          safe_installation: %{
            check_existing:
              "ls -la .cursor/skills/stride-* 2>/dev/null | grep -c 'stride-' || echo '0 skills found'",
            backup_first:
              "for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do [ -f .cursor/skills/$skill/SKILL.md ] && cp .cursor/skills/$skill/SKILL.md .cursor/skills/$skill/SKILL.md.backup; done",
            usage:
              "Invoke the stride-workflow skill to start the complete task lifecycle. Individual skills are also available: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc. Cursor will automatically find skills in .cursor/skills/ directories."
          }
        },
        windsurf: %{
          file_path: ".windsurf/skills/<skill-name>/SKILL.md (7 skills total)",
          description:
            "Stride skills for Windsurf — 7 skills including the stride-workflow orchestrator, downloaded into .windsurf/skills/ for auto-discovery. Skills now include G65 completion-validation guidance: `explorer_result`, `reviewer_result`, and `workflow_steps` are required fields on `/api/tasks/:id/complete`. See the stride-completing-tasks skill for the full schema.",
          compatible_tools: ["Windsurf", "Claude Code"],
          skills_provided: [
            "stride-workflow",
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          installation_unix:
            "for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do mkdir -p .windsurf/skills/$skill && curl -sL #{@docs_base_url}/docs/multi-agent-instructions/skills/$skill/SKILL.md -o .windsurf/skills/$skill/SKILL.md; done",
          installation_windows:
            "$skills = @('stride-workflow','stride-claiming-tasks','stride-completing-tasks','stride-creating-tasks','stride-creating-goals','stride-enriching-tasks','stride-subagent-workflow'); foreach ($s in $skills) { New-Item -ItemType Directory -Force -Path \".windsurf/skills/$s\" | Out-Null; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/skills/$s/SKILL.md\" -OutFile \".windsurf/skills/$s/SKILL.md\" }",
          note:
            "Windsurf automatically discovers skills in .windsurf/skills/ directories. These 7 skills include the stride-workflow orchestrator (complete task lifecycle), enforcement gates (claiming gate, verification checklist), and reframed process-over-speed messaging. See https://docs.windsurf.com/windsurf/cascade/skills for details.",
          token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
          alternative_locations: [
            "Recommended: .windsurf/skills/<skill-name>/SKILL.md (Windsurf auto-discovers)",
            "Global: ~/.codeium/windsurf/skills/<skill-name>/SKILL.md"
          ],
          safe_installation: %{
            check_existing:
              "ls -la .windsurf/skills/stride-* 2>/dev/null | grep -c 'stride-' || echo '0 skills found'",
            backup_first:
              "for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do [ -f .windsurf/skills/$skill/SKILL.md ] && cp .windsurf/skills/$skill/SKILL.md .windsurf/skills/$skill/SKILL.md.backup; done",
            usage:
              "Invoke the stride-workflow skill to start the complete task lifecycle. Individual skills are also available: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc. Windsurf will automatically find skills in .windsurf/skills/ directories."
          }
        },
        continue: %{
          file_path: ".continue/skills/<skill-name>/SKILL.md (7 skills total)",
          description:
            "Stride skills for Continue.dev — 7 skills including the stride-workflow orchestrator, downloaded into .continue/skills/ for auto-discovery. Skills now include G65 completion-validation guidance: `explorer_result`, `reviewer_result`, and `workflow_steps` are required fields on `/api/tasks/:id/complete`. See the stride-completing-tasks skill for the full schema.",
          compatible_tools: ["Continue.dev"],
          skills_provided: [
            "stride-workflow",
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          installation_unix:
            "for skill in stride-workflow stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals stride-enriching-tasks stride-subagent-workflow; do mkdir -p .continue/skills/$skill && curl -sL #{@docs_base_url}/docs/multi-agent-instructions/skills/$skill/SKILL.md -o .continue/skills/$skill/SKILL.md; done",
          installation_windows:
            "$skills = @('stride-workflow','stride-claiming-tasks','stride-completing-tasks','stride-creating-tasks','stride-creating-goals','stride-enriching-tasks','stride-subagent-workflow'); foreach ($s in $skills) { New-Item -ItemType Directory -Force -Path \".continue/skills/$s\" | Out-Null; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/skills/$s/SKILL.md\" -OutFile \".continue/skills/$s/SKILL.md\" }",
          note:
            "Continue.dev discovers skills in .continue/skills/ directories (added Jan 2026). These 7 skills include the stride-workflow orchestrator (complete task lifecycle), enforcement gates (claiming gate, verification checklist), and reframed process-over-speed messaging.",
          token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
          supplemental_config: %{
            description:
              "Optional Continue.dev config.json with context providers (supplemental to skills)",
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/continue-config.json",
            installation_unix:
              "mkdir -p .continue && curl -o .continue/config.json #{@docs_base_url}/docs/multi-agent-instructions/continue-config.json",
            installation_windows:
              "New-Item -ItemType Directory -Force -Path .continue; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/continue-config.json\" -OutFile .continue/config.json"
          }
        },
        gemini: %{
          description:
            "Stride Gemini Extension — provides 6 Gemini-adapted skills and 4 custom agents via gemini extensions install",
          extension_repo: "https://github.com/cheezy/stride-gemini",
          skills_provided: [
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          custom_agents: [
            "task-explorer",
            "task-reviewer",
            "task-decomposer",
            "hook-diagnostician"
          ],
          installation_unix: "gemini extensions install https://github.com/cheezy/stride-gemini",
          installation_windows:
            "gemini extensions install https://github.com/cheezy/stride-gemini",
          note:
            "The stride-gemini extension provides Gemini-adapted versions of all 6 Stride skills with Gemini tool names and 4 custom agents with Gemini-specific parameters (temperature, max_turns, timeout_mins). Includes GEMINI.md bridge file for workflow enforcement. See https://github.com/cheezy/stride-gemini for details.",
          fallback_note:
            "For manual installation of 7 generic skills as a fallback, install Claude Code skills from the claude_code_skills section above to .gemini/skills/ — Gemini discovers them automatically."
        },
        opencode: %{
          description:
            "Stride OpenCode Plugin — provides 6 OpenCode-adapted skills, 4 custom agents, and automatic hook execution via npm plugin",
          plugin_repo: "https://github.com/cheezy/stride-opencode",
          skills_provided: [
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          agents_provided: [
            "task-explorer",
            "task-reviewer",
            "task-decomposer",
            "hook-diagnostician"
          ],
          installation_unix:
            "# Add to opencode.json:\n# {\"plugin\": [\"github:cheezy/stride-opencode\"]}\n# Or install locally:\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-opencode/main/install.sh | bash -s -- --project",
          installation_windows:
            "# Add to opencode.json:\n# {\"plugin\": [\"github:cheezy/stride-opencode\"]}\n# Or install locally (requires git):\ngit clone https://github.com/cheezy/stride-opencode.git && xcopy /E stride-opencode\\skills .opencode\\skills\\ && xcopy /E stride-opencode\\agents .opencode\\agents\\",
          note:
            "The stride-opencode plugin provides 6 OpenCode-adapted skills with OpenCode tool names, 4 custom agents, and a native TypeScript plugin for automatic hook execution via tool.execute.before/after events. Install via opencode.json plugin array or locally. See https://github.com/cheezy/stride-opencode for details.",
          fallback_note:
            "For manual installation, copy skills to .opencode/skills/ and agents to .opencode/agents/ from the GitHub repository."
        },
        codex: %{
          description:
            "Stride Codex CLI Plugin — provides 6 Codex-adapted skills and 4 subagents with manual hook execution",
          plugin_repo: "https://github.com/cheezy/stride-codex",
          skills_provided: [
            "stride-claiming-tasks",
            "stride-completing-tasks",
            "stride-creating-tasks",
            "stride-creating-goals",
            "stride-enriching-tasks",
            "stride-subagent-workflow"
          ],
          agents_provided: [
            "task-explorer",
            "task-reviewer",
            "task-decomposer",
            "hook-diagnostician"
          ],
          installation_unix:
            "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash",
          installation_windows:
            "git clone https://github.com/cheezy/stride-codex.git && xcopy /E stride-codex\\skills .agents\\skills\\ && xcopy /E stride-codex\\agents .agents\\agents\\ && copy stride-codex\\AGENTS.md AGENTS.md",
          note:
            "The stride-codex plugin provides 6 Codex-adapted skills with manual hook execution (Codex has no automatic hook interception). Skills instruct the agent to read .stride.md and execute commands directly. Install globally with the install script or copy files manually. See https://github.com/cheezy/stride-codex for details.",
          fallback_note:
            "For project-local installation, use: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project"
        },
        kimi: %{
          file_path: "AGENTS.md",
          description:
            "Kimi Code CLI (k2.5) instructions with stride-workflow orchestrator, verification checklist, enforcement messaging, and G65 completion-validation requirements (explorer_result, reviewer_result, workflow_steps required on /complete) — append-mode, always-active",
          compatible_tools: ["Kimi Code CLI (k2.5)"],
          download_url: "#{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
          installation_unix:
            "curl -s #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md",
          installation_windows:
            "Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md\" | Select-Object -ExpandProperty Content | Add-Content AGENTS.md",
          token_limit: "~8000-10000 tokens (~400-500 lines)",
          alternative_locations: [
            "Project root: ./AGENTS.md (project-specific)",
            "Append-mode: Content added to existing AGENTS.md"
          ],
          note:
            "Kimi Code CLI (k2.5) uses AGENTS.md for always-active instructions. If AGENTS.md exists, Stride instructions should be appended. The file is loaded automatically when Kimi starts.",
          safe_installation: %{
            check_existing: "[ -f AGENTS.md ] && echo 'AGENTS.md exists'",
            backup_first: "[ -f AGENTS.md ] && cp AGENTS.md AGENTS.md.backup",
            append_install:
              "echo '\\n\\n# === Stride Integration Instructions ===' >> AGENTS.md && curl -s #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md",
            fresh_install:
              "curl -o AGENTS.md #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
            usage:
              "Kimi automatically loads AGENTS.md when starting. No manual invocation needed."
          }
        }
      },
      usage_notes: [
        "These instructions complement Claude Code Skills by providing similar guidance for other AI assistants",
        "Choose the format that matches your AI assistant and download it using the commands above",
        "All formats cover the same core content: hook execution, critical mistakes, essential fields, code patterns",
        "Token limits vary by assistant - content is optimized accordingly",
        "Claude Code users should use claude_code_skills section above (not this section)",
        "GitHub Copilot users: RECOMMENDED: copilot plugin install https://github.com/cheezy/stride-copilot (6 skills + 4 agents). Fallback: install Claude Code skills to .claude/skills/",
        "Cursor users: Install 7 Stride skills (including stride-workflow orchestrator) to .cursor/skills/ - see multi_agent_instructions.cursor for curl commands",
        "Windsurf users: Install 7 Stride skills (including stride-workflow orchestrator) to .windsurf/skills/ - see multi_agent_instructions.windsurf for curl commands",
        "Gemini CLI users: RECOMMENDED: gemini extensions install https://github.com/cheezy/stride-gemini (6 skills + 4 agents). Fallback: install Claude Code skills to .gemini/skills/",
        "OpenCode users: RECOMMENDED: Add \"github:cheezy/stride-opencode\" to opencode.json plugin array (6 skills + 4 agents + auto hooks). Fallback: install skills to .opencode/skills/",
        "Codex CLI users: RECOMMENDED: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash (6 skills + 4 agents). Manual hook execution.",
        "Kimi Code CLI (k2.5) users: Enhanced AGENTS.md with stride-workflow orchestrator, verification checklist, and enforcement messaging. Append to existing AGENTS.md or create new"
      ],
      safe_installation: [
        "RECOMMENDED: Check if config file exists before overwriting: [ -f .cursorrules ] && echo 'File exists, backup first'",
        "RECOMMENDED: Backup existing config: cp .cursorrules .cursorrules.backup",
        "ALTERNATIVE: Append Stride instructions: echo '\\n\\n# Stride Integration' >> .cursorrules && curl -s [url] >> .cursorrules",
        "ALTERNATIVE: Download to temp location and manually merge: curl -o /tmp/stride-instructions.txt [url]",
        "For OpenCode: RECOMMENDED: Add to opencode.json plugin array. Local: install to .opencode/skills/ and .opencode/agents/",
        "For Codex CLI: Install globally with install.sh or copy skills to .agents/skills/ and agents to .agents/agents/",
        "For Kimi Code CLI (k2.5): Use append-mode installation to add Stride instructions to existing AGENTS.md",
        "For more details see: #{@docs_base_url}/docs/MULTI-AGENT-INSTRUCTIONS.md#manual-installation"
      ]
    }
  end
end
