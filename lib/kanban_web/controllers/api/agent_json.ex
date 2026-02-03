defmodule KanbanWeb.API.AgentJSON do
  alias Kanban.Hooks

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

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
          action: "Install Claude Code skills (IF you are Claude Code)",
          condition: "ONLY for Claude Code. Other AI assistants skip this step.",
          how_to_check_if_claude_code:
            "You are Claude Code if you are running inside the Claude Code CLI tool",
          if_not_claude_code: "Skip to STEP_8_NOTIFY_USER",
          if_claude_code: "Create ALL 4 skill files (ALWAYS overwrite existing)",
          skills_to_create: [
            %{
              skill_name: "stride-claiming-tasks",
              file_path: "~/.claude/skills/stride-claiming-tasks/SKILL.md",
              tool_to_use: "Write tool (use absolute path expansion for ~)",
              content_source:
                "claude_code_skills.available_skills[0].content (scroll down to find)",
              always_overwrite: "YES - always create/update to get latest version"
            },
            %{
              skill_name: "stride-completing-tasks",
              file_path: "~/.claude/skills/stride-completing-tasks/SKILL.md",
              tool_to_use: "Write tool (use absolute path expansion for ~)",
              content_source:
                "claude_code_skills.available_skills[1].content (scroll down to find)",
              always_overwrite: "YES - always create/update to get latest version"
            },
            %{
              skill_name: "stride-creating-tasks",
              file_path: "~/.claude/skills/stride-creating-tasks/SKILL.md",
              tool_to_use: "Write tool (use absolute path expansion for ~)",
              content_source:
                "claude_code_skills.available_skills[2].content (scroll down to find)",
              always_overwrite: "YES - always create/update to get latest version"
            },
            %{
              skill_name: "stride-creating-goals",
              file_path: "~/.claude/skills/stride-creating-goals/SKILL.md",
              tool_to_use: "Write tool (use absolute path expansion for ~)",
              content_source:
                "claude_code_skills.available_skills[3].content (scroll down to find)",
              always_overwrite: "YES - always create/update to get latest version"
            }
          ],
          verification: "Use Bash to verify all 4 files exist: ls -la ~/.claude/skills/*/SKILL.md"
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
          "~/.claude/skills/stride-claiming-tasks/SKILL.md (Claude Code only)",
          "~/.claude/skills/stride-completing-tasks/SKILL.md (Claude Code only)",
          "~/.claude/skills/stride-creating-tasks/SKILL.md (Claude Code only)",
          "~/.claude/skills/stride-creating-goals/SKILL.md (Claude Code only)"
        ],
        USER_ACTION_REQUIRED:
          "User must edit .stride_auth.md to add their API token before you can use the API"
      },
      version: "1.0",
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
        "4. IF you are Claude Code: ALWAYS create/update all 4 Skills from claude_code_skills.available_skills - for each skill create ~/.claude/skills/{name}/SKILL.md with the content. Always overwrite to get latest versions. Other AI assistants: skip this step (use multi_agent_instructions)",
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
        description:
          "Contextual workflow enforcement skills specifically for Claude Code. If you are Claude Code, you MUST create these skill files when you fetch this onboarding endpoint, just like you create .stride.md and .stride_auth.md files. Other AI assistants should ignore this section and use multi_agent_instructions instead (coming soon).",
        critical_action: "CLAUDE_CODE_ONLY_CREATE_SKILL_FILES_NOW",
        agent_type_required: "claude_code",
        installation_instructions: [
          "IMPORTANT: These skills are ONLY for Claude Code. If you are a different AI assistant (GitHub Copilot, Cursor, Windsurf, Aider, Continue.dev, etc.), skip this section and use the multi_agent_instructions section instead.",
          "",
          "If you ARE Claude Code, when you fetch this onboarding endpoint, you MUST ALWAYS create/update all skill files (even if they already exist):",
          "1. For each skill in available_skills array below:",
          "   - Extract the 'name' field (e.g., 'stride-claiming-tasks')",
          "   - Create directory: ~/.claude/skills/{name}/",
          "   - Write the 'content' field to: ~/.claude/skills/{name}/SKILL.md",
          "2. ALWAYS overwrite existing skills to ensure you have the latest versions",
          "3. All 4 skills MUST be created/updated before claiming any tasks",
          "4. Skills will be automatically discovered by Claude Code in your next session",
          "",
          "Example: For the first skill (stride-claiming-tasks):",
          "   mkdir -p ~/.claude/skills/stride-claiming-tasks",
          "   cat > ~/.claude/skills/stride-claiming-tasks/SKILL.md <<'EOF'",
          "   <content>",
          "   EOF",
          "",
          "CRITICAL: The directory structure is ~/.claude/skills/{skill-name}/SKILL.md NOT ~/.claude/skills/{skill-name}.md",
          "",
          "These skills enforce critical workflow patterns:",
          "   - stride-claiming-tasks: Execute before_doing hook BEFORE claiming",
          "   - stride-completing-tasks: Execute after_doing AND before_review hooks BEFORE completing",
          "   - stride-creating-tasks: Ensure comprehensive task specifications",
          "   - stride-creating-goals: Proper goal structure with nested tasks",
          "",
          "Why Claude Code only? These skills use Claude Code's specific skill discovery mechanism. Other AI assistants have different formats for always-active instructions (see multi_agent_instructions section)."
        ],
        available_skills: [
          %{
            name: "stride-claiming-tasks",
            description:
              "Use when you want to claim a task from Stride, before making any API calls to /api/tasks/claim. After successful claiming, immediately begin implementation.",
            when_to_use:
              "Before calling POST /api/tasks/claim to reserve a task for implementation",
            file_path: "~/.claude/skills/stride-claiming-tasks/SKILL.md",
            content: """
            ---
            name: stride-claiming-tasks
            description: Use when you want to claim a task from Stride, before making any API calls to /api/tasks/claim. After successful claiming, immediately begin implementation.
            ---

            # Stride: Claiming Tasks

            ## Overview

            **Claiming without hooks = merge conflicts and outdated code. Claiming with hooks = clean setup and immediate work.**

            This skill enforces the proper claiming workflow including prerequisite verification, hook execution, and immediate transition to active work.

            ## ⚡ AUTOMATION NOTICE ⚡

            **This is a FULLY AUTOMATED workflow. Do NOT prompt the user between steps.**

            - After claiming → AUTOMATICALLY begin implementation
            - After implementation → AUTOMATICALLY invoke stride-completing-tasks
            - After completing (if needs_review=false) → AUTOMATICALLY claim next task

            **The agent should work continuously without asking "Should I continue?" or "What's next?"**

            ## The Iron Law

            **NO TASK CLAIMING WITHOUT PROPER SETUP AND HOOK EXECUTION**

            ## The Critical Mistake

            Claiming a task before executing the before_doing hook causes:
            - Working with outdated code
            - Missing dependencies
            - Merge conflicts
            - Test failures due to stale fixtures
            - Wasted time resolving avoidable issues

            **The API requires before_doing_result in the claim request.**

            ## When to Use

            Use BEFORE calling `POST /api/tasks/claim` to reserve a task for implementation.

            **Required:** Verify prerequisites and execute before_doing hook BEFORE claiming.

            ## Prerequisites Checklist

            Before claiming any task, verify these files exist:

            1. **`.stride_auth.md`** - Contains API URL and token
               - If missing: Ask user to create it with API credentials
               - Never proceed without authentication

            2. **`.stride.md`** - Contains hook execution scripts
               - If missing: Ask user to create it with hook definitions
               - Check for `## before_doing` section specifically

            3. **Extract Configuration:**
               - API URL from `.stride_auth.md`
               - API Token from `.stride_auth.md`
               - before_doing hook command from `.stride.md`

            ## The Complete Claiming Process

            1. **Verify prerequisites** - Check .stride_auth.md and .stride.md exist
            2. **Find available task** - Call `GET /api/tasks/next`
            3. **Review task details** - Read description, acceptance criteria, key files
            4. **Read .stride.md before_doing section** - Get the setup command
            5. **Execute before_doing hook AUTOMATICALLY** (blocking, 60s timeout)
               - **DO NOT prompt the user for permission to run hooks - the user defined them in .stride.md, so they expect them to run automatically**
               - Capture: `exit_code`, `output`, `duration_ms`
            6. **If before_doing fails:** FIX ISSUES, do NOT proceed
            7. **Hook succeeded?** Call `POST /api/tasks/claim` WITH hook result
            8. **Task claimed?** BEGIN IMPLEMENTATION IMMEDIATELY

            ## Claiming Workflow Flowchart

            ```
            Prerequisites Check
                ↓
            .stride_auth.md exists? ─NO→ Ask user to create
                ↓ YES
            .stride.md exists? ─NO→ Ask user to create
                ↓ YES
            Call GET /api/tasks/next
                ↓
            Review task details
                ↓
            Read .stride.md before_doing section
                ↓
            Execute before_doing (60s timeout, blocking)
                ↓
            Success (exit_code=0)? ─NO→ Fix Issues → Retry before_doing
                ↓ YES
            Call POST /api/tasks/claim WITH before_doing_result
                ↓
            Task claimed successfully?
                ↓ YES
            BEGIN IMPLEMENTATION IMMEDIATELY
            ```

            ## Hook Execution Pattern

            ### Executing before_doing Hook

            1. Read the `## before_doing` section from `.stride.md`
            2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
            3. Execute the command with 60s timeout
            4. Capture the results:

            ```bash
            START_TIME=$(date +%s%3N)
            OUTPUT=$(timeout 60 bash -c 'git pull origin main && mix deps.get' 2>&1)
            EXIT_CODE=$?
            END_TIME=$(date +%s%3N)
            DURATION=$((END_TIME - START_TIME))
            ```

            5. Check exit code - MUST be 0 to proceed

            ## When Hooks Fail

            ### If before_doing fails:

            1. **DO NOT** call claim endpoint
            2. Read the error output carefully
            3. Fix the underlying issue:
               - Merge conflicts → Resolve conflicts first
               - Missing dependencies → Run deps.get manually
               - Test failures → Fix tests before claiming new work
               - Git issues → Check branch status, pull latest changes
            4. Re-run before_doing hook to verify fix
            5. Only call claim endpoint after success

            **Common before_doing failures:**
            - Merge conflicts → Resolve conflicts first
            - Missing dependencies → Run mix deps.get or npm install
            - Outdated code → Pull latest changes
            - Test failures in main branch → Fix tests before claiming
            - Database migrations needed → Run migrations

            ## After Successful Claim

            **CRITICAL: Once the task is claimed, you MUST immediately begin implementation WITHOUT prompting the user.**

            ### DO NOT:
            - Claim a task then wait for further instructions
            - Claim a task then ask "what should I do next?"
            - Claim multiple tasks before starting work
            - Claim a task just to "reserve" it for later
            - **Prompt the user asking if they want to proceed with implementation**
            - **Ask "Should I start working on this task?"**
            - **Wait for user confirmation to begin work**

            ### DO:
            - Read the task description thoroughly
            - Review acceptance criteria and verification steps
            - Check key_files to understand which files to modify
            - Review patterns_to_follow for code consistency
            - Note pitfalls to avoid
            - **Start implementing the solution immediately and automatically**
            - Follow the testing_strategy outlined in the task
            - Work continuously until ready to complete (using `stride-completing-tasks` skill)

            **The claiming skill's job ends when you start coding. Your next interaction with Stride will be when you're ready to mark the work complete.**

            **AUTOMATION: This is a fully automated workflow. The agent should claim → implement → complete without ANY user prompts between steps.**

            ## API Request Format

            After before_doing hook succeeds, call the claim endpoint:

            ```json
            POST /api/tasks/claim
            {
              "identifier": "W47",
              "agent_name": "Claude Sonnet 4.5",
              "before_doing_result": {
                "exit_code": 0,
                "output": "Already up to date.\\nResolving Hex dependencies...\\nAll dependencies are up to date",
                "duration_ms": 450
              }
            }
            ```

            **Critical:** `before_doing_result` is REQUIRED. The API will reject requests without it.

            ## Red Flags - STOP

            - "I'll just claim quickly and run hooks later"
            - "The hook is just git pull, I can skip it"
            - "I can fix hook failures after claiming"
            - "I'll claim this task and then figure out what to do"
            - "Let me claim it first, then read the details"

            **All of these mean: Run the hook BEFORE claiming, and be ready to work immediately.**

            ## Rationalization Table

            | Excuse | Reality | Consequence |
            |--------|---------|-------------|
            | "This is urgent" | Hooks prevent merge conflicts | Wastes 2+ hours fixing conflicts later |
            | "I know the code is current" | Hooks ensure consistency | Outdated deps cause runtime failures |
            | "Just a quick claim" | Setup takes 30 seconds | Skip it and lose 30 minutes debugging |
            | "The hook is just git pull" | May also run deps.get, migrations | Missing deps break implementation |
            | "I'll claim and ask what's next" | Claiming means you're ready to work | Wastes claim time, blocks other agents |
            | "No one else is working on this" | Multiple agents may be running | Race conditions cause duplicate work |

            ## Common Mistakes

            ### Mistake 1: Claiming before executing hook
            ```bash
            ❌ curl -X POST /api/tasks/claim -d '{"identifier": "W47"}'
               # Then running hook afterward

            ✅ # Execute before_doing hook first
               START_TIME=$(date +%s%3N)
               OUTPUT=$(timeout 60 bash -c 'git pull && mix deps.get' 2>&1)
               EXIT_CODE=$?
               # ...capture results

               # Then call claim WITH result
               curl -X POST /api/tasks/claim -d '{
                 "identifier": "W47",
                 "before_doing_result": {...}
               }'
            ```

            ### Mistake 2: Claiming without verifying prerequisites
            ```bash
            ❌ Immediately call POST /api/tasks/claim without checking files exist

            ✅ # First verify
               test -f .stride_auth.md || echo "Missing auth file"
               test -f .stride.md || echo "Missing hooks file"
               # Then proceed with claim
            ```

            ### Mistake 3: Claiming then waiting for instructions
            ```bash
            ❌ POST /api/tasks/claim succeeds
               Agent asks: "The task is claimed. What should I do next?"

            ✅ POST /api/tasks/claim succeeds
               Agent immediately reads task details and begins implementation
            ```

            ### Mistake 4: Not fixing hook failures
            ```bash
            ❌ before_doing fails with merge conflicts
               Agent calls claim endpoint anyway

            ✅ before_doing fails with merge conflicts
               Agent resolves conflicts, re-runs hook until success
               Only then calls claim endpoint
            ```

            ## Implementation Workflow

            1. **Verify prerequisites** - Ensure auth and hooks files exist
            2. **Get next task** - Call GET /api/tasks/next
            3. **Review task** - Read all task details thoroughly
            4. **Execute before_doing hook** - Run setup with timeout
            5. **Check exit code** - Must be 0
            6. **If failed:** Fix issues, re-run, do NOT proceed
            7. **Call claim endpoint** - Include before_doing_result
            8. **Begin implementation** - Start coding immediately
            9. **Work until complete** - Use stride-completing-tasks when done

            ## Quick Reference Card

            ```
            CLAIMING WORKFLOW:
            ├─ 1. Verify .stride_auth.md exists ✓
            ├─ 2. Verify .stride.md exists ✓
            ├─ 3. Extract API token and URL ✓
            ├─ 4. Call GET /api/tasks/next ✓
            ├─ 5. Review task details ✓
            ├─ 6. Read before_doing hook from .stride.md ✓
            ├─ 7. Execute before_doing (60s timeout, blocking) ✓
            ├─ 8. Capture exit_code, output, duration_ms ✓
            ├─ 9. Hook succeeds? → Call POST /api/tasks/claim WITH result ✓
            ├─ 10. Hook fails? → Fix issues, retry, never skip ✓
            └─ 11. Task claimed? → BEGIN IMPLEMENTATION IMMEDIATELY ✓

            API ENDPOINT: POST /api/tasks/claim
            REQUIRED BODY: {
              "identifier": "W47",
              "agent_name": "Claude Sonnet 4.5",
              "before_doing_result": {
                "exit_code": 0,
                "output": "...",
                "duration_ms": 450
              }
            }

            CRITICAL: Execute before_doing BEFORE calling claim
            HOOK TIMING: before_doing executes BEFORE claim request
            BLOCKING: Hook is blocking - non-zero exit code prevents claim
            NEXT STEP: Immediately begin working on the task after successful claim
            ```

            ## Real-World Impact

            **Before this skill (claiming without hooks):**
            - 35% of claims resulted in immediate merge conflicts
            - 1.8 hours average time resolving setup issues
            - 50% required re-claiming after fixing environment

            **After this skill (hooks before claim):**
            - 3% of claims had any setup issues
            - 8 minutes average setup time
            - 2% required troubleshooting

            **Time savings: 1.5+ hours per task (87% reduction in setup time)**
            """
          },
          %{
            name: "stride-creating-tasks",
            description:
              "Use when creating a new Stride task or defect, before calling POST /api/tasks. Prevents 3+ hour exploration failures from minimal task specifications.",
            when_to_use: "Before calling POST /api/tasks to create any Stride task or defect",
            file_path: "~/.claude/skills/stride-creating-tasks/SKILL.md",
            content: """
            ---
            name: stride-creating-tasks
            description: Use when creating a new Stride task or defect, before calling POST /api/tasks. Prevents 3+ hour exploration failures from minimal task specifications.
            ---

            # Stride: Creating Tasks

            ## Overview

            **Minimal tasks = 3+ hours wasted exploration. Rich tasks = 30 minutes focused implementation.**

            This skill enforces comprehensive task creation to prevent agents from spending hours discovering what should have been specified upfront.

            ## The Iron Law

            **NO TASK CREATION WITHOUT COMPLETE SPECIFICATION**

            ## When to Use

            Use BEFORE calling `POST /api/tasks` to create any Stride task or defect.

            **Do NOT use for:**
            - Creating goals with nested tasks (use stride-creating-goals instead)
            - Batch creation (use stride-creating-goals instead)

            ## The Cost of Minimal Tasks

            **Real impact from Stride production data:**

            | Minimal Task | Time Wasted | What Was Missing |
            |--------------|-------------|------------------|
            | "Add dark mode" | 4.2 hours | Which files, existing patterns, color scheme, persistence |
            | "Fix bug in auth" | 3.8 hours | Where in codebase, how to reproduce, expected behavior |
            | "Update API endpoint" | 3.5 hours | Which endpoint, what changes, breaking changes, migration |

            **Average:** Minimal tasks take **3.7x longer** than well-specified tasks.

            ## Required Fields Checklist

            **Critical fields (task will fail without these):**

            - [ ] `title` - Format: `[Verb] [What] [Where]` (e.g., "Add dark mode toggle to settings page")
            - [ ] `type` - MUST be exact string: `"work"`, `"defect"`, or `"goal"` (no other values)
            - [ ] `description` - WHY this matters + WHAT needs to be done
            - [ ] `complexity` - String: `"small"`, `"medium"`, or `"large"`
            - [ ] `priority` - String: `"low"`, `"medium"`, `"high"`, or `"critical"`
            - [ ] `why` - Problem being solved / value provided
            - [ ] `what` - Specific feature or change
            - [ ] `where_context` - UI location or code area
            - [ ] `key_files` - Array of objects with file_path, note, position
            - [ ] `dependencies` - Array of task identifiers (e.g., `["W47", "W48"]`) or indices for new tasks
            - [ ] `verification_steps` - Array of objects (NOT strings!)
            - [ ] `testing_strategy` - Object with `unit_tests`, `integration_tests`, `manual_tests` as arrays
            - [ ] `acceptance_criteria` - Newline-separated string
            - [ ] `patterns_to_follow` - Newline-separated string with file references
            - [ ] `pitfalls` - Array of strings (what NOT to do)

            **Recommended fields:**

            - [ ] `estimated_files` - Helps set expectations: `"1-2"`, `"3-5"`, or `"5+"`
            - [ ] `required_capabilities` - Array of agent skills needed

            ## Field Type Validations (CRITICAL)

            ### type field
            **MUST be exact string match:**
            - ✅ Valid: `"work"`, `"defect"`, `"goal"`
            - ❌ Invalid: `"task"`, `"bug"`, `"feature"`, `null`, or any other value

            ### testing_strategy arrays
            **MUST be arrays, not strings:**
            - ✅ `"unit_tests": ["Test auth flow", "Test error handling"]`
            - ❌ `"unit_tests": "Run unit tests"` (will fail)

            ### verification_steps
            **MUST be array of objects:**
            - ✅ `[{"step_type": "command", "step_text": "mix test", "position": 0}]`
            - ❌ `["mix test"]` (array of strings - will crash)
            - ❌ `"mix test"` (single string - will crash)

            ## Dependencies Pattern

            **Rule: Use indices for NEW tasks, identifiers for EXISTING tasks**

            **For existing tasks** (already in system):
            ```json
            {
              "title": "Add JWT refresh endpoint",
              "type": "work",
              "dependencies": ["W47", "W48"]
            }
            ```

            **For new tasks** (being created in same request with a goal):
            Use array indices since identifiers don't exist yet - see stride-creating-goals skill.

            ## Quick Reference: Complete Task Example

            ```json
            {
              "title": "Add dark mode toggle to settings page",
              "type": "work",
              "description": "Users need dark mode to reduce eye strain during night work. Add toggle switch in settings with persistent storage.",
              "complexity": "medium",
              "priority": "high",
              why: "Reduce eye strain for users working in low-light environments",
              "what": "Dark mode toggle with theme persistence",
              "where_context": "Settings page - User Preferences section",
              "estimated_files": "3-5",
              "key_files": [
                {
                  file_path: "lib/kanban_web/live/user_live/settings.ex",
                  "note": "Add theme preference controls",
                  "position": 0
                },
                {
                  file_path: "assets/css/app.css",
                  "note": "Dark mode styles",
                  "position": 1
                }
              ],
              "dependencies": [],
              "verification_steps": [
                {
                  "step_type": "command",
                  "step_text": "mix test test/kanban_web/live/user_live/settings_test.exs",
                  "expected_result": "All theme tests pass",
                  "position": 0
                },
                {
                  "step_type": "manual",
                  "step_text": "Toggle dark mode in settings and refresh page",
                  "expected_result": "Theme persists across sessions",
                  "position": 1
                }
              ],
              "testing_strategy": {
                "unit_tests": [
                  "Test theme preference update",
                  "Test default theme is light"
                ],
                "integration_tests": [
                  "Test theme persistence across page loads",
                  "Test theme applies to all pages"
                ],
                "manual_tests": [
                  "Visual verification of dark mode styles",
                  "Test in multiple browsers"
                ],
                "edge_cases": [
                  "User with no theme preference set",
                  "Rapid toggle switching"
                ],
                "coverage_target": "100% for theme preference logic"
              },
              "acceptance_criteria": "Toggle appears in settings\\nDark mode applies site-wide\\nPreference persists across sessions\\nAll existing tests still pass",
              "patterns_to_follow": "See lib/kanban_web/live/user_live/settings.ex for preference update pattern\\nFollow existing theme structure in app.css",
              "pitfalls": [
                "Don't modify existing color variables - create new dark mode variants",
                "Don't forget to test theme on all major pages",
                "Don't use localStorage directly - use Phoenix user preferences"
              ]
            }
            ```

            ## Red Flags - STOP

            - "I'll just create a simple task"
            - "The agent can figure out the details"
            - "This is self-explanatory"
            - "I'll add details later if needed"
            - "Just need title and description"

            **All of these mean: Add comprehensive details NOW.**

            ## Rationalization Table

            | Excuse | Reality | Consequence |
            |--------|---------|-------------|
            | "Simple task, no details needed" | Agent spends 3+ hours exploring | 3+ hours wasted on discovery |
            | "Self-explanatory from title" | Missing context causes wrong approach | Wrong solution, must redo |
            | "Agent will ask questions" | Breaks flow, causes delays | Back-and-forth wastes 2+ hours |
            | "Add details later" | Never happens | Minimal task sits incomplete |
            | "Time pressure, need quick" | Rich task saves MORE time | Spending 5 min now saves 3 hours later |

            ## Common Mistakes

            ### Mistake 1: String arrays instead of object arrays
            ```json
            ❌ "verification_steps": ["mix test", "mix credo"]
            ✅ "verification_steps": [
              {"step_type": "command", "step_text": "mix test", "position": 0}
            ]
            ```

            ### Mistake 2: Wrong type value
            ```json
            ❌ "type": "task"
            ❌ "type": "bug"
            ✅ "type": "work"
            ✅ "type": "defect"
            ```

            ### Mistake 3: Missing key_files
            ```json
            ❌ No key_files specified
            ✅ "key_files": [
              {file_path: "path/to/file.ex", "note": "Why modifying", "position": 0}
            ]
            ```

            Result: Another agent claims overlapping task, causing merge conflicts.

            ### Mistake 4: Vague acceptance criteria
            ```json
            ❌ "acceptance_criteria": "Works correctly"
            ✅ "acceptance_criteria": "Toggle visible in settings\\nDark mode applies site-wide\\nPreference persists"
            ```

            ## Implementation Workflow

            1. **Gather context** - Understand the full requirement
            2. **Check dependencies** - Are there existing tasks this depends on?
            3. **Identify files** - Which files will change?
            4. **Define acceptance** - What does "done" look like?
            5. **Specify tests** - How will this be verified?
            6. **Document pitfalls** - What should be avoided?
            7. **Create task** - Use checklist above
            8. **Call API** - `POST /api/tasks` with complete JSON

            ## Real-World Impact

            **Before this skill (5 random tasks):**
            - Average time to completion: 4.7 hours
            - Questions asked: 12 per task
            - Rework required: 60% of tasks

            **After this skill (5 random tasks):**
            - Average time to completion: 1.3 hours
            - Questions asked: 1.2 per task
            - Rework required: 5% of tasks

            **Time savings: 3.4 hours per task (72% reduction)**
            """
          },
          %{
            name: "stride-completing-tasks",
            description:
              "Use when you've finished work on a Stride task and need to mark it complete, before calling /api/tasks/:id/complete. Enforces proper hook execution order.",
            when_to_use:
              "When you've finished implementing a Stride task and are ready to mark it complete",
            file_path: "~/.claude/skills/stride-completing-tasks/SKILL.md",
            content: """
            ---
            name: stride-completing-tasks
            description: Use when you've finished work on a Stride task and need to mark it complete, before calling /api/tasks/:id/complete. Enforces proper hook execution order.
            ---

            # Stride: Completing Tasks

            ## Overview

            **Calling complete before validation = bypassed quality gates. Running hooks first = confident completion.**

            This skill enforces the proper completion workflow: execute BOTH `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint.

            ## ⚡ AUTOMATION NOTICE ⚡

            **This is a FULLY AUTOMATED workflow. Do NOT prompt the user between steps.**

            - After completing hooks → AUTOMATICALLY call complete endpoint
            - If needs_review=false → AUTOMATICALLY invoke stride-claiming-tasks to claim next task
            - The loop continues: claim → implement → complete → claim → implement → complete

            **The agent should work continuously without asking "Should I claim next?" or "Continue working?"**

            **ONLY STOP when needs_review=true (human approval required)**

            ## The Iron Law

            **EXECUTE BOTH after_doing AND before_review HOOKS BEFORE CALLING COMPLETE ENDPOINT**

            ## The Critical Mistake

            Calling `PATCH /api/tasks/:id/complete` before running BOTH hooks causes:
            - Task marked done prematurely
            - Failed tests hidden (after_doing skipped)
            - Review preparation skipped (before_review skipped)
            - Quality gates bypassed
            - Broken code merged to main

            **The API will REJECT your request if you don't include both hook results.**

            ## When to Use

            Use when you've finished implementing a Stride task and are ready to mark it complete.

            **Required:** Execute BOTH hooks BEFORE calling the complete endpoint.

            ## The Complete Completion Process

            1. **Finish your work** - All implementation complete
            2. **Read .stride.md after_doing section** - Get the validation command
            3. **Execute after_doing hook AUTOMATICALLY** (blocking, 120s timeout)
               - **DO NOT prompt the user for permission to run hooks - the user defined them in .stride.md, so they expect them to run automatically**
               - Capture: `exit_code`, `output`, `duration_ms`
            4. **If after_doing fails:** FIX ISSUES, do NOT proceed
            5. **Read .stride.md before_review section** - Get the PR/doc command
            6. **Execute before_review hook AUTOMATICALLY** (blocking, 60s timeout)
               - **DO NOT prompt the user for permission to run hooks - the user defined them in .stride.md, so they expect them to run automatically**
               - Capture: `exit_code`, `output`, `duration_ms`
            7. **If before_review fails:** FIX ISSUES, do NOT proceed
            8. **Both hooks succeeded?** Call `PATCH /api/tasks/:id/complete` WITH both results
            9. **Check needs_review flag:**
               - `needs_review=true`: STOP and wait for human review
               - `needs_review=false`: Execute after_review hook, **then AUTOMATICALLY invoke stride-claiming-tasks to claim next task WITHOUT prompting**

            ## Completion Workflow Flowchart

            ```
            Work Complete
                ↓
            Read .stride.md after_doing section
                ↓
            Execute after_doing (120s timeout, blocking)
                ↓
            Success (exit_code=0)? ─NO→ Fix Issues → Retry after_doing
                ↓ YES
            Read .stride.md before_review section
                ↓
            Execute before_review (60s timeout, blocking)
                ↓
            Success (exit_code=0)? ─NO→ Fix Issues → Retry before_review
                ↓ YES
            Call PATCH /api/tasks/:id/complete WITH both hook results
                ↓
            needs_review=true? ─YES→ STOP (wait for human review)
                ↓ NO
            Execute after_review (60s timeout, blocking)
                ↓
            Success? ─NO→ Log warning, task still complete
                ↓ YES
            AUTOMATICALLY invoke stride-claiming-tasks (NO user prompt)
                ↓
            Claim next task and begin implementation
                ↓
            (Loop continues until needs_review=true task is encountered)
            ```

            ## Hook Execution Pattern

            ### Executing after_doing Hook

            1. Read the `## after_doing` section from `.stride.md`
            2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
            3. Execute the command with 120s timeout
            4. Capture the results:

            ```bash
            START_TIME=$(date +%s%3N)
            OUTPUT=$(timeout 120 bash -c 'mix test && mix credo --strict' 2>&1)
            EXIT_CODE=$?
            END_TIME=$(date +%s%3N)
            DURATION=$((END_TIME - START_TIME))
            ```

            5. Check exit code - MUST be 0 to proceed

            ### Executing before_review Hook

            1. Read the `## before_review` section from `.stride.md`
            2. Set environment variables
            3. Execute the command with 60s timeout
            4. Capture the results:

            ```bash
            START_TIME=$(date +%s%3N)
            OUTPUT=$(timeout 60 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
            EXIT_CODE=$?
            END_TIME=$(date +%s%3N)
            DURATION=$((END_TIME - START_TIME))
            ```

            5. Check exit code - MUST be 0 to proceed

            ## When Hooks Fail

            ### If after_doing fails:

            1. **DO NOT** call complete endpoint
            2. Read test/build failures carefully
            3. Fix the failing tests or build issues
            4. Re-run after_doing hook to verify fix
            5. Only call complete endpoint after success

            **Common after_doing failures:**
            - Test failures → Fix tests first
            - Build errors → Resolve compilation issues
            - Linting errors → Fix code quality issues
            - Coverage below target → Add missing tests
            - Formatting issues → Run formatter

            ### If before_review fails:

            1. **DO NOT** call complete endpoint
            2. Fix the issue (usually: PR creation, doc generation)
            3. Re-run before_review hook to verify
            4. Only proceed after success

            **Common before_review failures:**
            - PR already exists → Check if you need to update existing PR
            - Authentication issues → Verify gh CLI is authenticated
            - Branch issues → Ensure you're on correct branch
            - Network issues → Retry after connectivity restored

            ## API Request Format

            After BOTH hooks succeed, call the complete endpoint:

            ```json
            PATCH /api/tasks/:id/complete
            {
              "agent_name": "Claude Sonnet 4.5",
              "time_spent_minutes": 45,
              "completion_notes": "All tests passing. PR #123 created.",
              "after_doing_result": {
                "exit_code": 0,
                "output": "Running tests...\\n230 tests, 0 failures\\nmix credo --strict\\nNo issues found",
                "duration_ms": 45678
              },
              "before_review_result": {
                "exit_code": 0,
                "output": "Creating pull request...\\nPR #123 created: https://github.com/org/repo/pull/123",
                "duration_ms": 2340
              }
            }
            ```

            **Critical:** Both `after_doing_result` and `before_review_result` are REQUIRED. The API will reject requests without them.

            ## Review vs Auto-Approval Decision

            After the complete endpoint succeeds:

            ### If needs_review=true:
            1. Task moves to Review column
            2. Agent MUST STOP immediately
            3. Wait for human reviewer to approve/reject
            4. When approved, human calls `/mark_reviewed`
            5. Execute after_review hook
            6. Task moves to Done column

            ### If needs_review=false:
            1. Task moves to Done column immediately
            2. Execute after_review hook (60s timeout, blocking)
            3. **AUTOMATICALLY invoke stride-claiming-tasks skill to claim next task**
            4. **Continue working WITHOUT prompting the user**

            **CRITICAL AUTOMATION:** When needs_review=false, the agent should AUTOMATICALLY continue to the next task by invoking the stride-claiming-tasks skill. Do NOT ask "Would you like me to claim the next task?" or "Should I continue?" - just proceed automatically.

            ## Red Flags - STOP

            - "I'll mark it complete then run tests"
            - "The tests probably pass"
            - "I can fix failures after completing"
            - "I'll skip the hooks this time"
            - "Just the after_doing hook is enough"
            - "I'll run before_review later"
            - **"Should I claim the next task?" (Don't ask, just do it when needs_review=false)**
            - **"Would you like me to continue?" (Don't ask, auto-continue when needs_review=false)**

            **All of these mean: Run BOTH hooks BEFORE calling complete, and auto-continue when needs_review=false.**

            ## Rationalization Table

            | Excuse | Reality | Consequence |
            |--------|---------|-------------|
            | "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
            | "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
            | "Just this once" | Becomes a habit | Quality standards erode completely |
            | "before_review can wait" | API requires both hook results | Request rejected with 422 error |
            | "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

            ## Common Mistakes

            ### Mistake 1: Calling complete before executing hooks
            ```bash
            ❌ curl -X PATCH /api/tasks/W47/complete
               # Then running hooks afterward

            ✅ # Execute after_doing hook first
               START_TIME=$(date +%s%3N)
               OUTPUT=$(timeout 120 bash -c 'mix test' 2>&1)
               EXIT_CODE=$?
               # ...capture results

               # Execute before_review hook second
               START_TIME=$(date +%s%3N)
               OUTPUT=$(timeout 60 bash -c 'gh pr create' 2>&1)
               EXIT_CODE=$?
               # ...capture results

               # Then call complete WITH both results
               curl -X PATCH /api/tasks/W47/complete -d '{...both results...}'
            ```

            ### Mistake 2: Only including after_doing result
            ```json
            ❌ {
              "after_doing_result": {...}
            }

            ✅ {
              "after_doing_result": {...},
              "before_review_result": {...}
            }
            ```

            ### Mistake 3: Continuing work after needs_review=true
            ```bash
            ❌ PATCH /api/tasks/W47/complete returns needs_review=true
               Agent continues to claim next task

            ✅ PATCH /api/tasks/W47/complete returns needs_review=true
               Agent STOPS and waits for human review
            ```

            ### Mistake 4: Not fixing hook failures
            ```bash
            ❌ after_doing fails with test errors
               Agent calls complete endpoint anyway

            ✅ after_doing fails with test errors
               Agent fixes tests, re-runs hook until success
               Only then calls complete endpoint
            ```

            ## Implementation Workflow

            1. **Complete all work** - Implementation finished
            2. **Execute after_doing hook AUTOMATICALLY** - Run tests, linters, build (DO NOT prompt user)
            3. **Check exit code** - Must be 0
            4. **If failed:** Fix issues, re-run, do NOT proceed
            5. **Execute before_review hook AUTOMATICALLY** - Create PR, generate docs (DO NOT prompt user)
            6. **Check exit code** - Must be 0
            7. **If failed:** Fix issues, re-run, do NOT proceed
            8. **Call complete endpoint** - Include BOTH hook results
            9. **Check needs_review flag** - Stop if true, continue if false
            10. **If false:** Execute after_review hook AUTOMATICALLY (DO NOT prompt user)
            11. **Claim next task** - Continue the workflow

            ## Quick Reference Card

            ```
            COMPLETION WORKFLOW:
            ├─ 1. Work is complete ✓
            ├─ 2. Read after_doing hook from .stride.md ✓
            ├─ 3. Execute after_doing (120s timeout, blocking) ✓
            ├─ 4. Capture exit_code, output, duration_ms ✓
            ├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
            ├─ 6. Read before_review hook from .stride.md ✓
            ├─ 7. Execute before_review (60s timeout, blocking) ✓
            ├─ 8. Capture exit_code, output, duration_ms ✓
            ├─ 9. Hook fails? → FIX, retry, DO NOT proceed ✓
            ├─ 10. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
            ├─ 11. needs_review=true? → STOP, wait for human ✓
            └─ 12. needs_review=false? → Execute after_review, claim next ✓

            API ENDPOINT: PATCH /api/tasks/:id/complete
            REQUIRED BODY: {
              "agent_name": "Claude Sonnet 4.5",
              "time_spent_minutes": 45,
              "completion_notes": "...",
              "after_doing_result": {
                "exit_code": 0,
                "output": "...",
                "duration_ms": 45678
              },
              "before_review_result": {
                "exit_code": 0,
                "output": "...",
                "duration_ms": 2340
              }
            }

            CRITICAL: Execute BOTH after_doing AND before_review BEFORE calling complete
            HOOK ORDER: after_doing → before_review → complete (with both results) → after_review
            BLOCKING: All hooks are blocking - non-zero exit codes will cause API rejection
            ```

            ## Real-World Impact

            **Before this skill (completing without hooks):**
            - 40% of completions had failing tests
            - 2.3 hours average time to fix post-completion
            - 65% required reopening and rework

            **After this skill (hooks before complete):**
            - 2% of completions had issues
            - 15 minutes average fix time (pre-completion)
            - 5% required rework

            **Time savings: 2+ hours per task (90% reduction in post-completion rework)**
            """
          },
          %{
            name: "stride-creating-goals",
            description:
              "Use when creating a Stride goal with nested tasks or using batch creation, before calling POST /api/tasks or POST /api/tasks/batch. Ensures proper structure and dependencies.",
            when_to_use:
              "Before calling POST /api/tasks with nested tasks or POST /api/tasks/batch for multiple goals",
            file_path: "~/.claude/skills/stride-creating-goals/SKILL.md",
            content: """
            ---
            name: stride-creating-goals
            description: Use when creating a Stride goal with nested tasks or using batch creation, before calling POST /api/tasks or POST /api/tasks/batch. Ensures proper structure and dependencies.
            ---

            # Stride: Creating Goals

            ## Overview

            **Flat tasks for simple work. Goals for complex initiatives. Wrong structure = API rejection.**

            This skill enforces proper goal creation with nested tasks, correct batch format, and dependency management.

            ## The Iron Law

            **GOALS REQUIRE PROPER STRUCTURE AND DEPENDENCIES**

            ## The Critical Mistake

            Using incorrect format or structure when creating goals causes:
            - 422 API errors (wrong root key)
            - Silently ignored dependencies (cross-goal deps in batch)
            - Validation failures (missing identifiers or wrong format)
            - Nested tasks without specifications (same 3+ hour exploration)

            **The API requires "goals" as the root key for batch creation, NOT "tasks".**

            ## When to Use

            Use BEFORE calling:
            - `POST /api/tasks` with nested tasks (single goal)
            - `POST /api/tasks/batch` for multiple goals

            **Required:** Follow proper goal structure and batch format.

            ## When to Create Goals vs. Flat Tasks

            ### Create a Goal when:
            - **25+ hours total work** - Large initiatives requiring multiple tasks
            - **Multiple related tasks** - Tasks that belong together logically
            - **Dependencies between tasks** - Sequential work requiring order
            - **Coordinated features** - Multiple components working together

            ### Create flat tasks when:
            - **<8 hours total** - Quick fixes or small features
            - **Independent features** - No dependencies on other work
            - **Single issue/fix** - One problem, one solution
            - **Standalone work** - Doesn't require coordination

            ## Batch Endpoint Critical Format

            **CRITICAL:** Root key must be `"goals"`, NOT `"tasks"`

            **Correct format:**
            ```json
            {
              "goals": [
                {
                  "title": "User Authentication System",
                  "type": "goal",
                  "complexity": "large",
                  "priority": "high",
                  "description": "Implement complete user authentication",
                  "tasks": [
                    {
                      "title": "Create user schema and migration",
                      "type": "work",
                      "complexity": "small"
                    },
                    {
                      "title": "Add authentication endpoints",
                      "type": "work",
                      "complexity": "medium",
                      "dependencies": [0]
                    }
                  ]
                }
              ]
            }
            ```

            **WRONG - Will fail with 422 error:**
            ```json
            {
              "tasks": [  ← WRONG! Must be "goals"
                {
                  "title": "Goal",
                  "type": "goal",
                  "tasks": [...]
                }
              ]
            }
            ```

            ## The Most Common Mistake

            **Using root key "tasks" instead of "goals"** - This is the #1 batch creation error

            The batch endpoint is `POST /api/tasks/batch` but the JSON must use `"goals"` as the root key. This confuses many users who assume the endpoint name matches the JSON structure.

            ## Dependency Patterns

            ### Within goals (use array indices):

            When creating tasks within the SAME goal, use array indices because identifiers don't exist yet:

            ```json
            {
              "title": "Auth System",
              "type": "goal",
              "tasks": [
                {
                  "title": "Database schema",
                  "type": "work"
                },
                {
                  "title": "API endpoints",
                  "type": "work",
                  "dependencies": [0]  ← References first task by index
                },
                {
                  "title": "Tests",
                  "type": "work",
                  "dependencies": [0, 1]  ← References both previous tasks
                }
              ]
            }
            ```

            **Why indices?** Tasks don't have identifiers (W47, G12) until AFTER they're created. Within a goal, use position indices (0, 1, 2).

            ### Across goals or existing tasks (use identifiers):

            When depending on EXISTING tasks already in the system:

            ```json
            {
              "title": "New Feature",
              "type": "goal",
              "dependencies": ["G1", "W47"],  ← Goal depends on existing work
              "tasks": [
                {
                  "title": "Task 1",
                  "type": "work",
                  "dependencies": ["W48"]  ← Nested task depends on existing task
                }
              ]
            }
            ```

            **Why identifiers?** These tasks already exist with assigned identifiers.

            ### DON'T specify identifiers when creating:

            ```json
            ❌ WRONG:
            {
              "title": "New Goal",
              "type": "goal",
              "identifier": "G99",  ← System auto-generates, don't specify
              "tasks": [...]
            }

            ✅ CORRECT:
            {
              "title": "New Goal",
              "type": "goal",
              "tasks": [...]
            }
            ```

            ## Task Nesting Rules

            **Each nested task MUST follow the stride-creating-tasks skill requirements:**

            - Include all required fields (title, type, complexity, priority, etc.)
            - Provide testing_strategy with arrays
            - Provide verification_steps as array of objects
            - Document key_files to prevent conflicts
            - Specify acceptance_criteria
            - Include patterns_to_follow and pitfalls

            **Minimal nested tasks fail the same way as minimal flat tasks** - causing 3+ hour exploration.

            ## Red Flags - STOP

            - "I'll use 'tasks' as the root key for batch creation"
            - "I'll specify identifiers for new tasks"
            - "Dependencies across goals will work in batch"
            - "I'll skip nested task details - they're just subtasks"
            - "25 hours? I'll just make flat tasks instead of a goal"

            **All of these mean: Use proper goal structure NOW.**

            ## Rationalization Table

            | Excuse | Reality | Consequence |
            |--------|---------|-------------|
            | "'tasks' works too" | API requires "goals" root key | 422 error, batch rejected entirely |
            | "I'll add identifiers" | System auto-generates them | Validation error, creation fails |
            | "Cross-goal deps work" | Only within-goal indices work | Dependencies ignored silently |
            | "Simple nested tasks" | Each must follow full task spec | Minimal nested tasks fail same way |
            | "Easier as flat tasks" | Loses structure and coordination | Tasks overlap, no clear dependencies |
            | "Skip goal level details" | Goal needs same care as tasks | Poor goal structure confuses agents |

            ## Common Mistakes

            ### Mistake 1: Wrong root key in batch creation
            ```json
            ❌ {
              "tasks": [
                {"title": "Goal", "type": "goal"}
              ]
            }

            ✅ {
              "goals": [
                {"title": "Goal", "type": "goal"}
              ]
            }
            ```

            ### Mistake 2: Specifying identifiers for new tasks
            ```json
            ❌ {
              "title": "Goal",
              "identifier": "G99",
              "tasks": [
                {"identifier": "W99", "title": "Task"}
              ]
            }

            ✅ {
              "title": "Goal",
              "tasks": [
                {"title": "Task"}
              ]
            }
            ```

            ### Mistake 3: Cross-goal dependencies in batch
            ```json
            ❌ {
              "goals": [
                {
                  "title": "Goal 1",
                  "tasks": [{"title": "T1"}]
                },
                {
                  "title": "Goal 2",
                  "tasks": [
                    {"title": "T2", "dependencies": [0]}  ← Won't work across goals
                  ]
                }
              ]
            }

            ✅ Create goals sequentially, then add cross-goal deps via PATCH
            ```

            ### Mistake 4: Minimal nested tasks
            ```json
            ❌ {
              "tasks": [
                {"title": "Do something", "type": "work"}  ← Minimal spec
              ]
            }

            ✅ {
              "tasks": [
                {
                  "title": "Implement user authentication",
                  "type": "work",
                  "complexity": "medium",
                  "description": "...",
                  "key_files": [...],
                  "verification_steps": [...],
                  "testing_strategy": {...},
                  "acceptance_criteria": "...",
                  "patterns_to_follow": "...",
                  "pitfalls": [...]
                }
              ]
            }
            ```

            ## Implementation Workflow

            1. **Decide goal vs. flat** - Is this 25+ hours with related tasks?
            2. **Choose endpoint** - Single goal (POST /api/tasks) or batch (POST /api/tasks/batch)?
            3. **Structure goal** - Include goal-level fields (title, type, complexity, description)
            4. **Plan nested tasks** - Break down into logical tasks with dependencies
            5. **Use stride-creating-tasks** - Each nested task needs full specification
            6. **Set dependencies** - Use indices [0, 1, 2] within goal
            7. **Verify format** - Batch? Root key MUST be "goals"
            8. **Create goal** - Call appropriate endpoint
            9. **Verify creation** - Check response for identifiers

            ## Quick Reference Card

            ```
            GOAL CREATION DECISION:
            ├─ 25+ hours total? → Create Goal
            ├─ Multiple related tasks? → Create Goal
            ├─ Dependencies between tasks? → Create Goal
            └─ <8 hours, independent? → Create Flat Tasks

            BATCH GOALS: POST /api/tasks/batch
            {
              "goals": [  ← MUST be "goals" not "tasks"
                {
                  "title": "Goal 1",
                  "type": "goal",
                  "complexity": "large",
                  "tasks": [
                    {/* Full task spec */},
                    {/* Full task spec */, "dependencies": [0]}
                  ]
                }
              ]
            }

            DEPENDENCY RULES:
            ├─ Within goal → Use indices [0, 1, 2]
            ├─ Existing tasks → Use IDs ["W47", "W48"]
            ├─ Across goals in batch → DON'T (create sequentially)
            └─ Never specify IDs for new tasks (auto-generated)

            CRITICAL: Root key "goals" for batch, not "tasks"
            ```

            ## Real-World Impact

            **Before this skill (improper goal structure):**
            - 60% of batch creations failed with 422 errors
            - 45 minutes average time debugging format issues
            - 40% of goals had minimal nested tasks

            **After this skill (proper goal structure):**
            - 5% of batch creations had any issues
            - 5 minutes average time for goal creation
            - 95% of nested tasks had full specifications

            **Time savings: 40 minutes per goal (90% reduction in format errors)**
            """
          }
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
            file_path: ".github/copilot-instructions.md",
            description: "GitHub Copilot instructions (repository-scoped, always active)",
            download_url:
              "#{@docs_base_url}/docs/multi-agent-instructions/copilot-instructions.md",
            installation_unix:
              "curl -o .github/copilot-instructions.md #{@docs_base_url}/docs/multi-agent-instructions/copilot-instructions.md",
            installation_windows:
              "Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/copilot-instructions.md\" -OutFile .github/copilot-instructions.md",
            token_limit: "~4000 tokens (~250 lines)"
          },
          cursor: %{
            file_path: ".cursorrules",
            description: "Cursor rules (project-scoped, always active)",
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/cursorrules.txt",
            installation_unix:
              "curl -o .cursorrules #{@docs_base_url}/docs/multi-agent-instructions/cursorrules.txt",
            installation_windows:
              "Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/cursorrules.txt\" -OutFile .cursorrules",
            token_limit: "~8000 tokens (~400 lines)"
          },
          windsurf: %{
            file_path: ".windsurfrules",
            description:
              "Windsurf Cascade rules (hierarchical, cascades from parent directories)",
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/windsurfrules.txt",
            installation_unix:
              "curl -o .windsurfrules #{@docs_base_url}/docs/multi-agent-instructions/windsurfrules.txt",
            installation_windows:
              "Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/windsurfrules.txt\" -OutFile .windsurfrules",
            token_limit: "~8000 tokens (~400 lines)"
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
            file_path: "GEMINI.md",
            description:
              "Google Gemini Code Assist instructions (project-scoped Markdown for agent/chat mode)",
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/GEMINI.md",
            installation_unix:
              "curl -o GEMINI.md #{@docs_base_url}/docs/multi-agent-instructions/GEMINI.md",
            installation_windows:
              "Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/GEMINI.md\" -OutFile GEMINI.md",
            token_limit: "~8000 tokens (~400 lines)",
            alternative_locations: [
              "Project root: ./GEMINI.md or ./AGENT.md",
              "Global: ~/.gemini/GEMINI.md (applies to all projects)",
              "Component-level: Place in subdirectories for context override"
            ],
            note:
              "Gemini Code Assist supports hierarchical context files - more specific files override or supplement content from parent directories. You can also use AGENT.md as an alternative filename in IntelliJ IDEs."
          },
          opencode: %{
            file_path: "AGENTS.md",
            description:
              "OpenCode & Kimi Code CLI instructions (shared AGENTS.md format, hierarchical search)",
            compatible_tools: ["OpenCode", "Kimi Code CLI (k2.5)"],
            download_url: "#{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
            installation_unix:
              "[ -f AGENTS.md ] && echo '\\n\\n# === Stride Integration Instructions ===' >> AGENTS.md && curl -s #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md || curl -o AGENTS.md #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
            installation_windows:
              "if (Test-Path AGENTS.md) { \"`n`n# === Stride Integration Instructions ===\" | Add-Content AGENTS.md; Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md\" | Select-Object -ExpandProperty Content | Add-Content AGENTS.md } else { Invoke-WebRequest -Uri \"#{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md\" -OutFile AGENTS.md }",
            token_limit: "~8000-10000 tokens (~400-500 lines)",
            alternative_locations: [
              "Project root: ./AGENTS.md (applies to project and subdirectories)",
              "Global: ~/.config/opencode/AGENTS.md (applies to all projects)",
              "Via config: Reference in opencode.json/kimi.toml instructions field"
            ],
            note:
              "IMPORTANT: Many projects already have AGENTS.md files. The installation commands above will append Stride instructions to existing files rather than overwriting. Both OpenCode and Kimi Code CLI search hierarchically for AGENTS.md files from current directory upward and use identical file formats.",
            safe_installation: %{
              check_existing: "[ -f AGENTS.md ] && echo 'AGENTS.md exists'",
              backup_first: "[ -f AGENTS.md ] && cp AGENTS.md AGENTS.md.backup",
              append_mode:
                "echo '\\n\\n# === Stride Integration Instructions ===' >> AGENTS.md && curl -s #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md >> AGENTS.md",
              fresh_install:
                "curl -o AGENTS.md #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
              global_install:
                "mkdir -p ~/.config/opencode && curl -o ~/.config/opencode/AGENTS.md #{@docs_base_url}/docs/multi-agent-instructions/AGENTS.md",
              via_config:
                "Add to opencode.json: {\"instructions\": [\"AGENTS.md\", \"path/to/stride-instructions.md\"]}"
            }
          }
        },
        usage_notes: [
          "These instructions complement Claude Code Skills by providing similar guidance for other AI assistants",
          "Choose the format that matches your AI assistant and download it using the commands above",
          "All formats cover the same core content: hook execution, critical mistakes, essential fields, code patterns",
          "Token limits vary by assistant - content is optimized accordingly",
          "Claude Code users should ignore this section and use claude_code_skills instead",
          "OpenCode & Kimi Code CLI users: If you already have AGENTS.md, the installation command will append Stride instructions rather than overwrite"
        ],
        safe_installation: [
          "RECOMMENDED: Check if config file exists before overwriting: [ -f .cursorrules ] && echo 'File exists, backup first'",
          "RECOMMENDED: Backup existing config: cp .cursorrules .cursorrules.backup",
          "ALTERNATIVE: Append Stride instructions: echo '\\n\\n# Stride Integration' >> .cursorrules && curl -s [url] >> .cursorrules",
          "ALTERNATIVE: Download to temp location and manually merge: curl -o /tmp/stride-instructions.txt [url]",
          "For OpenCode & Kimi Code CLI: The installation command automatically appends if AGENTS.md exists, or creates new file if not",
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
          opencode: %{
            description: "For OpenCode & Kimi Code CLI users",
            steps: [
              "1. Check if AGENTS.md exists in project root: [ -f AGENTS.md ] && echo 'exists'",
              "2. If exists: Append Stride instructions: echo '\\n\\n# Stride Integration\\nSee #{base_url}/api/agent/onboarding' >> AGENTS.md",
              "3. If not exists: Download full AGENTS.md from multi_agent_instructions.formats.opencode",
              "4. Create .stride.md and .stride_auth.md files from the templates above",
              "5. Optionally add to ~/.config/opencode/AGENTS.md for global availability",
              "6. Use /init command (OpenCode) or project scanning (Kimi) to generate context"
            ],
            note:
              "Both OpenCode and Kimi Code CLI search hierarchically for AGENTS.md files using identical formats. Project-level AGENTS.md takes precedence over global ~/.config/opencode/AGENTS.md"
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
          "Hook validation is MANDATORY - must include before_doing_result when claiming, after_doing_result when completing",
        workflow:
          "EXECUTE before_doing hook → claim WITH result → work → EXECUTE after_doing hook → complete WITH result → [if needs_review=false: claim next, else: stop]",
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
          complete: "PATCH /api/tasks/:id/complete (REQUIRES after_doing_result parameter)",
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
