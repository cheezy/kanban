defmodule KanbanWeb.API.Agent.SetupDocs do
  @moduledoc """
  Setup-documentation blocks of the agent onboarding payload — the file
  templates, memory strategy, session-initialization, and
  task-creation-requirements sections — extracted
  verbatim from `KanbanWeb.API.AgentJSON` (W1442). Pure data.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  @doc "The `file_templates` section of the onboarding payload."
  def file_templates(base_url) do
    %{
      stride_auth_md: """
      # Stride API Authentication

      **DO NOT commit this file to version control!**

      ## API Configuration

      - **API URL:** `#{base_url}`
      - **API Token:** `{{YOUR_TOKEN_HERE}}`
      - **User Email:** `{{YOUR_EMAIL}}`
      - **Token Name:** Development Agent

      ## Usage

      **Unix/Linux/macOS:**

      ```bash
      export STRIDE_API_TOKEN="{{YOUR_TOKEN_HERE}}"
      export STRIDE_API_URL="#{base_url}"

      curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \\
        $STRIDE_API_URL/api/tasks/next
      ```

      **Windows PowerShell:**

      ```powershell
      $env:STRIDE_API_TOKEN = "{{YOUR_TOKEN_HERE}}"
      $env:STRIDE_API_URL = "#{base_url}"

      curl -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
        $env:STRIDE_API_URL/api/tasks/next
      ```

      **Windows Users:** For complete setup instructions including WSL2, PowerShell, and Git Bash options, see #{base_url}/docs/WINDOWS-SETUP.md
      """,
      stride_md: """
      # Stride Configuration

      **Note:** Examples below use Unix/Linux/macOS bash syntax. Windows users should see #{base_url}/docs/WINDOWS-SETUP.md for PowerShell equivalents.

      ## before_doing

      Executes before starting work on a task (blocking, 60s timeout).

      ```bash
      echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
      git pull origin main
      # Add your setup commands here
      ```

      ## after_doing

      Executes after completing work (blocking, 120s timeout).
      If this fails, task completion should fail.

      ```bash
      echo "Running tests for $TASK_IDENTIFIER"
      # Run your tests here
      # mix test
      # npm test
      # pytest
      ```

      ## before_review

      Executes when task enters review (blocking, 60s timeout).
      If this fails, task completion should fail.

      ```bash
      echo "Creating PR for $TASK_IDENTIFIER"
      # gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
      ```

      ## after_review

      Executes after review approval (blocking, 60s timeout).
      If this fails, mark_reviewed should fail.

      ```bash
      echo "Deploying $TASK_IDENTIFIER"
      # Add deployment commands here
      ```
      """
    }
  end

  @doc "The `memory_strategy` section of the onboarding payload."
  def memory_strategy(base_url) do
    %{
      description:
        "How to ensure you remember this Stride context in future sessions across all AI coding platforms",
      universal_approach:
        "All agents should fetch this onboarding endpoint (#{base_url}/api/agent/onboarding) at the START of every new session before claiming any tasks",
      recommended_actions: [
        "1. Save this onboarding JSON response to a local file (e.g., .stride_onboarding.json) for quick reference during the session",
        "2. Create .stride_auth.md and .stride.md files from the templates if they don't exist",
        "3. Bookmark or save the documentation URLs for quick access",
        "4. If your agent platform supports project configuration, add Stride context to it (see agent_specific_instructions)"
      ],
      agent_specific_instructions: %{
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

          **Workflow:** before_doing hook → claim WITH result → work → after_doing hook → before_review hook → complete WITH both results → [if needs_review=false: after_review hook → claim next, else: stop]

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
            "2. This provides 6 Gemini-adapted skills + 4 custom agents + GEMINI.md bridge file",
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
            "2. This provides 6 Copilot-adapted skills + 4 custom agents",
            "3. Create .stride.md and .stride_auth.md files from the templates above",
            "4. Skills activate automatically when Stride API calls are made",
            "5. Update with: copilot plugin update stride-copilot",
            "FALLBACK: Install 7 generic skills from claude_code_skills section to .claude/skills/ directories"
          ],
          note:
            "The stride-copilot plugin provides Copilot-adapted skills with tool-agnostic language and 4 custom agents. Install via copilot plugin install for automatic discovery. See https://github.com/cheezy/stride-copilot for details."
        },
        opencode: %{
          description:
            "For OpenCode users — install the Stride OpenCode plugin (recommended) or use generic skills as fallback",
          steps: [
            "1. RECOMMENDED: Add to opencode.json: {\"plugin\": [\"github:cheezy/stride-opencode\"]}",
            "2. This provides 6 OpenCode-adapted skills + 4 custom agents + automatic hook execution",
            "3. Create .stride.md and .stride_auth.md files from the templates above",
            "4. Skills activate automatically when Stride API calls are made",
            "FALLBACK: Install locally: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-opencode/main/install.sh | bash -s -- --project"
          ],
          note:
            "The stride-opencode plugin provides OpenCode-adapted skills with OpenCode tool names and a native TypeScript plugin for automatic hook execution. See https://github.com/cheezy/stride-opencode for details."
        },
        codex: %{
          description: "For Codex CLI users — install the Stride Codex plugin",
          steps: [
            "1. RECOMMENDED: Install globally: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash",
            "2. This provides 6 Codex-adapted skills + 4 subagents",
            "3. Create .stride.md and .stride_auth.md files from the templates above",
            "4. Copy AGENTS.md to your project root: cp ~/.agents/AGENTS.md ./AGENTS.md",
            "PROJECT-LOCAL: curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project"
          ],
          note:
            "Codex CLI has no automatic hook interception. Skills instruct the agent to execute .stride.md hooks directly via shell. See https://github.com/cheezy/stride-codex for details."
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
    }
  end

  @doc "The `session_initialization` section of the onboarding payload."
  def session_initialization(base_url) do
    %{
      description:
        "Complete this checklist at the START of every new session before claiming tasks",
      checklist: [
        %{
          step: 1,
          action: "Fetch onboarding data",
          command: "curl #{base_url}/api/agent/onboarding",
          why: "Get latest workflow instructions and documentation links"
        },
        %{
          step: 2,
          action: "Verify .stride.md exists",
          command:
            "test -f .stride.md || echo 'Missing .stride.md - copy from onboarding file_templates.stride_md'",
          why: "Ensure hook scripts are available for task lifecycle"
        },
        %{
          step: 3,
          action: "Verify .stride_auth.md exists and is gitignored",
          command: "test -f .stride_auth.md && grep -q '.stride_auth.md' .gitignore",
          why: "Ensure authentication is configured and secrets are protected"
        },
        %{
          step: 4,
          action: "Read essential documentation (first-time or if rusty)",
          urls: [
            "#{@docs_base_url}/docs/AI-WORKFLOW.md",
            "#{@docs_base_url}/docs/TASK-WRITING-GUIDE.md"
          ],
          why: "Understand workflow sequence and task creation requirements"
        },
        %{
          step: 5,
          action: "Ready to claim tasks",
          command: "curl -H 'Authorization: Bearer YOUR_TOKEN' #{base_url}/api/tasks/claim",
          why: "Start working on Stride tasks"
        }
      ]
    }
  end

  @doc "The `task_creation_requirements` section of the onboarding payload."
  def task_creation_requirements do
    %{
      critical_importance:
        "CRITICAL: Always create DETAILED, RICH tasks following the Task Writing Guide. Agents that create minimal tasks with only title/description struggle and fail. Success requires comprehensive task specifications.",
      task_writing_guide_url: "#{@docs_base_url}/docs/TASK-WRITING-GUIDE.md",
      why_detailed_tasks_matter: [
        "Minimal tasks = 3+ hours of exploration and uncertainty",
        "Detailed tasks = 30 minutes of focused implementation",
        "Rich context prevents wrong approaches and wasted work",
        "Specific file paths and test scenarios eliminate guesswork"
      ],
      minimum_required_fields: [
        "title - Clear, specific description of the work",
        "type - 'work' or 'defect'",
        "description - WHY this matters and WHAT needs to be done",
        "complexity - Realistic estimate: small, medium, large",
        "key_files - ALWAYS specify files that will be modified (array of objects with file_path, note, position)",
        "acceptance_criteria - Specific, testable conditions for 'done' (newline-separated string)",
        "verification_steps - Commands and manual steps to verify success (array of objects with step_type, step_text, expected_result, position)"
      ],
      highly_recommended_fields: [
        "why - Why this task matters - business justification (string)",
        "what - What needs to be done - concise summary (string)",
        "where_context - Where in the codebase this work happens (string)",
        "dependencies - Tasks that must complete first (controls execution order). Use 0-based indices [0, 1] when creating goals with child tasks, or task identifiers ['W47', 'W48'] for existing tasks",
        "estimated_files - Estimated number of files to modify as a number or range (e.g., '2', '3-5', '5+') (string)",
        "patterns_to_follow - Specific coding patterns to replicate (newline-separated string)",
        "testing_strategy - Overall testing approach with edge cases, coverage goals, mocking strategy (JSON object)",
        "pitfalls - Common mistakes to avoid (array of strings)",
        "out_of_scope - What NOT to include in this task (array of strings)",
        "technology_requirements - Required technologies or libraries (array of strings)",
        "database_changes - Database schema or query changes (string)",
        "validation_rules - Data validation requirements (string)",
        "telemetry_event - Telemetry events to emit (string)",
        "metrics_to_track - Metrics to instrument (string)",
        "logging_requirements - What to log and at what level (string)",
        "error_user_message - User-facing error messages (string)",
        "error_on_failure - How to handle failures (string)",
        "security_considerations - Security concerns or requirements (array of strings)",
        "integration_points - Systems or APIs this touches (JSON object)"
      ],
      bad_example: %{
        title: "Add search feature",
        description: "Users need search",
        note: "This task will fail! Too vague, no context, no file paths, no tests specified"
      },
      good_example: %{
        title: "Add task search by title and description",
        type: "work",
        complexity: "medium",
        estimated_files: "2-3",
        description: "Add search input that filters tasks in real-time in the board view header.",
        why: "Users need to find tasks quickly without scrolling through long lists",
        what: "Add search input that filters tasks in real-time by title and description",
        where_context: "Board view header component",
        key_files: [
          %{
            file_path: "lib/kanban_web/live/board_live.ex",
            note: "Add search input and handle_event",
            position: 0
          },
          %{
            file_path: "lib/kanban/tasks.ex",
            note: "Add search_tasks/2 query function",
            position: 1
          }
        ],
        patterns_to_follow:
          "Use LiveView handle_event for input changes (see filter component in lib/kanban_web/live/board_live/filter_component.ex)\nDebounce search input to avoid excessive queries",
        acceptance_criteria:
          "Search input appears in board header\nTyping filters tasks in real-time\nSearch is case-insensitive\nSearches both title and description fields\nEmpty search shows all tasks",
        verification_steps: [
          %{
            step_type: "command",
            step_text: "mix test test/kanban/tasks_test.exs",
            expected_result: "All tests pass",
            position: 0
          },
          %{
            step_type: "command",
            step_text: "mix test test/kanban_web/live/board_live_test.exs",
            expected_result: "All tests pass",
            position: 1
          },
          %{
            step_type: "manual",
            step_text: "Navigate to board and type in search - tasks filter in real-time",
            expected_result: "Tasks filter as you type",
            position: 2
          }
        ],
        pitfalls: [
          "Don't modify task card layout",
          "Don't add sorting yet - that's a separate task"
        ],
        testing_strategy: %{
          unit_tests: "Test search_tasks/2 query function with various search terms",
          integration_tests: "Test LiveView search with live rendering and real-time updates",
          edge_cases: [
            "Empty search string shows all tasks",
            "Search with special characters",
            "Case sensitivity (should be case-insensitive)",
            "Partial matches in title and description"
          ],
          coverage_target: "100% for new search functions"
        },
        database_changes:
          "Use ILIKE for PostgreSQL case-insensitive search. Consider adding search index later for performance."
      },
      first_time_instructions: [
        "1. READ the Task Writing Guide completely: #{@docs_base_url}/docs/TASK-WRITING-GUIDE.md",
        "2. Study the good_example above - this is the level of detail required",
        "3. When creating your first tasks, include ALL minimum_required_fields",
        "4. Add highly_recommended_fields whenever possible - especially testing_strategy for comprehensive testing guidance",
        "5. Use proper formats: key_files and verification_steps are arrays of objects, testing_strategy is a JSON object, acceptance_criteria and patterns_to_follow are newline-separated strings",
        "6. Never create minimal tasks - they waste time and cause failure"
      ]
    }
  end
end
