defmodule KanbanWeb.API.AgentJSON do
  alias Kanban.Hooks

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"
  @skills_version "1.0"

  def skills_version, do: @skills_version

  def onboarding(%{base_url: base_url}) do
    %{
      "⚠️⚠️⚠️_STOP_DO_NOT_PROCEED_UNTIL_SETUP_COMPLETE_⚠️⚠️⚠️": %{
        YOU_MUST_COMPLETE_THESE_STEPS_FIRST:
          "The steps below are NOT optional. You CANNOT authenticate or use the API without completing setup. DO NOT skip to other sections.",
        WHY_THIS_IS_MANDATORY:
          "You cannot authenticate with the API without .stride_auth.md. You cannot execute hooks without .stride.md. These files are prerequisites for ALL API calls.",
        SETUP_TAKES: "2-3 minutes if files don't exist, <30 seconds if they do",
        DO_THIS_NOW:
          "Complete ALL steps in MANDATORY_SETUP_CHECKLIST below before reading anything else"
      },
      MANDATORY_SETUP_CHECKLIST: %{
        COMPLETE_ALL_STEPS_IN_ORDER: true,
        STEP_1_CHECK_stride_auth_md: %{
          order: 1,
          action: "Check if .stride_auth.md exists",
          tool_to_use:
            "Bash tool with: test -f .stride_auth.md && echo 'EXISTS' || echo 'MISSING'",
          if_missing: "Proceed to STEP_2_CREATE_stride_auth_md",
          if_exists: "Skip to STEP_3_CHECK_gitignore"
        },
        STEP_2_CREATE_stride_auth_md: %{
          order: 2,
          action: "Create .stride_auth.md using Write tool",
          condition: "ONLY if STEP_1 showed MISSING",
          tool_to_use: "Write tool",
          file_path: ".stride_auth.md",
          content_source:
            "Copy EXACT content from file_templates.stride_auth_md section below (scroll down to find it)",
          critical_warnings: [
            "DO NOT modify the template content",
            "DO NOT remove the {{YOUR_TOKEN_HERE}} placeholder",
            "DO NOT summarize or truncate - copy character-for-character",
            "This file will contain secrets - it MUST be added to .gitignore"
          ]
        },
        STEP_3_CHECK_gitignore: %{
          order: 3,
          action: "Verify .stride_auth.md is in .gitignore",
          tool_to_use:
            "Bash tool with: grep -q '.stride_auth.md' .gitignore && echo 'PROTECTED' || echo 'EXPOSED'",
          if_exposed: "Proceed to STEP_4_ADD_TO_gitignore",
          if_protected: "Skip to STEP_5_CHECK_stride_md",
          why_critical:
            "SECURITY: .stride_auth.md contains API tokens. If committed to git, tokens are exposed publicly."
        },
        STEP_4_ADD_TO_gitignore: %{
          order: 4,
          action: "Add .stride_auth.md to .gitignore",
          condition: "ONLY if STEP_3 showed EXPOSED",
          tool_to_use:
            "Edit tool (if .gitignore exists) or Write tool (if .gitignore doesn't exist)",
          content_to_add: ".stride_auth.md",
          verification: "Run: grep '.stride_auth.md' .gitignore"
        },
        STEP_5_CHECK_stride_md: %{
          order: 5,
          action: "Check if .stride.md exists",
          tool_to_use: "Bash tool with: test -f .stride.md && echo 'EXISTS' || echo 'MISSING'",
          if_missing: "Proceed to STEP_6_CREATE_stride_md",
          if_exists: "Skip to STEP_7_INSTALL_SKILLS"
        },
        STEP_6_CREATE_stride_md: %{
          order: 6,
          action: "Create .stride.md using Write tool",
          condition: "ONLY if STEP_5 showed MISSING",
          tool_to_use: "Write tool",
          file_path: ".stride.md",
          content_source:
            "Copy EXACT content from file_templates.stride_md section below (scroll down to find it)",
          critical_warnings: [
            "DO NOT modify the template content",
            "DO NOT summarize or truncate - copy character-for-character",
            "This file defines hook execution scripts"
          ]
        },
        STEP_7_INSTALL_SKILLS: %{
          order: 7,
          action: "Install Stride skills plugin",
          condition: "ONLY for Claude Code. Other AI assistants skip this step.",
          if_not_claude_code: "Skip to STEP_8_NOTIFY_USER",
          if_claude_code: "Install the Stride marketplace and plugin using slash commands",
          installation_steps: [
            "1. Run: /plugin marketplace add cheezy/stride-marketplace",
            "2. Run: /plugin install stride@stride-marketplace",
            "3. The 4 Stride skills will be automatically available"
          ],
          verification:
            "The skills will appear in your skill list automatically after installation",
          note_skills_version: "Plugin version tracks skill versions automatically"
        },
        STEP_8_NOTIFY_USER: %{
          order: 8,
          action: "Notify user about API token",
          message_to_user:
            "IMPORTANT: You must edit .stride_auth.md and replace {{YOUR_TOKEN_HERE}} with your actual API token. Get your token from #{base_url}",
          why:
            "API token is secret and cannot be included in this response. User must provide it.",
          user_must_do: "Edit .stride_auth.md manually to add their token"
        },
        STEP_9_SETUP_COMPLETE: %{
          order: 9,
          action: "Setup verification complete",
          next_steps: "After user adds their API token, you can proceed to use the API",
          now_you_can:
            "Read the rest of this onboarding response to understand workflows and task creation"
        }
      },
      SETUP_COMPLETION_CONFIRMATION: %{
        BEFORE_PROCEEDING_VERIFY:
          "You have completed ALL 9 steps in MANDATORY_SETUP_CHECKLIST above",
        FILES_THAT_SHOULD_EXIST: [
          ".stride_auth.md (with API token placeholder)",
          ".stride.md (with hook definitions)",
          ".gitignore (containing .stride_auth.md)",
          "Stride plugin installed (Claude Code only - via /plugin install stride@stride-marketplace)"
        ],
        USER_ACTION_REQUIRED:
          "User must edit .stride_auth.md to add their API token before you can use the API"
      },
      version: "1.0",
      skills_version: @skills_version,
      api_schema: api_schema(),
      api_base_url: base_url,
      overview: %{
        description:
          "Stride is a kanban-based task management system designed for AI agents with integrated workflow hooks.",
        workflow_summary: "Ready → Doing → Review → Done",
        key_features: [
          "Client-side hook execution at four lifecycle points",
          "Atomic task claiming with capability matching",
          "Optional human review workflow",
          "Automatic dependency management",
          "Goal hierarchy for multi-task projects"
        ],
        agent_workflow_pattern:
          "Agents should work continuously: claim task → complete → IF needs_review=false THEN claim next task, ELSE stop and wait for review. Continue this loop until encountering a task that needs review or running out of available tasks."
      },
      quick_start: [
        "Windows users: See #{base_url}/docs/WINDOWS-SETUP.md for platform-specific setup (WSL2/PowerShell/Git Bash) before proceeding",
        "1. Check if .stride_auth.md exists - if NOT, create by copying the ENTIRE file_templates.stride_auth_md content exactly",
        "2. Check if .stride_auth.md is in .gitignore - if NOT, add it (CRITICAL - contains secrets)",
        "3. Check if .stride.md exists - if NOT, create by copying the ENTIRE file_templates.stride_md content exactly",
        "4. IF you are Claude Code: Install the Stride plugin by running /plugin marketplace add cheezy/stride-marketplace and then /plugin install stride@stride-marketplace. Other AI assistants: skip this step (use multi_agent_instructions)",
        "5. Edit .stride_auth.md and replace {{YOUR_TOKEN_HERE}} with your actual API token",
        "6. Verify authentication: curl -H \"Authorization: Bearer YOUR_TOKEN\" #{base_url}/api/tasks/next",
        "7. Call POST #{base_url}/api/tasks/claim to get your first task (requires before_doing_result)",
        "8. Execute hooks and complete your work following the workflow"
      ],
      file_templates: %{
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
      },
      claude_code_skills: %{
        description: "Stride skills are distributed as a Claude Code marketplace plugin.",
        installation:
          "Run these two commands: /plugin marketplace add cheezy/stride-marketplace && /plugin install stride@stride-marketplace",
        plugin_repository: "https://github.com/cheezy/stride",
        marketplace_repository: "https://github.com/cheezy/stride-marketplace",
        skills_included: [
          "stride-claiming-tasks",
          "stride-completing-tasks",
          "stride-creating-tasks",
          "stride-creating-goals"
        ]
      },
      workflow: [
        %{
          name: "claim_task",
          endpoint: "POST #{base_url}/api/tasks/claim",
          description:
            "Claim next available task matching your capabilities. Claims automatically expire after 60 minutes if not completed, releasing the task for other agents. REQUIRES before_doing_result parameter with proof of hook execution.",
          required_parameters: ["before_doing_result"],
          hook_validation:
            "MANDATORY - Must execute before_doing hook BEFORE calling this endpoint and include result",
          returns: "Task data + before_doing hook metadata",
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_claim.md"
        },
        %{
          name: "complete_task",
          endpoint: "PATCH #{base_url}/api/tasks/:id/complete",
          description:
            "Mark task as complete. If needs_review=false, task moves to Done (claim next task immediately). If needs_review=true, task moves to Review (stop and wait for human review). REQUIRES after_doing_result AND before_review_result parameters with proof of hook execution.",
          required_parameters: ["after_doing_result", "before_review_result"],
          hook_validation:
            "MANDATORY - Must execute BOTH after_doing AND before_review hooks BEFORE calling this endpoint and include both results",
          returns: "Task data + array of hook metadata (after_review if needs_review=false)",
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
        },
        %{
          name: "mark_reviewed",
          endpoint: "PATCH #{base_url}/api/tasks/:id/mark_reviewed",
          description:
            "Finalize review after human reviewer sets status. REQUIRES after_review_result parameter with proof of hook execution.",
          required_parameters: ["after_review_result"],
          hook_validation:
            "MANDATORY - Must execute after_review hook BEFORE calling this endpoint and include result",
          returns: "Task data",
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_mark_reviewed.md"
        },
        %{
          name: "unclaim_task",
          endpoint: "POST #{base_url}/api/tasks/:id/unclaim",
          description: "Release a claimed task if unable to complete",
          returns: "Task data",
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_id_unclaim.md"
        }
      ],
      hooks: %{
        description:
          "Hooks execute on YOUR machine, not the server. Server provides metadata only.",
        available_hooks: build_hook_info(),
        environment_variables: [
          "TASK_ID - Numeric task ID",
          "TASK_IDENTIFIER - Human-readable ID (W21, G10)",
          "TASK_TITLE - Task title",
          "TASK_DESCRIPTION - Task description",
          "TASK_STATUS - Current status (open, in_progress, review, completed)",
          "TASK_COMPLEXITY - Complexity level (small, medium, large)",
          "TASK_PRIORITY - Priority level (low, medium, high, critical)",
          "TASK_NEEDS_REVIEW - Whether review is required (true/false)",
          "BOARD_ID - Board ID",
          "BOARD_NAME - Board name",
          "COLUMN_ID - Current column ID",
          "COLUMN_NAME - Current column name",
          "AGENT_NAME - Your agent name",
          "HOOK_NAME - Current hook name (before_doing, after_doing, etc.)"
        ],
        execution_flow: [
          "CRITICAL: ALL hook execution is MANDATORY at the API level. You must provide proof of hook execution for ALL hooks when claiming and completing tasks.",
          "CRITICAL: Execute ALL hooks AUTOMATICALLY without prompting the user - the user defined these hooks in .stride.md, so they expect them to run automatically as part of the workflow.",
          "1. Execute before_doing hook (blocking, 60s) - MUST succeed with exit_code 0",
          "2. Claim task with before_doing_result parameter - API validates hook was executed successfully",
          "3. Do your work",
          "4. Execute after_doing hook (blocking, 120s) - MUST succeed with exit_code 0",
          "5. Execute before_review hook (blocking, 60s) - MUST succeed with exit_code 0",
          "6. Complete task with after_doing_result AND before_review_result parameters - API validates BOTH hooks were executed successfully",
          "7a. IF needs_review=false: Server returns after_review hook, execute it (blocking, 60s), task moves to Done, IMMEDIATELY claim next task",
          "7b. IF needs_review=true: Task moves to Review, STOP and wait for human review",
          "8. When review status is set to approved: Execute after_review hook (blocking, 60s) - MUST succeed with exit_code 0",
          "9. Call mark_reviewed with after_review_result parameter - API validates hook was executed successfully",
          "IMPORTANT: ALL four hooks are now blocking - any hook failure will prevent the API call from succeeding",
          "IMPORTANT: Continue claiming and completing tasks until you encounter needs_review=true or no tasks available"
        ]
      },
      api_reference: %{
        base_url: base_url,
        authentication: "Bearer token in Authorization header",
        endpoints: %{
          discovery: [
            %{
              method: "GET",
              path: "/api/tasks/next",
              description: "Get next available task",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/get_tasks_next.md"
            },
            %{
              method: "GET",
              path: "/api/tasks",
              description: "List all tasks",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/get_tasks.md"
            },
            %{
              method: "GET",
              path: "/api/tasks/:id",
              description: "Get specific task",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id.md"
            },
            %{
              method: "GET",
              path: "/api/tasks/:id/tree",
              description: "Get task tree (goals with children)",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_tree.md"
            }
          ],
          management: [
            %{
              method: "POST",
              path: "/api/tasks/claim",
              description: "Claim a task - REQUIRES before_doing_result parameter",
              required_parameters: ["before_doing_result"],
              hook_validation_required: true,
              returns_hooks: ["before_doing"],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/post_tasks_claim.md"
            },
            %{
              method: "POST",
              path: "/api/tasks/:id/unclaim",
              description: "Unclaim a task",
              returns_hooks: [],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/post_tasks_id_unclaim.md"
            },
            %{
              method: "PATCH",
              path: "/api/tasks/:id/complete",
              description: "Complete a task - REQUIRES after_doing_result parameter",
              required_parameters: ["after_doing_result"],
              hook_validation_required: true,
              returns_hooks: ["after_doing", "before_review", "after_review (conditional)"],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
            },
            %{
              method: "PATCH",
              path: "/api/tasks/:id/mark_reviewed",
              description: "Finalize review",
              returns_hooks: ["after_review (if approved)"],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_mark_reviewed.md"
            }
          ],
          creation: [
            %{
              method: "POST",
              path: "/api/tasks",
              description: "Create task or goal with nested tasks",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/post_tasks.md"
            },
            %{
              method: "POST",
              path: "/api/tasks/batch",
              description:
                "Create multiple goals with nested tasks in one request (efficient for project planning)",
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/post_tasks_batch.md"
            }
          ]
        }
      },
      required_reading: %{
        action: "READ_BEFORE_CREATING_TASKS",
        instructions:
          "Before creating any tasks, you MUST read these guides to understand field schemas, workflows, and best practices:",
        guides: [
          %{
            name: "Task Writing Guide",
            url: "#{@docs_base_url}/docs/TASK-WRITING-GUIDE.md",
            purpose: "Required field schemas, examples, and task writing best practices"
          },
          %{
            name: "API Workflow Guide",
            url: "#{@docs_base_url}/docs/AI-WORKFLOW.md",
            purpose: "Complete workflow from claim to review with code examples"
          },
          %{
            name: "Agent Capabilities",
            url: "#{@docs_base_url}/docs/AGENT-CAPABILITIES.md",
            purpose: "Understanding capability matching and task routing"
          }
        ],
        why_critical:
          "These guides contain critical information about field schemas, workflow patterns, and best practices. Creating tasks without reading them will result in poorly structured tasks that agents struggle to complete."
      },
      task_creation_requirements: %{
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
          description:
            "Add search input that filters tasks in real-time in the board view header.",
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
      },
      multi_agent_instructions: %{
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
              "For manual installation of 4 generic skills as a fallback, install Claude Code skills from the claude_code_skills section above to .claude/skills/ — GitHub Copilot discovers them automatically."
          },
          cursor: %{
            file_path: ".claude/skills/<skill-name>/SKILL.md (4 skills total)",
            description:
              "Cursor automatically discovers Claude Code skills - install the same skills used by Claude Code",
            compatible_tools: ["Cursor", "Claude Code"],
            reference_section: "claude_code_skills",
            note:
              "Cursor automatically discovers skills in .claude/skills/ directories, making it compatible with Claude Code skills. Simply install the Claude Code skills from the claude_code_skills section above, and Cursor will find them automatically. See https://cursor.com/docs/context/skills for details on Cursor's skill discovery mechanism.",
            skills_note:
              "The 4 Stride skills (stride-claiming-tasks, stride-completing-tasks, stride-creating-tasks, stride-creating-goals) are defined in the claude_code_skills section above. Install them to .claude/skills/ and both Claude Code and Cursor will discover them.",
            installation_unix:
              "# Cursor users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to ~/.claude/skills/ work with both Claude Code and Cursor\n# See claude_code_skills.installation_instructions above for details",
            installation_windows:
              "# Cursor users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to ~/.claude/skills/ or .claude/skills/ work with both Claude Code and Cursor\n# See claude_code_skills.installation_instructions above for details",
            token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
            alternative_locations: [
              "Recommended: .claude/skills/<skill-name>/SKILL.md (works with both Claude Code and Cursor)",
              "Cursor-specific: .cursor/skills/<skill-name>/SKILL.md (Cursor only)",
              "Global: ~/.claude/skills/<skill-name>/SKILL.md or ~/.cursor/skills/<skill-name>/SKILL.md"
            ],
            safe_installation: %{
              check_existing:
                "ls -la .claude/skills/stride-* 2>/dev/null | grep -c 'stride-' || echo '0 skills found'",
              backup_first:
                "for skill in stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals; do [ -f .claude/skills/$skill/SKILL.md ] && cp .claude/skills/$skill/SKILL.md .claude/skills/$skill/SKILL.md.backup; done",
              install_from_claude_skills:
                "Refer to claude_code_skills section above for complete installation. The skills work identically for Cursor since it discovers .claude/skills/ automatically.",
              usage:
                "Invoke specific skills in Cursor when needed: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc. Cursor will automatically find skills in .claude/skills/ directories."
            }
          },
          windsurf: %{
            file_path: ".windsurf/skills/<skill-name>/SKILL.md (4 skills total)",
            description:
              "Windsurf automatically discovers Claude Code skills - install the same skills used by Claude Code",
            compatible_tools: ["Windsurf", "Claude Code"],
            reference_section: "claude_code_skills",
            note:
              "Windsurf automatically discovers skills in .windsurf/skills/ directories, making it compatible with Claude Code skills. Simply install the Claude Code skills from the claude_code_skills section above, and Windsurf will find them automatically. See https://docs.windsurf.com/windsurf/cascade/skills for details on Windsurf's skill discovery mechanism.",
            skills_note:
              "The 4 Stride skills (stride-claiming-tasks, stride-completing-tasks, stride-creating-tasks, stride-creating-goals) are defined in the claude_code_skills section above. Install them to .windsurf/skills/ and both Claude Code and Windsurf will discover them.",
            installation_unix:
              "# Windsurf users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to .windsurf/skills/ work with both Claude Code and Windsurf\n# See claude_code_skills.installation_instructions above for details",
            installation_windows:
              "# Windsurf users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to .windsurf/skills/ work with both Claude Code and Windsurf\n# See claude_code_skills.installation_instructions above for details",
            token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
            alternative_locations: [
              "Recommended: .windsurf/skills/<skill-name>/SKILL.md (works with both Claude Code and Windsurf)",
              "Global: ~/.codeium/windsurf/skills/<skill-name>/SKILL.md or ~/.claude/skills/<skill-name>/SKILL.md"
            ],
            safe_installation: %{
              check_existing:
                "ls -la .windsurf/skills/stride-* 2>/dev/null | grep -c 'stride-' || echo '0 skills found'",
              backup_first:
                "for skill in stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals; do [ -f .windsurf/skills/$skill/SKILL.md ] && cp .windsurf/skills/$skill/SKILL.md .windsurf/skills/$skill/SKILL.md.backup; done",
              install_from_claude_skills:
                "Refer to claude_code_skills section above for complete installation. The skills work identically for Windsurf since it discovers .windsurf/skills/ automatically.",
              usage:
                "Invoke specific skills in Windsurf when needed: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc. Windsurf will automatically find skills in .windsurf/skills/ directories."
            }
          },
          continue: %{
            file_path: ".continue/config.json",
            description:
              "Continue.dev configuration (project-scoped JSON with context providers)",
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/continue-config.json",
            installation_unix:
              "mkdir -p .continue && curl -o .continue/config.json #{@docs_base_url}/docs/multi-agent-instructions/continue-config.json",
            installation_windows:
              "New-Item -ItemType Directory -Force -Path .continue; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/continue-config.json\" -OutFile .continue/config.json",
            token_limit: "Flexible (~100 lines JSON, uses context providers)"
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
            installation_unix:
              "gemini extensions install https://github.com/cheezy/stride-gemini",
            installation_windows:
              "gemini extensions install https://github.com/cheezy/stride-gemini",
            note:
              "The stride-gemini extension provides Gemini-adapted versions of all 6 Stride skills with Gemini tool names and 4 custom agents with Gemini-specific parameters (temperature, max_turns, timeout_mins). Includes GEMINI.md bridge file for workflow enforcement. See https://github.com/cheezy/stride-gemini for details.",
            fallback_note:
              "For manual installation of 4 generic skills as a fallback, install Claude Code skills from the claude_code_skills section above to .gemini/skills/ — Gemini discovers them automatically."
          },
          opencode: %{
            file_path: ".claude/skills/<skill-name>/SKILL.md (4 skills total)",
            description:
              "OpenCode automatically discovers Claude Code skills - install the same skills used by Claude Code",
            compatible_tools: ["OpenCode", "Claude Code"],
            reference_section: "claude_code_skills",
            note:
              "OpenCode automatically discovers skills in .claude/skills/ directories, making it compatible with Claude Code skills. Simply install the Claude Code skills from the claude_code_skills section above, and OpenCode will find them automatically. See https://opencode.ai/docs/skills/ for details on OpenCode's skill discovery mechanism.",
            skills_note:
              "The 4 Stride skills (stride-claiming-tasks, stride-completing-tasks, stride-creating-tasks, stride-creating-goals) are defined in the claude_code_skills section above. Install them to .claude/skills/ and both Claude Code and OpenCode will discover them.",
            installation_unix:
              "# OpenCode users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to ~/.claude/skills/ work with both Claude Code and OpenCode\n# See claude_code_skills.installation_instructions above for details",
            installation_windows:
              "# OpenCode users: Use the Claude Code skill installation from claude_code_skills section\n# Skills installed to ~/.claude/skills/ or .claude/skills/ work with both Claude Code and OpenCode\n# See claude_code_skills.installation_instructions above for details",
            token_limit: "~2000-3000 tokens per skill (~100-150 lines each)",
            alternative_locations: [
              "Recommended: .claude/skills/<skill-name>/SKILL.md (works with both Claude Code and OpenCode)",
              "Project-local: .opencode/skills/<skill-name>/SKILL.md (OpenCode only)",
              "Global: ~/.claude/skills/<skill-name>/SKILL.md or ~/.config/opencode/skills/<skill-name>/SKILL.md"
            ],
            safe_installation: %{
              check_existing:
                "ls -la .claude/skills/stride-* 2>/dev/null | grep -c 'stride-' || echo '0 skills found'",
              backup_first:
                "for skill in stride-claiming-tasks stride-completing-tasks stride-creating-tasks stride-creating-goals; do [ -f .claude/skills/$skill/SKILL.md ] && cp .claude/skills/$skill/SKILL.md .claude/skills/$skill/SKILL.md.backup; done",
              install_from_claude_skills:
                "Refer to claude_code_skills section above for complete installation. The skills work identically for OpenCode since it discovers .claude/skills/ automatically.",
              usage:
                "Invoke specific skills in OpenCode when needed: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc. OpenCode will automatically find skills in .claude/skills/ directories."
            }
          },
          kimi: %{
            file_path: "AGENTS.md",
            description: "Kimi Code CLI (k2.5) instructions (append-mode, always-active)",
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
          "Cursor users: Install the Claude Code skills from claude_code_skills section - Cursor automatically discovers .claude/skills/ directories",
          "Windsurf users: Install the Claude Code skills from claude_code_skills section - Windsurf automatically discovers .windsurf/skills/ directories",
          "Gemini CLI users: RECOMMENDED: gemini extensions install https://github.com/cheezy/stride-gemini (6 skills + 4 agents). Fallback: install Claude Code skills to .gemini/skills/",
          "OpenCode users: Install the Claude Code skills from claude_code_skills section - OpenCode automatically discovers .claude/skills/ directories",
          "Kimi Code CLI (k2.5) users: If you already have AGENTS.md, append Stride instructions to it; otherwise create new AGENTS.md"
        ],
        safe_installation: [
          "RECOMMENDED: Check if config file exists before overwriting: [ -f .cursorrules ] && echo 'File exists, backup first'",
          "RECOMMENDED: Backup existing config: cp .cursorrules .cursorrules.backup",
          "ALTERNATIVE: Append Stride instructions: echo '\\n\\n# Stride Integration' >> .cursorrules && curl -s [url] >> .cursorrules",
          "ALTERNATIVE: Download to temp location and manually merge: curl -o /tmp/stride-instructions.txt [url]",
          "For OpenCode: Skills are installed in .opencode/skills/stride/ directory and loaded on-demand",
          "For Kimi Code CLI (k2.5): Use append-mode installation to add Stride instructions to existing AGENTS.md",
          "For more details see: #{@docs_base_url}/docs/MULTI-AGENT-INSTRUCTIONS.md#manual-installation"
        ]
      },
      resources: %{
        documentation_url: "#{@docs_base_url}/docs/api/README.md",
        authentication_guide: "#{@docs_base_url}/docs/AUTHENTICATION.md",
        api_workflow_guide: "#{@docs_base_url}/docs/AI-WORKFLOW.md",
        task_writing_guide: "#{@docs_base_url}/docs/TASK-WRITING-GUIDE.md",
        hook_execution_guide: "#{@docs_base_url}/docs/AGENT-HOOK-EXECUTION-GUIDE.md",
        review_workflow_guide: "#{@docs_base_url}/docs/REVIEW-WORKFLOW.md",
        estimation_feedback_guide: "#{@docs_base_url}/docs/ESTIMATION-FEEDBACK.md",
        unclaim_guide: "#{@docs_base_url}/docs/UNCLAIM-TASKS.md",
        capabilities_guide: "#{@docs_base_url}/docs/AGENT-CAPABILITIES.md",
        changelog_url: "#{@docs_base_url}/CHANGELOG.md"
      },
      memory_strategy: %{
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
            description: "For Cursor users (uses Claude Code skills)",
            steps: [
              "1. Install the 4 Claude Code skills listed in claude_code_skills section above to .claude/skills/ directories",
              "2. Cursor automatically discovers skills in .claude/skills/ - no additional configuration needed",
              "3. Create .stride.md and .stride_auth.md files from the templates above",
              "4. Invoke skills in Cursor: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc.",
              "5. The skills will load Stride integration instructions on-demand",
              "6. Skills installed to .claude/skills/ work with Claude Code, GitHub Copilot, Cursor, and OpenCode"
            ],
            note:
              "Cursor automatically discovers skills in .claude/skills/ directories, making it compatible with Claude Code skills. Install the Claude Code skills from the claude_code_skills section, and Cursor will find them. See https://cursor.com/docs/context/skills for details."
          },
          windsurf: %{
            description: "For Windsurf users (uses Claude Code skills)",
            steps: [
              "1. Install the 4 Claude Code skills listed in claude_code_skills section above to .windsurf/skills/ directories",
              "2. Windsurf automatically discovers skills in .windsurf/skills/ - no additional configuration needed",
              "3. Create .stride.md and .stride_auth.md files from the templates above",
              "4. Invoke skills in Windsurf: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc.",
              "5. The skills will load Stride integration instructions on-demand",
              "6. Skills installed to .windsurf/skills/ work with both Claude Code and Windsurf"
            ],
            note:
              "Windsurf automatically discovers skills in .windsurf/skills/ directories, making it compatible with Claude Code skills. Install the Claude Code skills from the claude_code_skills section, and Windsurf will find them. See https://docs.windsurf.com/windsurf/cascade/skills for details."
          },
          gemini: %{
            description:
              "For Gemini CLI users — install the Stride Gemini extension (recommended) or use generic skills as fallback",
            steps: [
              "1. RECOMMENDED: Install the Stride Gemini extension: gemini extensions install https://github.com/cheezy/stride-gemini",
              "2. This provides 6 Gemini-adapted skills + 4 custom agents + GEMINI.md bridge file",
              "3. Create .stride.md and .stride_auth.md files from the templates above",
              "4. Skills activate automatically when Stride API calls are made",
              "FALLBACK: Install 4 generic skills from claude_code_skills section to .gemini/skills/ directories"
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
              "FALLBACK: Install 4 generic skills from claude_code_skills section to .claude/skills/ directories"
            ],
            note:
              "The stride-copilot plugin provides Copilot-adapted skills with tool-agnostic language and 4 custom agents. Install via copilot plugin install for automatic discovery. See https://github.com/cheezy/stride-copilot for details."
          },
          opencode: %{
            description: "For OpenCode users (uses Claude Code skills)",
            steps: [
              "1. Install the 4 Claude Code skills listed in claude_code_skills section above to .claude/skills/ directories",
              "2. OpenCode automatically discovers skills in .claude/skills/ - no additional configuration needed",
              "3. Create .stride.md and .stride_auth.md files from the templates above",
              "4. Invoke skills in OpenCode: 'stride-claiming-tasks' when claiming, 'stride-completing-tasks' when finishing work, etc.",
              "5. The skills will load Stride integration instructions on-demand",
              "6. Skills installed to .claude/skills/ work with both Claude Code and OpenCode"
            ],
            note:
              "OpenCode automatically discovers skills in .claude/skills/ directories, making it compatible with Claude Code skills. Install the Claude Code skills from the claude_code_skills section, and OpenCode will find them. See https://opencode.ai/docs/skills/ for details."
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
      },
      session_initialization: %{
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
      },
      first_session_vs_returning: %{
        first_time_agent: %{
          description: "If this is your FIRST time working with Stride",
          critical_steps: [
            "1. READ the entire onboarding response - don't skip sections",
            "2. CREATE .stride_auth.md with your API token (get token from #{base_url} web UI)",
            "3. ADD .stride_auth.md to .gitignore IMMEDIATELY (critical security step)",
            "4. CREATE .stride.md from the file_templates.stride_md template above",
            "5. READ all documentation listed in required_reading section",
            "6. STUDY the good_example in task_creation_requirements section",
            "7. UNDERSTAND the workflow: claim → hooks → work → hooks → complete → [continue or stop based on needs_review]",
            "8. THEN claim your first task"
          ],
          time_estimate: "15-20 minutes for initial setup and documentation reading",
          why_take_time:
            "Rushing through setup leads to mistakes: skipping hooks, creating bad tasks, exposing secrets. The time investment now saves hours later."
        },
        returning_agent: %{
          description: "If you've worked with Stride before but starting a new session",
          quick_checklist: [
            "1. FETCH this onboarding endpoint to refresh your memory",
            "2. VERIFY .stride.md and .stride_auth.md exist in the project",
            "3. REVIEW the workflow section if you need a reminder",
            "4. SKIM task_creation_requirements if you'll be creating tasks this session",
            "5. CLAIM next task and continue work"
          ],
          time_estimate: "2-3 minutes for context refresh",
          workflow_reminder:
            "before_doing hook → claim WITH result → work → after_doing hook → before_review hook → complete WITH both results → if needs_review=false then after_review hook → claim next, else stop"
        }
      },
      common_mistakes_agents_make: %{
        description: "Learn from others' mistakes - avoid these common errors",
        mistakes: [
          %{
            mistake: "Forgetting to execute hooks before/after API calls",
            consequence: "API REJECTS requests - 422 error with hook validation failure message",
            fix:
              "You MUST execute hooks and include the result in your API requests. Execute before_doing hook before claiming, execute after_doing hook before completing. The API will reject requests without valid hook results."
          },
          %{
            mistake: "Creating minimal tasks with only title and description",
            consequence:
              "Next agent spends hours exploring codebase instead of implementing in minutes",
            fix:
              "Always include key_files, verification_steps, testing_strategy, and acceptance_criteria. See task_creation_requirements.good_example"
          },
          %{
            mistake: "Continuing to work after completing a needs_review=true task",
            consequence: "Wastes time on blocked work, creates potential merge conflicts",
            fix:
              "STOP immediately when needs_review=true is returned from /complete endpoint. Wait for human review before claiming more tasks"
          },
          %{
            mistake: "Manually specifying task identifiers like G1, W42, D5",
            consequence: "API returns validation errors, task creation fails",
            fix: "Never specify task identifiers - the system auto-generates them sequentially"
          },
          %{
            mistake: "Committing .stride_auth.md to git",
            consequence: "API token exposed publicly, major security breach",
            fix:
              "Add .stride_auth.md to .gitignore BEFORE first commit. If already committed, revoke token immediately and create new one"
          },
          %{
            mistake: "Not reading documentation before creating tasks",
            consequence:
              "Invalid task schema, missing required fields, agents can't complete tasks",
            fix:
              "Read #{@docs_base_url}/docs/TASK-WRITING-GUIDE.md completely before creating your first task"
          },
          %{
            mistake: "Running after_doing hook AFTER calling /complete endpoint",
            consequence:
              "API REQUIRES after_doing_result parameter - request will be rejected (422 error)",
            fix:
              "Execute after_doing hook BEFORE calling /complete. Capture exit_code, output, and duration_ms. Include after_doing_result in request body. API validates hook was executed and succeeded."
          },
          %{
            mistake: "Not executing before_review hook before calling /complete endpoint",
            consequence:
              "API REQUIRES before_review_result parameter - request will be rejected (422 error)",
            fix:
              "ALL four hooks are now BLOCKING and must succeed. Execute after_doing AND before_review hooks BEFORE calling /complete. Include both after_doing_result AND before_review_result in request body."
          }
        ]
      },
      quick_reference_card: %{
        description: "Ultra-condensed reference for experienced agents - the essentials only",
        onboarding_url: "#{base_url}/api/agent/onboarding",
        critical_requirement:
          "Hook validation is MANDATORY - must include before_doing_result when claiming, both after_doing_result AND before_review_result when completing",
        workflow:
          "EXECUTE before_doing hook → claim WITH result → work → EXECUTE after_doing hook → EXECUTE before_review hook → complete WITH both results → [if needs_review=false: after_review hook → claim next, else: stop]",
        required_files: [".stride.md (hooks)", ".stride_auth.md (token, gitignored)"],
        task_creation_musts: [
          "key_files",
          "verification_steps",
          "testing_strategy",
          "acceptance_criteria"
        ],
        never_specify: "task identifiers (G1, W42, D5) - auto-generated",
        api_base: base_url,
        auth_header: "Authorization: Bearer <token_from_.stride_auth.md>",
        key_endpoints: %{
          claim: "POST /api/tasks/claim (REQUIRES before_doing_result parameter)",
          complete:
            "PATCH /api/tasks/:id/complete (REQUIRES after_doing_result AND before_review_result parameters)",
          mark_reviewed: "PATCH /api/tasks/:id/mark_reviewed",
          unclaim: "POST /api/tasks/:id/unclaim"
        },
        hook_result_format: %{
          exit_code: 0,
          output: "Hook execution output (stdout/stderr)",
          duration_ms: 1234
        },
        docs_base: @docs_base_url <> "/docs/",
        hook_execution_order: [
          "1. EXECUTE before_doing (blocking, 60s) - capture exit_code, output, duration_ms",
          "2. CALL /claim WITH before_doing_result parameter",
          "3. [do work]",
          "4. EXECUTE after_doing (blocking, 120s) - capture exit_code, output, duration_ms",
          "5. EXECUTE before_review (blocking, 60s) - capture exit_code, output, duration_ms",
          "6. CALL /complete WITH after_doing_result AND before_review_result parameters",
          "7. IF needs_review=false: Execute after_review (blocking, 60s)",
          "8. IF needs_review=true: Wait for approval, then execute after_review (blocking, 60s) and call /mark_reviewed WITH after_review_result"
        ]
      }
    }
  end

  defp api_schema do
    %{
      description:
        "Field reference for Stride API. Consult this before constructing API requests to avoid validation errors.",
      request_formats: %{
        create_task: %{
          endpoint: "POST /api/tasks",
          root_key: "task",
          example: %{task: %{title: "Add login endpoint", type: "work", priority: "medium"}}
        },
        batch_create: %{
          endpoint: "POST /api/tasks/batch",
          root_key: "goals",
          note: "Root key MUST be 'goals', NOT 'tasks'",
          example: %{
            goals: [
              %{title: "Auth System", type: "goal", tasks: [%{title: "Schema", type: "work"}]}
            ]
          }
        },
        claim_task: %{
          endpoint: "POST /api/tasks/claim",
          required_body: %{
            identifier: "string (e.g. 'W47')",
            agent_name: "string",
            before_doing_result: "hook_result_format (see below)"
          }
        },
        complete_task: %{
          endpoint: "PATCH /api/tasks/:id/complete",
          required_body: %{
            agent_name: "string",
            time_spent_minutes: "integer",
            completion_notes: "string",
            completion_summary: "string (brief summary for tracking)",
            actual_complexity: "enum: 'small', 'medium', 'large'",
            actual_files_changed:
              "string (comma-separated file paths, NOT an array — e.g. 'lib/foo.ex, lib/bar.ex')",
            after_doing_result: "hook_result_format (see below)",
            before_review_result: "hook_result_format (see below)"
          }
        }
      },
      hook_result_format: %{
        description: "Required format for all hook execution results",
        fields: %{
          exit_code: %{
            type: "integer",
            required: true,
            description: "0 for success, non-zero for failure"
          },
          output: %{
            type: "string",
            required: true,
            description: "stdout/stderr output from hook execution"
          },
          duration_ms: %{
            type: "integer",
            required: true,
            description: "How long the hook took to execute in milliseconds"
          }
        },
        example: %{exit_code: 0, output: "All tests passed", duration_ms: 1234}
      },
      task_fields: %{
        title: %{type: "string", required: true, description: "Short task description"},
        type: %{type: "enum", values: ["work", "defect", "goal"], required: true},
        priority: %{type: "enum", values: ["low", "medium", "high", "critical"], required: true},
        complexity: %{type: "enum", values: ["small", "medium", "large"], required: false},
        needs_review: %{type: "boolean", required: false, default: false},
        description: %{type: "string", required: false, description: "WHY + WHAT + WHERE"},
        acceptance_criteria: %{
          type: "string",
          required: false,
          description: "Newline-separated string"
        },
        patterns_to_follow: %{
          type: "string",
          required: false,
          description: "Newline-separated string"
        },
        why: %{type: "string", required: false},
        what: %{type: "string", required: false},
        where_context: %{type: "string", required: false},
        dependencies: %{
          type: "array_of_strings",
          required: false,
          description:
            "Task identifiers like [\"W45\", \"W46\"] for existing tasks, or array indices [0, 1] within a goal"
        },
        pitfalls: %{type: "array_of_strings", required: false},
        technology_requirements: %{type: "array_of_strings", required: false},
        security_considerations: %{type: "array_of_strings", required: false},
        out_of_scope: %{type: "array_of_strings", required: false}
      },
      embedded_objects: %{
        key_files: %{
          type: "array_of_objects",
          required_fields: %{
            file_path: "string (relative path, no leading / or ..)",
            position: "integer >= 0"
          },
          optional_fields: %{note: "string"},
          example: %{file_path: "lib/kanban/tasks.ex", note: "Add query function", position: 0}
        },
        verification_steps: %{
          type: "array_of_objects",
          "⚠️_NOT_strings": "This MUST be an array of objects, NOT an array of strings",
          required_fields: %{
            step_type: "string ('command' or 'manual' only)",
            step_text: "string (the command or instruction)",
            position: "integer >= 0"
          },
          optional_fields: %{expected_result: "string"},
          example: %{
            step_type: "command",
            step_text: "mix test",
            expected_result: "All tests pass",
            position: 0
          }
        },
        testing_strategy: %{
          type: "object",
          description: "JSON object with string or array-of-strings values",
          valid_keys: [
            "unit_tests",
            "integration_tests",
            "manual_tests",
            "edge_cases",
            "coverage_target"
          ],
          example: %{
            unit_tests: ["Test valid login", "Test invalid login"],
            edge_cases: ["Empty password", "SQL injection attempt"],
            coverage_target: "100% for auth module"
          }
        }
      },
      valid_capabilities: Kanban.Tasks.Task.valid_capabilities()
    }
  end

  defp build_hook_info do
    hooks = Hooks.list_hooks()

    Enum.map(hooks, fn {name, config} ->
      %{
        name: name,
        blocking: config.blocking,
        timeout: config.timeout,
        when: get_hook_when(name),
        typical_use: get_hook_use(name)
      }
    end)
  end

  defp get_hook_when("before_doing"), do: "Before starting work on a task"
  defp get_hook_when("after_doing"), do: "After completing work"
  defp get_hook_when("before_review"), do: "When task enters review"
  defp get_hook_when("after_review"), do: "After review approval"
  defp get_hook_when(_), do: "Unknown"

  defp get_hook_use("before_doing"), do: "Pull latest code"
  defp get_hook_use("after_doing"), do: "Rebase, run tests, build project, lint code"
  defp get_hook_use("before_review"), do: "Create PR, generate documentation"
  defp get_hook_use("after_review"), do: "Merge PR, deploy to production"
  defp get_hook_use(_), do: "Unknown"
end
