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

        ```bash
        export STRIDE_API_TOKEN="{{YOUR_TOKEN_HERE}}"
        export STRIDE_API_URL="#{base_url}"

        curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \\
          $STRIDE_API_URL/api/tasks/next
        ```
        """,
        stride_md: """
        # Stride Configuration

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
          "TASK_COMPLEXITY - Complexity level (trivial, low, medium, high, very_high)",
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
            }
          ]
        }
      },
      task_creation_requirements: %{
        critical_importance:
          "CRITICAL: Always create DETAILED, RICH tasks following the Task Writing Guide. Agents that create minimal tasks with only title/description struggle and fail. Success requires comprehensive task specifications.",
        required_reading: "#{@docs_base_url}/docs/TASK-WRITING-GUIDE.md",
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
          "dependencies - Tasks that must complete first (controls execution order, array of identifiers)",
          "estimated_files - Estimated number of files to modify as a number or range (e.g., '2', '3-5', '5+') (string)",
          "patterns_to_follow - Specific coding patterns to replicate (newline-separated string)",
          "testing_strategy - Overall testing approach with edge cases, coverage goals, mocking strategy (JSON object)",
          "pitfalls - Common mistakes to avoid (array of strings)",
          "out_of_scope - What NOT to include in this task (array of strings)",
          "technology_requirements - Required technologies or libraries (array of strings)",
          "database_changes - Database schema or query changes (string)",
          "validation_rules - Data validation requirements (string)",
          "logging_requirements - What to log and at what level (string)",
          "security_considerations - Security concerns or requirements (array of strings)"
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
            "WHY: Users need to find tasks quickly without scrolling. WHAT: Add search input that filters tasks in real-time. WHERE: Board view header.",
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
