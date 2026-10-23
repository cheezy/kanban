defmodule KanbanWeb.API.Agent.AgentSpecificInstructions do
  @moduledoc """
  The `memory_strategy.agent_specific_instructions` block of the agent
  onboarding payload: per-assistant steps for keeping Stride context across
  sessions and installing that assistant's Stride plugin or skills.
  Extracted from `KanbanWeb.API.Agent.SetupDocs` (D390). Pure data.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  @doc "Per-assistant instructions map, keyed by assistant."
  def instructions(base_url) do
    %{
      claude_code: %{
        description: "For Claude Code users working in their own projects",
        steps: [
          "1. Add to .claudeproject file in 'contextFiles' array: [\".stride.md\", \".stride_auth.md\"]",
          "2. Optionally create a custom slash command /stride that fetches this onboarding endpoint",
          "3. Add a Stride section to your project's AGENTS.md or README.md with the essential workflow"
        ],
        example_agents_md_section: """
        ## STRIDE TASK MANAGEMENT

        This project uses Stride for AI task management.

        **Setup:** Fetch onboarding at #{base_url}/api/agent/onboarding

        **Workflow:** before_doing hook → claim WITH result → work → after_doing hook → before_review hook → complete WITH both results → [if needs_review=false: after_review hook → claim next, else: stop] → [after a goal's last child: after_goal hook → PATCH /api/tasks/:goal_id/after_goal]

        **Files:** .stride.md (hooks), .stride_auth.md (token, gitignored)

        **Docs:** #{@docs_base_url}/docs/AI-WORKFLOW.md
        """
      },
      cursor: %{
        description:
          "For Cursor users — install 7 Stride skills including the stride-workflow orchestrator",
        steps: [
          "1. Install all 7 Stride skills: run the installation command from multi_agent_instructions.cursor.installation_unix above",
          "2. Cursor automatically discovers skills in .cursor/skills/ - no additional configuration needed",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Invoke stride-workflow to start the complete task lifecycle (claim → explore → implement → review → complete)",
          "5. Individual skills are also available: 'stride-claiming-tasks', 'stride-completing-tasks', etc.",
          "6. Skills include the workflow orchestrator, enforcement gates, and all task creation formats"
        ],
        note:
          "Cursor automatically discovers skills in .cursor/skills/ directories. The 7 Stride skills include stride-workflow (orchestrator), stride-claiming-tasks (with claiming gate), stride-completing-tasks (with verification checklist), stride-creating-tasks, stride-creating-goals, stride-enriching-tasks, and stride-subagent-workflow."
      },
      windsurf: %{
        description:
          "For Windsurf users — install 7 Stride skills including the stride-workflow orchestrator",
        steps: [
          "1. Install all 7 Stride skills: run the installation command from multi_agent_instructions.windsurf.installation_unix above",
          "2. Windsurf automatically discovers skills in .windsurf/skills/ - no additional configuration needed",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Invoke stride-workflow to start the complete task lifecycle (claim → explore → implement → review → complete)",
          "5. Individual skills are also available: 'stride-claiming-tasks', 'stride-completing-tasks', etc.",
          "6. Skills include the workflow orchestrator, enforcement gates, and all task creation formats"
        ],
        note:
          "Windsurf automatically discovers skills in .windsurf/skills/ directories. The 7 Stride skills include stride-workflow (orchestrator), stride-claiming-tasks (with claiming gate), stride-completing-tasks (with verification checklist), stride-creating-tasks, stride-creating-goals, stride-enriching-tasks, and stride-subagent-workflow."
      },
      gemini: %{
        description:
          "For Gemini CLI users — install the Stride Gemini extension (recommended) or use generic skills as fallback",
        steps: [
          "1. RECOMMENDED: Install the Stride Gemini extension: gemini extensions install https://github.com/cheezy/stride-gemini",
          "2. This provides 7 Gemini-adapted skills + 5 custom agents + GEMINI.md bridge file",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Skills activate automatically when Stride API calls are made",
          "FALLBACK: Install 7 generic skills from claude_code_skills section to .gemini/skills/ directories"
        ],
        note:
          "The stride-gemini extension provides Gemini-adapted skills with Gemini tool names (run_shell_command, read_file, grep_search, etc.) and custom agents with Gemini-specific parameters. See https://github.com/cheezy/stride-gemini for details."
      },
      aider: %{
        description: "For Aider users",
        steps: [
          "1. Add .stride.md to your .aider.conf.yml read_files list",
          "2. Create .stride_auth.md with your API token",
          "3. Set environment variables STRIDE_API_URL=#{base_url} and STRIDE_API_TOKEN=<your_token>"
        ]
      },
      cline: %{
        description: "For Cline users",
        steps: [
          "1. Add .stride.md to your custom instructions or project documentation",
          "2. Create .stride_auth.md with your API token and add to .gitignore",
          "3. Reference this onboarding URL in your project's README or setup docs"
        ]
      },
      copilot: %{
        description:
          "For GitHub Copilot CLI users — install the Stride Copilot plugin (recommended) or use generic skills as fallback",
        steps: [
          "1. RECOMMENDED: Install the Stride Copilot plugin: copilot plugin install https://github.com/cheezy/stride-copilot",
          "2. This provides 7 Copilot-adapted skills + 5 custom agents",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Skills activate automatically when Stride API calls are made",
          "5. Update with: copilot plugin update stride-copilot",
          "FALLBACK: Install 7 generic skills from claude_code_skills section to .claude/skills/ directories"
        ],
        note:
          "The stride-copilot plugin provides Copilot-adapted skills with tool-agnostic language and 5 custom agents. Install via copilot plugin install for automatic discovery. See https://github.com/cheezy/stride-copilot for details."
      },
      opencode: %{
        description:
          "For OpenCode users — install the Stride OpenCode plugin (recommended) or use generic skills as fallback",
        steps: [
          "1. RECOMMENDED: Add to opencode.json: {\"plugin\": [\"github:cheezy/stride-opencode\"]}",
          "2. Copy the skills and agents into the project, because OpenCode does not discover skills inside an installed plugin: src=$(mktemp -d) && git clone https://github.com/cheezy/stride-opencode.git \"$src/stride-opencode\" && mkdir -p .opencode/skills .opencode/agents && cp -R \"$src/stride-opencode/skills/.\" .opencode/skills/ && cp \"$src/stride-opencode/agents/\"*.md .opencode/agents/",
          "3. This provides 7 OpenCode-adapted skills + 5 custom agents + automatic hook execution",
          "4. Create .stride.md and .stride_auth.md files from the templates above",
          "5. Skills activate automatically when Stride API calls are made"
        ],
        note:
          "The stride-opencode plugin provides OpenCode-adapted skills with OpenCode tool names and a native TypeScript plugin for automatic hook execution. The plugin runs your hooks; the skills and agents are copied into .opencode/skills/ and .opencode/agents/ (or ~/.config/opencode/ for a global install). See https://github.com/cheezy/stride-opencode for details."
      },
      codex: %{
        description: "For Codex CLI users — install the Stride Codex plugin",
        steps: [
          "1. RECOMMENDED: Install globally: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash",
          "2. This provides 7 Codex-adapted skills + 5 subagents",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Copy AGENTS.md to your project root: cp ~/.agents/AGENTS.md ./AGENTS.md",
          "PROJECT-LOCAL: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project"
        ],
        note:
          "Codex CLI has no automatic hook interception. Skills instruct the agent to execute .stride.md hooks directly via shell. See https://github.com/cheezy/stride-codex for details."
      },
      pi: %{
        description: "For Pi users — install the Stride Pi plugin",
        steps: [
          "1. RECOMMENDED: Download the install script: curl -fsSLo stride-pi-install.sh https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh",
          "2. Read stride-pi-install.sh, then run it: bash stride-pi-install.sh to install globally, or bash stride-pi-install.sh --project for this project only",
          "3. This provides 11 Pi skills: the 7 Stride skills plus 4 that stand in for subagents (stride-task-explorer, stride-task-reviewer, stride-task-decomposer, stride-hook-diagnostician)",
          "4. Create .stride.md and .stride_auth.md files from the templates above",
          "5. Pi lists the skills it discovered when it starts; check that the Stride skills are among them"
        ],
        note:
          "The default install also adds the Pi extensions that run your .stride.md hooks automatically. Pi has no separate ideation plugin yet. See https://github.com/cheezy/stride-pi for details."
      },
      kimi: %{
        description: "For Kimi Code CLI (k2.5) users",
        steps: [
          "1. If AGENTS.md exists, append Stride instructions: echo '\\n\\n# === Stride Integration Instructions ===' >> AGENTS.md && curl -s #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md",
          "2. If AGENTS.md doesn't exist, create it: curl -o AGENTS.md #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Kimi automatically loads AGENTS.md when starting",
          "5. No manual invocation needed - instructions are always active"
        ],
        note:
          "Kimi Code CLI (k2.5) uses AGENTS.md for always-active instructions. If you have existing content in AGENTS.md, use append-mode to add Stride instructions."
      },
      generic: %{
        description: "For any AI coding agent",
        steps: [
          "1. Store this onboarding URL in your project documentation: #{base_url}/api/agent/onboarding",
          "2. Fetch this endpoint at the start of each session before working with Stride",
          "3. Create .stride.md and .stride_auth.md files from the templates above",
          "4. Add .stride_auth.md to .gitignore (CRITICAL - contains secrets)"
        ]
      }
    }
  end
end
