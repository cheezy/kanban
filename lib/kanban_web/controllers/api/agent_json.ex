defmodule KanbanWeb.API.AgentJSON do
  alias Kanban.Hooks
  alias KanbanWeb.API.Agent.MultiAgentInstructions
  alias KanbanWeb.API.Agent.SchemaDoc
  alias KanbanWeb.API.Agent.SetupDocs

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
            "3. The 7 Stride skills will be automatically available"
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
      api_schema: SchemaDoc.schema(),
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
      file_templates: SetupDocs.file_templates(base_url),
      claude_code_skills: %{
        description: "Stride skills are distributed as a Claude Code marketplace plugin.",
        installation:
          "Run these two commands: /plugin marketplace add cheezy/stride-marketplace && /plugin install stride@stride-marketplace",
        plugin_repository: "https://github.com/cheezy/stride",
        marketplace_repository: "https://github.com/cheezy/stride-marketplace",
        skills_included: [
          "stride-workflow",
          "stride-claiming-tasks",
          "stride-completing-tasks",
          "stride-creating-tasks",
          "stride-creating-goals",
          "stride-enriching-tasks",
          "stride-subagent-workflow"
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
            "Mark task as complete. If needs_review=false, task moves to Done (claim next task immediately). If needs_review=true, task moves to Review (stop and wait for human review). REQUIRES after_doing_result AND before_review_result parameters with proof of hook execution. Note: changed_files included in this body is silently ignored — upload via PUT /api/tasks/:id/changed_files instead.",
          required_parameters: ["after_doing_result", "before_review_result"],
          hook_validation:
            "MANDATORY - Must execute BOTH after_doing AND before_review hooks BEFORE calling this endpoint and include both results",
          returns: "Task data + array of hook metadata (after_review if needs_review=false)",
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
        },
        %{
          name: "upload_changed_files",
          endpoint: "PUT #{base_url}/api/tasks/:id/changed_files",
          description:
            "Upload the per-file diff snapshot for a claimed-or-in-review task. Sole writer for tasks.changed_files — the completion endpoint silently ignores any changed_files in its body. Encoding (truncation marker, binary placeholder, 500-line cap) is defined in docs/diff-contract.md.",
          required_parameters: ["changed_files"],
          hook_validation:
            "Not a hook endpoint. Authz: caller must be the task assignee OR the task must be in the Review column.",
          returns: "Task data with the persisted changed_files in the response body",
          documentation_url: "#{@docs_base_url}/docs/api/put_tasks_id_changed_files.md"
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
              description:
                "Complete a task - REQUIRES after_doing_result parameter. changed_files in the body is silently ignored; use PUT /api/tasks/:id/changed_files instead.",
              required_parameters: ["after_doing_result"],
              hook_validation_required: true,
              returns_hooks: ["after_doing", "before_review", "after_review (conditional)"],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
            },
            %{
              method: "PUT",
              path: "/api/tasks/:id/changed_files",
              description:
                "Upload the per-file diff snapshot — sole writer for tasks.changed_files. Encoding defined in docs/diff-contract.md.",
              required_parameters: ["changed_files"],
              hook_validation_required: false,
              returns_hooks: [],
              auth_required: true,
              documentation_url: "#{@docs_base_url}/docs/api/put_tasks_id_changed_files.md"
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
      task_creation_requirements: SetupDocs.task_creation_requirements(),
      multi_agent_instructions: MultiAgentInstructions.instructions(),
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
      memory_strategy: SetupDocs.memory_strategy(base_url),
      session_initialization: SetupDocs.session_initialization(base_url),
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
          },
          %{
            mistake:
              "Trying to claim a task that has already been assigned to a different user via the UI or a goal-cascade",
            consequence:
              "API returns 403 Forbidden with error :assigned_to_other_user. The task row is NOT mutated.",
            fix:
              "Skip this task and call GET /api/tasks/next again — your queue will exclude assigned-to-others tasks automatically. Only the user named in assigned_to_id can claim a pre-assigned task. Unassigned tasks (assigned_to_id IS NULL) remain claimable by anyone."
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
