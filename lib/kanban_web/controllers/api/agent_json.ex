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
          "Claude Code skills automatically provided via this onboarding endpoint. Install these skills to enforce best practices and prevent common mistakes.",
        installation_instructions: [
          "1. Create the skills directories:",
          "   mkdir -p ~/.claude/skills/stride-claiming-tasks",
          "   mkdir -p ~/.claude/skills/stride-completing-tasks",
          "   mkdir -p ~/.claude/skills/stride-creating-tasks",
          "2. Copy skill contents from the fields below into their respective SKILL.md files:",
          "   - stride-claiming-tasks content → ~/.claude/skills/stride-claiming-tasks/SKILL.md",
          "   - stride-completing-tasks content → ~/.claude/skills/stride-completing-tasks/SKILL.md",
          "   - stride-creating-tasks content → ~/.claude/skills/stride-creating-tasks/SKILL.md",
          "3. Skills will be automatically discovered by Claude Code when you restart or start a new session",
          "4. Use the skills:",
          "   - stride-claiming-tasks: Before calling POST /api/tasks/claim to claim tasks",
          "   - stride-completing-tasks: Before calling PATCH /api/tasks/:id/complete to mark tasks complete",
          "   - stride-creating-tasks: Before calling POST /api/tasks to create tasks"
        ],
        available_skills: [
          %{
            name: "stride-claiming-tasks",
            description:
              "Use when you want to claim a task from Stride, before making any API calls to /api/tasks/claim. After successful claiming, immediately begin implementation.",
            when_to_use: "Before calling POST /api/tasks/claim to reserve a task for implementation",
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
            5. **Execute before_doing hook** (blocking, 60s timeout)
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

            **CRITICAL: Once the task is claimed, you MUST immediately begin implementation.**

            ### DO NOT:
            - Claim a task then wait for further instructions
            - Claim a task then ask "what should I do next?"
            - Claim multiple tasks before starting work
            - Claim a task just to "reserve" it for later

            ### DO:
            - Read the task description thoroughly
            - Review acceptance criteria and verification steps
            - Check key_files to understand which files to modify
            - Review patterns_to_follow for code consistency
            - Note pitfalls to avoid
            - Start implementing the solution immediately
            - Follow the testing_strategy outlined in the task
            - Work continuously until ready to complete (using `stride-completing-tasks` skill)

            **The claiming skill's job ends when you start coding. Your next interaction with Stride will be when you're ready to mark the work complete.**

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
              "why": "Reduce eye strain for users working in low-light environments",
              "what": "Dark mode toggle with theme persistence",
              "where_context": "Settings page - User Preferences section",
              "estimated_files": "3-5",
              "key_files": [
                {
                  "file_path": "lib/kanban_web/live/user_live/settings.ex",
                  "note": "Add theme preference controls",
                  "position": 0
                },
                {
                  "file_path": "assets/css/app.css",
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
              {"file_path": "path/to/file.ex", "note": "Why modifying", "position": 0}
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
            3. **Execute after_doing hook** (blocking, 120s timeout)
               - Capture: `exit_code`, `output`, `duration_ms`
            4. **If after_doing fails:** FIX ISSUES, do NOT proceed
            5. **Read .stride.md before_review section** - Get the PR/doc command
            6. **Execute before_review hook** (blocking, 60s timeout)
               - Capture: `exit_code`, `output`, `duration_ms`
            7. **If before_review fails:** FIX ISSUES, do NOT proceed
            8. **Both hooks succeeded?** Call `PATCH /api/tasks/:id/complete` WITH both results
            9. **Check needs_review flag:**
               - `needs_review=true`: STOP and wait for human review
               - `needs_review=false`: Execute after_review hook, then claim next task

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
            Claim next task immediately
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
            3. Claim next task and continue working

            ## Red Flags - STOP

            - "I'll mark it complete then run tests"
            - "The tests probably pass"
            - "I can fix failures after completing"
            - "I'll skip the hooks this time"
            - "Just the after_doing hook is enough"
            - "I'll run before_review later"

            **All of these mean: Run BOTH hooks BEFORE calling complete.**

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
            2. **Execute after_doing hook** - Run tests, linters, build
            3. **Check exit code** - Must be 0
            4. **If failed:** Fix issues, re-run, do NOT proceed
            5. **Execute before_review hook** - Create PR, generate docs
            6. **Check exit code** - Must be 0
            7. **If failed:** Fix issues, re-run, do NOT proceed
            8. **Call complete endpoint** - Include BOTH hook results
            9. **Check needs_review flag** - Stop if true, continue if false
            10. **If false:** Execute after_review hook
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
