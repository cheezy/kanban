defmodule KanbanWeb.ResourcesLive.HowTos.Developer do
  @moduledoc """
  Developer guides: hooks, API authentication, the claim/complete workflow and debugging hooks.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "setting-up-hooks",
        title: "Setting Up Hook Execution",
        description:
          "Configure client-side hooks for automated workflows when AI agents claim and complete tasks.",
        tags: ["developer", "hooks", "automation", "ai-agents"],
        content_type: "tutorial",
        reading_time: 8,
        thumbnail: "/images/resources/hooks-setup.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "Understanding Hooks",
            content:
              "**Important:** Hooks are designed exclusively for AI-Optimized boards working with AI agents. They do not execute for regular boards or human users.\n\nHooks are shell commands that execute on the agent's machine at specific points in the task lifecycle:\n\n- **before_doing**: Runs before the agent claims a task (e.g., `git pull`)\n- **after_doing**: Runs after the agent completes work (e.g., `mix test`)\n- **before_review**: Runs when the agent submits for review (e.g., `gh pr create`)\n- **after_review**: Runs after human approval (e.g., `git push`)",
            image: nil
          },
          %{
            title: "Create .stride.md",
            content:
              "Create a `.stride.md` file in your project root with hook definitions. This file is typically created when an AI agent calls the onboarding endpoint and it defines the automation steps that AI agents will execute:",
            image: "/images/resources/guides/hooks-step-2.png",
            image_width: 760,
            image_height: 828
          },
          %{
            title: "Hook Environment Variables",
            content:
              "When hooks execute, AI agents receive environment variables with task context:\n\n- `TASK_ID`, `TASK_IDENTIFIER`, `TASK_TITLE`\n- `TASK_STATUS`, `TASK_COMPLEXITY`, `TASK_PRIORITY`\n- `BOARD_NAME`, `COLUMN_NAME`, `AGENT_NAME`\n\nThese variables allow hooks to customize behavior based on the specific task and board context.",
            image: nil
          },
          %{
            title: "Hook Execution Requirements",
            content:
              "**All four hooks are blocking** - they must succeed for the agent to proceed:\n\n- **before_doing** must succeed before the agent can claim a task\n- **after_doing** must succeed before the agent can mark the task complete\n- **before_review** must succeed before the task enters the review queue\n- **after_review** must succeed before the task is marked as done\n\nIf any hook fails (exits with non-zero code), the agent must fix the issue and retry. Failed hooks prevent the workflow from advancing, ensuring quality gates are enforced.\n\n**Remember:** Hooks are for AI agent automation only. Regular board users won't trigger hook execution.",
            image: nil
          },
          %{
            title: "Learn More",
            content:
              "For comprehensive details on hook execution, including platform-specific examples (Unix/Linux, Windows, macOS), advanced patterns, debugging tips, and best practices, see the complete [Agent Hook Execution Guide](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md).\n\nThis guide covers:\n\n- Platform-specific hook implementations\n- Complete workflow examples\n- Error handling strategies\n- Security best practices\n- Debugging and troubleshooting",
            image: nil
          }
        ]
      },
      %{
        id: "api-authentication",
        title: "Configuring API Authentication",
        description:
          "Set up API tokens for secure access to the Stride API from your applications.",
        tags: ["developer", "api", "security"],
        content_type: "tutorial",
        reading_time: 5,
        thumbnail: "/images/resources/api-auth.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "Generate an API Token",
            content:
              "Navigate to your board settings and click **API Tokens**. Complete the fields with paying special attention to the Agent Capabilities. More information about Agent Capabilities can be found at [Agent Capabilities Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md).",
            image: "/images/resources/guides/api-auth-step-1.png",
            image_width: 636,
            image_height: 623
          },
          %{
            title: "Complete Token Generation",
            content:
              "Click **Generate Token** and **Copy** your token. You will not be able to see the token again so it is important to move directly to the next step.",
            image: "/images/resources/guides/api-auth-step-2.png",
            image_width: 636,
            image_height: 273
          },
          %{
            title: "Create .stride_auth.md.",
            content:
              "Create a `.stride_auth.md` file (add to `.gitignore`!). This file is typically created when an AI agent calls the onboarding endpoint. Paste the API token from the previous step into this file:",
            image: "/images/resources/guides/api-auth-step-3.png",
            image_width: 579,
            image_height: 211
          },
          %{
            title: "Using the Token",
            content:
              "The AI agent will automatically use this token every time it calls Stride. There is nothing you need to do here.",
            image: nil
          },
          %{
            title: "Security Best Practices",
            content:
              "- Never commit tokens to version control\n- Use environment variables in CI/CD\n- Rotate tokens periodically\n- Use separate tokens for different environments",
            image: nil
          }
        ]
      },
      %{
        id: "claim-complete-workflow",
        title: "Understanding Claim/Complete Workflow",
        description:
          "Master the task lifecycle with claiming, completing, and review workflows for AI agents.",
        tags: ["developer", "workflow", "api"],
        content_type: "guide",
        reading_time: 10,
        thumbnail: "/images/resources/claim-complete.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "The Task Lifecycle",
            content:
              "Tasks flow through these states:\n\n1. **Open** → Available for claiming\n2. **In Progress** → Claimed by an agent\n3. **Review** → Awaiting human approval (if needed)\n4. **Done** → Completed\n\nAgents automatically discover, claim, and complete tasks through the Stride API.",
            image: nil
          },
          %{
            title: "Finding Available Tasks",
            content:
              "The agent calls `GET /api/tasks/next` to find the next available task. Stride uses sophisticated filtering to determine which task is next:\n\n**1. Column Filter** - Only tasks in the **Ready** column\n\n**2. Task Type** - Only **work** and **defect** tasks (goals are containers, not claimable)\n\n**3. Status Filter** - Tasks that are:\n\n- `open` (never claimed), OR\n- `in_progress` with expired claims (60 minutes timeout)\n\n**4. Capability Matching** - Agent must have ALL required capabilities, OR task requires none\n\n**5. Dependency Check** - ALL dependencies must be completed (in Done column)\n\n**6. Key File Conflicts** - Task cannot modify files currently being worked on in Doing or Review columns\n\n**7. Priority Ordering** - Sorted by priority (critical → high → medium → low)\n\n**8. Position Ordering** - Within same priority, sorted by position (manual ordering)\n\nThe first task passing all criteria is returned.",
            image: nil
          },
          %{
            title: "Before Claiming: Execute before_doing Hook",
            content:
              "**CRITICAL:** Before claiming a task, the agent must execute the `before_doing` hook (blocking, 60s timeout). This hook typically:\n\n- Pulls latest code (`git pull`)\n- Sets up the workspace\n- Installs dependencies\n\nThe hook must succeed (exit code 0) to proceed. The agent captures the exit code, output, and duration.",
            image: nil
          },
          %{
            title: "Claiming a Task",
            content:
              "The agent calls `POST /api/tasks/claim` with:\n\n- Task identifier (e.g., \"W42\")\n- Agent name\n- **`before_doing_result`** containing the hook execution results\n\nThe API validates the hook succeeded and moves the task to the **In Progress** column. The agent can now work on the task.",
            image: nil
          },
          %{
            title: "Working on the Task",
            content:
              "The agent performs the actual implementation work:\n\n- Write code and implement features\n- Fix bugs and refactor\n- Write tests\n- Update documentation\n\nOnce the work is complete, the agent prepares to mark the task complete.",
            image: nil
          },
          %{
            title: "Before Completing: Execute Two Hooks",
            content:
              "**CRITICAL:** Before calling the complete endpoint, the agent must execute TWO hooks in order:\n\n**1. after_doing hook** (blocking, 120s timeout)\n\n- Run tests (`mix test`)\n- Lint code (`mix credo`)\n- Build project\n\n**2. before_review hook** (blocking, 60s timeout)\n\n- Create pull request\n- Generate documentation\n\nBoth hooks must succeed (exit code 0). If either fails, the agent must fix the issues before proceeding.",
            image: nil
          },
          %{
            title: "Completing a Task",
            content:
              "The agent calls `PATCH /api/tasks/:id/complete` with:\n\n- Agent name\n- Time spent (minutes)\n- Completion notes\n- **`after_doing_result`** from step 6\n- **`before_review_result`** from step 6\n\nThe API validates both hooks succeeded. The task moves to:\n- **Review** column if `needs_review=true`\n- **Done** column if `needs_review=false`",
            image: nil
          },
          %{
            title: "Review Flow (if needs_review=true)",
            content:
              "If the task requires review, the agent **STOPS and WAITS**:\n\n1. Task enters Review column\n2. Human reviewer examines the work\n3. Reviewer sets status: **approved**, **changes_requested**, or **rejected**\n\nThe agent proceeds to the next step only when notified of approval. If changes are requested, the agent returns to step 5 to make updates.",
            image: nil
          },
          %{
            title: "After Review: Execute after_review Hook",
            content:
              "**After approval** (or immediately if `needs_review=false`), the agent executes the `after_review` hook (blocking, 60s timeout):\n\n- Deploy to production\n- Merge pull request\n- Notify stakeholders\n\nThe hook must succeed (exit code 0). The agent then calls `PATCH /api/tasks/:id/mark_reviewed` with the hook results to finalize completion.",
            image: nil
          },
          %{
            title: "Dependencies Automatically Unblock",
            content:
              "When a task reaches the **Done** column, Stride automatically:\n\n- Marks the task as completed\n- Unblocks dependent tasks\n- Makes the next tasks available for claiming\n\nAgents can immediately claim the newly available tasks and continue the workflow.",
            image: nil
          }
        ]
      },
      %{
        id: "debugging-hooks",
        title: "Debugging Hook Failures",
        description:
          "Troubleshoot common hook execution issues and learn best practices for reliable automation.",
        tags: ["developer", "hooks", "troubleshooting"],
        content_type: "guide",
        reading_time: 6,
        thumbnail: "/images/resources/debug-hooks.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "Common Failure Causes",
            content:
              "Hooks fail for several reasons:\n\n- **Exit code non-zero**: Tests failing, lint errors\n- **Timeout exceeded**: Hook taking too long (60-120s limits)\n- **Missing dependencies**: Commands not found\n- **Permission errors**: File access issues",
            image: nil
          },
          %{
            title: "Reading Hook Output",
            content:
              "The API returns hook output in the response:\n\n```json\n{\n  \"exit_code\": 1,\n  \"output\": \"Error: 3 tests failed...\",\n  \"duration_ms\": 5432\n}\n```\n\nUse this output to diagnose the issue.",
            image: nil
          },
          %{
            title: "Testing Hooks Locally",
            content:
              "Test your hooks manually before relying on them:\n\n```bash\nexport TASK_IDENTIFIER=\"W1\"\nexport TASK_TITLE=\"Test Task\"\nbash -c 'source .stride.md && echo $TASK_IDENTIFIER'\n```",
            image: nil
          },
          %{
            title: "Best Practices",
            content:
              "- Keep hooks fast (under 60 seconds)\n- Use set -e to fail fast on errors\n- Log meaningful output for debugging\n- Handle edge cases (empty repos, missing files)\n- Test hooks in CI before production",
            image: nil
          }
        ]
      }
    ]
  end
end
