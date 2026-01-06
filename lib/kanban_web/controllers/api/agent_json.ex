defmodule KanbanWeb.API.AgentJSON do
  alias Kanban.Hooks

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  def onboarding(%{base_url: base_url}) do
    %{
      version: "1.0",
      api_base_url: base_url,
      critical_first_steps: %{
        action: "CREATE_FILES_NOW",
        instructions: [
          "Before claiming any tasks, you MUST create two configuration files:",
          "1. Create .stride_auth.md by copying the COMPLETE contents from file_templates.stride_auth_md EXACTLY as shown - do not summarize or omit any lines",
          "2. Add .stride_auth.md to .gitignore (NEVER commit this file - it contains secrets)",
          "3. Create .stride.md by copying the COMPLETE contents from file_templates.stride_md EXACTLY as shown - do not summarize or omit any lines",
          "4. Verify both files exist before proceeding"
        ],
        why_critical:
          "Without these files, you cannot execute hooks or authenticate with the API. The .stride_auth.md file contains your API token and MUST be gitignored to prevent exposing secrets.",
        file_creation_requirements: [
          "CRITICAL: Copy the ENTIRE template content character-for-character",
          "CRITICAL: Do NOT summarize, truncate, or omit any sections",
          "CRITICAL: Do NOT modify the structure or remove placeholder text like {{YOUR_TOKEN_HERE}}",
          "The templates contain important documentation and examples that must be preserved in full"
        ]
      },
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
        "1. IMMEDIATELY create .stride_auth.md by copying the ENTIRE file_templates.stride_auth_md content exactly - do not omit any lines",
        "2. IMMEDIATELY add .stride_auth.md to your .gitignore file (CRITICAL - contains secrets)",
        "3. IMMEDIATELY create .stride.md by copying the ENTIRE file_templates.stride_md content exactly - do not omit any lines",
        "4. Verify files are created: .stride_auth.md (gitignored), .stride.md (version controlled)",
        "5. Call POST #{base_url}/api/tasks/claim to get your first task",
        "6. Execute hooks and complete your work following the workflow"
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
        - **Capabilities:** code_generation, testing

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

        Executes when task enters review (non-blocking, 60s timeout).

        ```bash
        echo "Creating PR for $TASK_IDENTIFIER"
        # gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
        ```

        ## after_review

        Executes after review approval (non-blocking, 60s timeout).

        ```bash
        echo "Deploying $TASK_IDENTIFIER"
        # Add deployment commands here
        ```
        """
      },
      workflow: [
        %{
          name: "claim_task",
          endpoint: "POST #{base_url}/api/tasks/claim",
          description:
            "Claim next available task matching your capabilities. Claims automatically expire after 60 minutes if not completed, releasing the task for other agents.",
          returns: "Task data + before_doing hook metadata",
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_claim.md"
        },
        %{
          name: "complete_task",
          endpoint: "PATCH #{base_url}/api/tasks/:id/complete",
          description:
            "Mark task as complete. If needs_review=false, task moves to Done (claim next task immediately). If needs_review=true, task moves to Review (stop and wait for human review).",
          returns:
            "Task data + array of hook metadata (after_doing, before_review, after_review)",
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
        },
        %{
          name: "mark_reviewed",
          endpoint: "PATCH #{base_url}/api/tasks/:id/mark_reviewed",
          description: "Finalize review after human reviewer sets status",
          returns: "Task data + after_review hook (if approved)",
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
          "1. Claim task - receive before_doing hook metadata",
          "2. Execute before_doing hook (blocking, 60s)",
          "3. Do your work",
          "4. Complete task - receive after_doing, before_review, after_review hooks",
          "5. Execute after_doing hook (blocking, 120s) - tests must pass",
          "6. Execute before_review hook (non-blocking, 60s)",
          "7a. IF needs_review=false: Execute after_review hook, task moves to Done, IMMEDIATELY claim next task",
          "7b. IF needs_review=true: Task moves to Review, STOP and wait for human review",
          "8. When review complete: Call mark_reviewed to receive after_review hook (if approved)",
          "9. Execute after_review hook (non-blocking, 60s)",
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
              description: "Claim a task",
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
              description: "Complete a task",
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

            **Workflow:** claim → before_doing hook → work → after_doing hook → complete → [if needs_review=false: claim next, else: stop]

            **Files:** .stride.md (hooks), .stride_auth.md (token, gitignored)

            **Docs:** #{@docs_base_url}/docs/AI-WORKFLOW.md
            """
          },
          cursor: %{
            description: "For Cursor AI users",
            steps: [
              "1. Add .stride.md and .stride_auth.md references to your .cursorrules file",
              "2. Create a .cursor/prompts/stride.md file with the essential workflow from this response",
              "3. Reference the onboarding endpoint (#{base_url}/api/agent/onboarding) in your project documentation"
            ]
          },
          windsurf: %{
            description: "For Windsurf users",
            steps: [
              "1. Add Stride workflow documentation to your project's cascade.md or .windsurfrules",
              "2. Create .stride.md and .stride_auth.md files in your project root",
              "3. Add the onboarding endpoint URL to your project setup documentation"
            ]
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
            "claim → before_doing hook → work → after_doing hook → complete → if needs_review=false then claim next, else stop"
        }
      },
      common_mistakes_agents_make: %{
        description: "Learn from others' mistakes - avoid these common errors",
        mistakes: [
          %{
            mistake: "Forgetting to execute hooks before/after API calls",
            consequence: "Task workflow breaks, tests don't run, quality gates are bypassed",
            fix:
              "Always read .stride.md and execute the hook scripts at the correct lifecycle points (before_doing, after_doing, before_review, after_review)"
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
            consequence: "Hook failures don't prevent task completion, quality gates fail",
            fix:
              "Execute after_doing hook BEFORE calling /complete. Only call /complete if hook succeeds"
          },
          %{
            mistake: "Not understanding blocking vs non-blocking hooks",
            consequence: "Incorrect error handling, tasks marked complete when they should fail",
            fix:
              "before_doing and after_doing are BLOCKING (must pass). before_review and after_review are NON-BLOCKING (logged but don't block)"
          }
        ]
      },
      quick_reference_card: %{
        description: "Ultra-condensed reference for experienced agents - the essentials only",
        onboarding_url: "#{base_url}/api/agent/onboarding",
        workflow:
          "claim → before_doing hook → work → after_doing hook → complete → [if needs_review=false: claim next, else: stop]",
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
          claim: "POST /api/tasks/claim",
          complete: "PATCH /api/tasks/:id/complete",
          mark_reviewed: "PATCH /api/tasks/:id/mark_reviewed",
          unclaim: "POST /api/tasks/:id/unclaim"
        },
        docs_base: @docs_base_url <> "/docs/",
        hook_execution_order: [
          "1. before_doing (blocking, 60s)",
          "2. [do work]",
          "3. after_doing (blocking, 120s) - MUST PASS BEFORE CALLING /complete",
          "4. before_review (non-blocking, 60s)",
          "5. after_review (non-blocking, 60s, only if needs_review=false or review approved)"
        ]
      }
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
