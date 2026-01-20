defmodule KanbanWeb.ResourcesLive.HowToData do
  @moduledoc """
  Embedded how-to guide data for the Resources section.
  All content is version-controlled and deployed with the app.
  """

  @type_icons %{
    "guide" => "hero-book-open",
    "tutorial" => "hero-academic-cap",
    "reference" => "hero-document-text",
    "video" => "hero-play-circle"
  }

  @how_tos [
    %{
      id: "creating-your-first-board",
      title: "Creating Your First Board",
      description:
        "Learn how to create and configure a new Stride board for your team or project.",
      tags: ["getting-started", "beginner", "boards"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/board-creation.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Access Your Boards Dashboard",
          content:
            "After logging in, you'll automatically land on your **My Boards** dashboard. If you're navigating from elsewhere in the app, you can always return here by clicking **My Boards** in the navigation bar.",
          image: "/images/resources/guides/board-creation-step-1.png",
          image_width: 1160,
          image_height: 74
        },
        %{
          title: "Click New Board",
          content:
            "Click the **New Board** button in the top right corner. You'll see two options: **New Empty Board** for a blank slate, or **New AI Optimized Board** which comes pre-configured with columns optimized for AI agent workflows.",
          image: "/images/resources/guides/board-creation-step-2.png",
          image_width: 300,
          image_height: 230
        },
        %{
          title: "Enter Board Details",
          content:
            "Give your board a descriptive name and optional description. The name should reflect the project or team that will use this board.",
          image: "/images/resources/guides/board-creation-step-3.png",
          image_width: 714,
          image_height: 405
        },
        %{
          title: "Start Using Your Board",
          content:
            "Your AI Optimized board is ready with pre-configured workflow columns (Backlog → Ready → Doing → Review → Done). To invite team members, click the **Edit Board** button and add collaborators in the board settings.",
          image: "/images/resources/guides/board-creation-step-4.png",
          image_width: 714,
          image_height: 317
        }
      ]
    },
    %{
      id: "understanding-columns",
      title: "Understanding Board Columns and Workflow",
      description:
        "Discover how columns help organize your tasks and create efficient workflows.",
      tags: ["getting-started", "beginner", "workflow"],
      content_type: "guide",
      reading_time: 4,
      thumbnail: "/images/resources/columns-workflow.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "What Are Columns?",
          content:
            "Columns represent stages in your workflow. Tasks move from left to right as they progress through different stages toward completion. Stride offers two types of boards with different column configurations.",
        },
        %{
          title: "AI-Optimized Boards: Fixed Columns",
          content:
            "**AI-optimized boards** come with five pre-configured columns designed for AI agent workflows. These columns **cannot be added, removed, or renamed**:\n\n- **Backlog**: Tasks that are not yet ready to be worked on\n- **Ready**: Tasks available for AI agents to claim\n- **Doing**: Tasks currently being worked on\n- **Review**: Tasks awaiting human review\n- **Done**: Completed tasks\n\nThis fixed structure ensures consistency for AI agents working across multiple boards.",
          image: "/images/resources/guides/understanding-columns-step-2.png",
          image_width: 714,
          image_height: 317
        },
        %{
          title: "Custom Boards: Flexible Columns",
          content:
            "**Non-AI optimized boards** give you complete flexibility to design your own workflow. You can:\n\n- Create any number of columns with custom names\n- Add new columns by clicking **Add Column**\n- Reorder columns by dragging them\n- Rename or delete existing columns\n- Design workflows like **Backlog → In Progress → Testing → Complete** or any pattern that fits your team's needs",
          image: "/images/resources/guides/understanding-columns-step-3.png",
          image_width: 730,
          image_height: 180
        },
        %{
          title: "Choosing the Right Board Type",
          content:
            "When creating a board, select:\n\n- **AI Optimized Board** if you'll be working with AI agents or want a standardized agent-friendly workflow\n- **Empty Board** if you need custom columns tailored to your team's specific process\n\nNote: You cannot convert between board types after creation, so choose carefully based on your workflow needs.",
        },
        %{
          title: "Column Settings & WIP Limits",
          content:
            "Both board types support **WIP (Work In Progress) limits** for each column. WIP limits prevent bottlenecks by restricting how many tasks can be in a column at once, keeping work flowing smoothly through your workflow.",
          images: [
            %{
              url: "/images/resources/guides/understanding-columns-step-5-1.png",
              alt: "AI-Optimized Board column settings with WIP limit",
              width: 602,
              height: 340
            },
            %{
              url: "/images/resources/guides/understanding-columns-step-5-2.png",
              alt: "Custom Board column settings with WIP limit",
              width: 234,
              height: 77
            }
          ]
        }
      ]
    },
    %{
      id: "adding-your-first-task",
      title: "Adding Your First Task",
      description: "A step-by-step guide to creating tasks with all the essential fields.",
      tags: ["getting-started", "beginner", "tasks"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/task-creation.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Open the Task Form",
          content:
            "Click the <span class=\"hero-plus-circle-solid h-5 w-5 text-green-600 inline-block\"></span> button at the bottom of any column, or use the keyboard shortcut **N** when focused on a column.",
          image: "/images/resources/guides/adding-task-step-1.png",
          image_width: 517,
          image_height: 263
        },
        %{
          title: "Enter Task Details",
          content:
            "Fill in the essential fields:\n\n- **Title**: A clear, action-oriented description\n- **Type**: Work, Defect, or Goal\n- **Priority**: Low, Medium, High, or Critical\n- **Description**: Detailed context and requirements",
          image: "/images/resources/guides/adding-task-step-2.png",
          image_width: 542,
          image_height: 586
        },
        %{
          title: "Add Acceptance Criteria",
          content:
            "Define what \"done\" looks like. Good acceptance criteria are specific, measurable, and testable. This helps both humans and AI agents understand exactly what's expected.",
          image: nil
        },
        %{
          title: "Save and Start Working",
          content:
            "Click **Create Task** to add it to the column. The task is now ready to be claimed and worked on.",
          image: "/images/resources/guides/adding-task-step-4.png",
          image_width: 263,
          image_height: 256
        }
      ]
    },
    %{
      id: "inviting-team-members",
      title: "Adding Team Members to Your Board",
      description:
        "Learn how to add collaborators to your board and set their access permissions.",
      tags: ["getting-started", "beginner", "collaboration"],
      content_type: "guide",
      reading_time: 2,
      thumbnail: "/images/resources/invite-members.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Access Board Settings",
          content:
            "From your board view, click the **Edit board** button in the top right corner to access board management options.\n\n**Important:** Users must already have a Stride account to be added to your board. Team members need to register at Stride before you can add them as collaborators.",
          image: "/images/resources/guides/inviting-members-step-1.png",
          image_width: 1387,
          image_height: 304
        },
        %{
          title: "Search for Users",
          content:
            "In the board settings form, locate the **Board Users** section. Use the search field to find registered Stride users by their email address or name. Select the user from the search results.",
          image: "/images/resources/guides/inviting-members-step-2.png",
          image_width: 603,
          image_height: 369
        },
        %{
          title: "Set Permission Level",
          content:
            "After selecting a user, choose their permission level:\n\n- **Can View**: Read-only access to view tasks and board\n- **Can Edit**: Can create, edit, and manage tasks\n- **Owner**: Full control including board settings and user management\n\nClick **Add User** to complete the process. The user will immediately have access to your board.",
          image: "/images/resources/guides/inviting-members-step-3.png",
          image_width: 603,
          image_height: 298
        }
      ]
    },
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
    },
    # Non-developer guides
    %{
      id: "writing-tasks-for-ai",
      title: "Writing Effective Tasks for AI Agents",
      description:
        "Learn how to write clear, actionable tasks that AI agents can understand and complete successfully.",
      tags: ["non-developer", "tasks", "ai-agents"],
      content_type: "guide",
      reading_time: 5,
      thumbnail: "/images/resources/writing-tasks.png",
      created_at: ~D[2026-01-17],
      steps: [
        %{
          title: "Start with a Clear Title",
          content:
            "Your task title should describe **what** needs to be done in action-oriented language. Start with a verb like \"Add\", \"Create\", \"Fix\", or \"Update\".\n\n**Good examples:**\n\n- \"Add user authentication to the login page\"\n- \"Fix the broken image upload feature\"\n- \"Create a dashboard for viewing statistics\"\n\n**Avoid vague titles like:**\n\n- \"Work on login\" (too vague)\n- \"Bug\" (doesn't describe the problem)",
          image: nil
        },
        %{
          title: "Write a Detailed Description",
          content:
            "The description should explain **why** this task matters and **what** the expected outcome is. Include:\n\n- The problem you're solving\n- Who benefits from this change\n- Any relevant context or background\n- Links to related resources or discussions\n\nThe more context you provide, the better the AI agent can understand your intent.",
          image: nil
        },
        %{
          title: "Define Clear Acceptance Criteria",
          content:
            "Acceptance criteria tell the AI agent exactly what \"done\" looks like. Use simple, testable statements:\n\n- \"Users can log in with email and password\"\n- \"Error messages display when login fails\"\n- \"Session persists after browser refresh\"\n\nThink of acceptance criteria as a checklist that can be verified.",
          image: nil
        },
        %{
          title: "Choose the Right Priority and Complexity",
          content:
            "Help the AI agent understand how to prioritize work:\n\n**Priority levels:**\n\n- **Critical**: Blocking issues, security problems\n- **High**: Important features, significant bugs\n- **Medium**: Normal feature work\n- **Low**: Nice-to-haves, minor improvements\n\n**Complexity:**\n\n- **Small**: Simple changes, under 2 hours\n- **Medium**: Moderate effort, 2-8 hours\n- **Large**: Significant work, 8+ hours",
          image: nil
        }
      ]
    },
    %{
      id: "monitoring-task-progress",
      title: "Monitoring Task Progress",
      description:
        "Track what AI agents are working on and understand task status throughout the workflow.",
      tags: ["non-developer", "workflow", "monitoring"],
      content_type: "guide",
      reading_time: 4,
      thumbnail: "/images/resources/monitoring-progress.png",
      created_at: ~D[2026-01-17],
      steps: [
        %{
          title: "Understanding Task Columns",
          content:
            "Tasks move through columns as they progress:\n\n- **Ready**: Available tasks waiting to be claimed\n- **Doing**: Tasks currently being worked on by an agent\n- **Review**: Completed work waiting for your approval\n- **Done**: Approved and finished tasks\n\nWatch tasks move across columns to track progress.",
          image: nil
        },
        %{
          title: "Checking Who's Working on What",
          content:
            "When a task is in the **Doing** column, you can see which agent claimed it and when. This helps you understand:\n\n- Which tasks are actively being worked on\n- How long tasks have been in progress\n- Whether any tasks seem stuck\n\nIf a task stays in Doing too long, the claim may expire and the task returns to Ready.",
          image: nil
        },
        %{
          title: "Viewing Task Details",
          content:
            "Click on any task card to see its full details:\n\n- Complete description and acceptance criteria\n- Current status and assigned agent\n- Time spent and completion notes\n- Any blocking dependencies\n\nThis gives you full visibility into task progress.",
          image: nil
        },
        %{
          title: "Using Filters to Focus",
          content:
            "Filter your board view to focus on what matters:\n\n- Filter by status to see only tasks in progress\n- Filter by priority to focus on critical items\n- Filter by assignee to see specific agent work\n\nFilters help you manage large boards effectively.",
          image: nil
        }
      ]
    },
    %{
      id: "reviewing-completed-work",
      title: "Reviewing Completed Work",
      description:
        "Learn how to effectively review work completed by AI agents and provide helpful feedback.",
      tags: ["non-developer", "workflow", "reviewing"],
      content_type: "guide",
      reading_time: 5,
      thumbnail: "/images/resources/reviewing-work.png",
      created_at: ~D[2026-01-17],
      steps: [
        %{
          title: "When to Review",
          content:
            "Tasks that have **Needs Review** enabled will move to the Review column after completion. You'll be notified when work is ready for your review.\n\nReview is your chance to:\n\n- Verify the work meets requirements\n- Catch any issues before they're finalized\n- Provide feedback for improvement",
          image: nil
        },
        %{
          title: "What to Check",
          content:
            "When reviewing completed work, verify:\n\n- **Acceptance criteria**: Are all requirements met?\n- **Quality**: Does the work meet your standards?\n- **Completion notes**: Did the agent explain what was done?\n- **Test results**: Did verification steps pass?\n\nTake time to thoroughly check the work.",
          image: nil
        },
        %{
          title: "Approving Work",
          content:
            "If the work meets your requirements, approve it:\n\n1. Click the **Approve** button on the task\n2. Optionally add review notes\n3. The task moves to Done\n\nApproved work triggers the after_review hook, which may deploy changes or notify stakeholders.",
          image: nil
        },
        %{
          title: "Requesting Changes",
          content:
            "If work needs improvement:\n\n1. Click **Request Changes**\n2. Provide clear, specific feedback\n3. Explain what needs to be different\n4. The task returns to the agent for revision\n\nGood feedback helps the agent improve. Be specific about what needs to change and why.",
          image: nil
        }
      ]
    },
    # Best practices guides
    %{
      id: "organizing-with-dependencies",
      title: "Organizing Tasks with Dependencies",
      description:
        "Use dependencies to ensure tasks are completed in the right order and manage complex projects effectively.",
      tags: ["best-practices", "tasks", "dependencies"],
      content_type: "guide",
      reading_time: 4,
      thumbnail: "/images/resources/dependencies.png",
      created_at: ~D[2026-01-17],
      steps: [
        %{
          title: "Understanding Dependencies",
          content:
            "Dependencies define the order tasks must be completed. If Task B depends on Task A, then Task A must be finished before Task B can start.\n\nThis prevents agents from:\n\n- Working on tasks before prerequisites are done\n- Creating merge conflicts from parallel changes\n- Building on incomplete foundations",
          image: nil
        },
        %{
          title: "When to Use Dependencies",
          content:
            "Add dependencies when:\n\n- One task builds on another's work\n- Tasks modify the same files\n- There's a logical sequence (design → implement → test)\n- Database migrations must happen before code changes\n\nDon't over-use dependencies—only add them when truly needed.",
          image: nil
        },
        %{
          title: "Creating Dependencies",
          content:
            "When creating or editing a task:\n\n1. Find the **Dependencies** field\n2. Select tasks that must complete first\n3. The dependent task will be blocked until prerequisites finish\n\nBlocked tasks show which dependencies are incomplete.",
          image: nil
        },
        %{
          title: "Dependency Best Practices",
          content:
            "Best practices:\n\n- **Keep chains short**: Long dependency chains slow down work\n- **Avoid cycles**: A can't depend on B if B depends on A\n- **Group related work**: Use Goals to organize related tasks\n- **Review regularly**: Remove dependencies when no longer needed",
          image: nil
        }
      ]
    },
    %{
      id: "using-complexity-priority",
      title: "Using Complexity and Priority Effectively",
      description:
        "Learn how to use complexity and priority settings to manage work and set expectations.",
      tags: ["best-practices", "tasks", "priority"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/complexity-priority.png",
      created_at: ~D[2026-01-17],
      steps: [
        %{
          title: "Understanding Complexity",
          content:
            "Complexity estimates how much effort a task requires:\n\n- **Small**: Quick fixes, simple changes (under 2 hours)\n- **Medium**: Standard feature work (2-8 hours)\n- **Large**: Significant effort, multiple components (8+ hours)\n\nComplexity helps agents pick appropriate tasks and helps you plan timelines.",
          image: nil
        },
        %{
          title: "Setting Priority Right",
          content:
            "Priority determines which tasks get attention first:\n\n- **Critical**: Drop everything—security issues, production bugs\n- **High**: Important work that should happen soon\n- **Medium**: Normal priority, standard workflow\n- **Low**: Nice-to-have, do when time allows\n\nAgents work on higher priority tasks first.",
          image: nil
        },
        %{
          title: "Balancing Complexity and Priority",
          content:
            "Consider both factors together:\n\n- **High priority + Small complexity**: Quick wins, do immediately\n- **High priority + Large complexity**: Important but needs planning\n- **Low priority + Small complexity**: Fill time between bigger tasks\n- **Low priority + Large complexity**: May never get done—reconsider if needed",
          image: nil
        },
        %{
          title: "Adjusting Over Time",
          content:
            "Revisit complexity and priority as work progresses:\n\n- Raise priority if something becomes urgent\n- Adjust complexity if estimates were wrong\n- Lower priority for tasks that are no longer relevant\n\nKeep your board reflecting current reality.",
          image: nil
        }
      ]
    }
  ]

  @all_tags [
    "getting-started",
    "beginner",
    "developer",
    "non-developer",
    "best-practices",
    "boards",
    "tasks",
    "workflow",
    "collaboration",
    "hooks",
    "api",
    "automation",
    "security",
    "troubleshooting",
    "ai-agents",
    "monitoring",
    "reviewing",
    "dependencies",
    "priority"
  ]

  @doc """
  Returns all how-to guides.
  """
  def all_how_tos, do: @how_tos

  @doc """
  Returns all available tags.
  """
  def all_tags, do: @all_tags

  @doc """
  Returns the type icon mapping.
  """
  def type_icons, do: @type_icons

  @doc """
  Finds a how-to by its ID.
  Returns `{:ok, how_to}` or `:error`.
  """
  def get_how_to(id) do
    case Enum.find(@how_tos, &(&1.id == id)) do
      nil -> :error
      how_to -> {:ok, how_to}
    end
  end

  @doc """
  Returns the type icon for a content type.
  """
  def type_icon(content_type) do
    Map.get(@type_icons, content_type, "hero-document")
  end

  @doc """
  Formats a tag for display (kebab-case to Title Case).
  """
  def format_tag(tag) do
    tag
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Returns previous and next how-tos within the same tags.
  """
  def get_navigation(current_how_to) do
    # Get how-tos that share at least one tag
    primary_tag = List.first(current_how_to.tags)

    related =
      @how_tos
      |> Enum.filter(&(primary_tag in &1.tags))
      |> Enum.with_index()

    current_index =
      Enum.find_index(related, fn {how_to, _} -> how_to.id == current_how_to.id end)

    prev_how_to =
      if current_index && current_index > 0 do
        {how_to, _} = Enum.at(related, current_index - 1)
        how_to
      end

    next_how_to =
      if current_index && current_index < length(related) - 1 do
        {how_to, _} = Enum.at(related, current_index + 1)
        how_to
      end

    {prev_how_to, next_how_to}
  end
end
