defmodule KanbanWeb.API.Agent.SetupDocs do
  @moduledoc """
  Setup-documentation blocks of the agent onboarding payload — the file
  templates, memory strategy, session-initialization, and
  task-creation-requirements sections — extracted
  verbatim from `KanbanWeb.API.AgentJSON` (W1442). Pure data.

  The memory strategy's per-assistant `agent_specific_instructions` live in
  `KanbanWeb.API.Agent.AgentSpecificInstructions` (D390).
  """

  alias Kanban.Hooks
  alias KanbanWeb.API.Agent.AgentSpecificInstructions

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  @doc """
  Each hook's blocking flag and timeout as onboarding text, keyed by hook
  name: `%{"before_doing" => "blocking, 600s", ...}`. Read from
  `Kanban.Hooks`, so the text matches the metadata the server sends.
  """
  def hook_terms do
    Map.new(Hooks.list_hooks(), fn {name, config} ->
      blocking = if config.blocking, do: "blocking", else: "non-blocking"
      {name, "#{blocking}, #{div(config.timeout, 1000)}s"}
    end)
  end

  # The when and typical_use text of each hook in Kanban.Hooks.list_hooks/0.
  @hook_usage %{
    "before_doing" => %{when: "Before starting work on a task", typical_use: "Pull latest code"},
    "after_doing" => %{
      when: "After completing work",
      typical_use: "Rebase, run tests, build project, lint code"
    },
    "before_review" => %{
      when: "When task enters review",
      typical_use: "Create PR, generate documentation"
    },
    "after_review" => %{
      when: "After review approval",
      typical_use: "Merge PR, deploy to production"
    },
    "after_goal" => %{
      when: "After the last open child task of a goal is done",
      typical_use: "Push the goal's work, cut a release"
    }
  }

  @doc """
  The `hooks.available_hooks` list of the onboarding payload: every hook in
  `Kanban.Hooks.list_hooks/0`, in order, with its blocking flag, timeout (ms),
  when it runs and what it is typically used for.
  """
  def hook_info do
    Enum.map(Hooks.list_hooks(), fn {name, config} ->
      %{
        name: name,
        blocking: config.blocking,
        timeout: config.timeout,
        when: get_in(@hook_usage, [name, :when]),
        typical_use: get_in(@hook_usage, [name, :typical_use])
      }
    end)
  end

  @doc "The names of the blocking hooks, in order, joined with commas."
  def blocking_hook_names do
    Hooks.list_hooks()
    |> Enum.filter(fn {_name, config} -> config.blocking end)
    |> Enum.map_join(", ", &elem(&1, 0))
  end

  @doc "The `file_templates` section of the onboarding payload."
  def file_templates(base_url) do
    terms = hook_terms()

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

      curl.exe -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
        "$env:STRIDE_API_URL/api/tasks/next"
      ```

      Type `curl.exe`, not `curl`: in Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`, which takes different arguments and fails on this command.

      **Windows Users:** For complete setup instructions including WSL2, PowerShell, and Git Bash options, see #{@docs_base_url}/docs/WINDOWS-SETUP.md
      """,
      stride_md: """
      # Stride Configuration

      **Note:** Examples below use Unix/Linux/macOS bash syntax. Windows users should see #{@docs_base_url}/docs/WINDOWS-SETUP.md for PowerShell equivalents.

      ## before_doing

      Executes before starting work on a task (#{terms["before_doing"]} timeout).

      ```bash
      echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
      git pull origin main
      # Add your setup commands here
      ```

      ## after_doing

      Executes after completing work (#{terms["after_doing"]} timeout).
      If this fails, task completion should fail.

      ```bash
      echo "Running tests for $TASK_IDENTIFIER"
      # Run your tests here
      # mix test
      # npm test
      # pytest
      ```

      ## before_review

      Executes when task enters review (#{terms["before_review"]} timeout).
      If this fails, task completion should fail.

      ```bash
      echo "Creating PR for $TASK_IDENTIFIER"
      # gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
      ```

      ## after_review

      Executes after review approval (#{terms["after_review"]} timeout).
      If this fails, mark_reviewed should fail.

      ```bash
      echo "Deploying $TASK_IDENTIFIER"
      # Add deployment commands here
      ```

      ## after_goal

      Executes once, when the last task of a goal is done (#{terms["after_goal"]} timeout).
      Report its result with PATCH /api/tasks/:id/after_goal, where :id is the goal.
      The goal moves to Done only when the reported exit code is 0.

      ```bash
      echo "Goal finished with $TASK_IDENTIFIER"
      # git push origin main
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
      agent_specific_instructions: AgentSpecificInstructions.instructions(base_url)
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
          command:
            "curl -X POST -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' -d '{\"agent_name\": \"YOUR_AGENT_NAME\", \"before_doing_result\": {\"exit_code\": 0, \"output\": \"\", \"duration_ms\": 0}}' #{base_url}/api/tasks/claim",
          why:
            "Start working on Stride tasks. Claiming is a POST; before_doing_result carries the exit_code, output and duration_ms of your before_doing hook"
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
