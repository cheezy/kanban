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
        reading_time: 9,
        thumbnail: "/images/resources/hooks-setup.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "Understanding Hooks",
            content:
              "Hooks are shell commands, kept in a `.stride.md` file in your project, that the agent runs on its own machine at fixed points in a task's life. Stride's server never runs them: it tells the agent which hook to run, with the task's details, and checks the result the agent reports.\n\nThere are five hooks:\n\n- `before_doing`: before the agent claims a task, for example `git pull`\n- `after_doing`: after the work, before the agent calls complete, for example `mix test`\n- `before_review`: straight after `after_doing`, before complete, for every task, for example `gh pr create`\n- `after_review`: after a person approves the task, or straight after complete when the task needs no review, for example a merge\n- `after_goal`: once, when the last task of a goal is done, for example `git push`\n\nAgents work on **AI Optimized** boards, because that's where API tokens are made.",
            image: nil
          },
          %{
            title: "Create .stride.md",
            content:
              "Create `.stride.md` in your project root. It starts with `# Stride Configuration` and has one section per hook, from `## before_doing` to `## after_goal`, each holding a fenced bash block. The agent runs a section's commands in order, one at a time, and stops at the first one that fails. A section with no commands does nothing.\n\nCommit `.stride.md` so everyone working on the project shares the same hooks. An agent that calls the onboarding endpoint, `GET /api/agent/onboarding`, gets a template to start from.",
            image: "/images/resources/guides/hooks-step-2.png",
            image_width: 701,
            image_height: 845
          },
          %{
            title: "Hook Environment Variables",
            content:
              "Every hook gets these environment variables with the task's details:\n\n- `TASK_ID`, `TASK_IDENTIFIER`, `TASK_TITLE`, `TASK_DESCRIPTION`\n- `TASK_STATUS`, `TASK_COMPLEXITY`, `TASK_PRIORITY`, `TASK_NEEDS_REVIEW`\n- `BOARD_ID`, `BOARD_NAME`, `COLUMN_ID`, `COLUMN_NAME`\n- `AGENT_NAME`, `HOOK_NAME`\n\nThe values are strings, and `TASK_NEEDS_REVIEW` is `true` or `false`. Quote them in commands, as in `\"$TASK_TITLE\"`, because titles contain spaces.",
            image: nil
          },
          %{
            title: "When Each Hook Runs",
            content:
              "Each hook runs before the API call that reports its result:\n\n- `before_doing` goes to `POST /api/tasks/claim` as `before_doing_result`\n- `after_doing` and then `before_review` go to `PATCH /api/tasks/:id/complete` as `after_doing_result` and `before_review_result`\n- `after_review` goes to `PATCH /api/tasks/:id/mark_reviewed` as `after_review_result`\n- `after_goal` goes to `PATCH /api/tasks/:id/after_goal`, where `:id` is the goal\n\nThe responses describe the hooks too. The claim response's `hook` is the `before_doing` hook the agent has just run. The complete response's `hooks` list holds `after_doing` and `before_review`, which have also run, plus `after_review` when `needs_review` is false. When a task finishes the last open task of its goal, `after_goal` is added to the response that finished it: complete, or the `mark_reviewed` call that approves it.\n\nThe Stride plugin for Claude Code runs the sections for you around the claim, complete and mark_reviewed calls. Other agents read each section and run its commands themselves.",
            image: nil
          },
          %{
            title: "Hook Execution Requirements",
            content:
              "All five hooks are sent as blocking, with a timeout of 600 seconds (10 minutes) each.\n\nThe result the agent reports is a map with `exit_code`, `output` and `duration_ms`, and `exit_code` must be `0`. A missing or failing result makes the call fail with HTTP 422, and the task stays where it was. The agent must fix the problem, run the hook again and retry.\n\nTwo results no call can refuse:\n\n- `after_review` on a task that needs no review: the task is already **Done** when the hook runs, and nothing reports the result\n- `after_goal`: a failed report keeps the goal out of **Done** until a passing report arrives or a five-minute grace window ends, and then Stride moves the goal to Done itself",
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
        reading_time: 6,
        thumbnail: "/images/resources/api-auth.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "Generate an API Token",
            content:
              "A board token works on one board. On an **AI Optimized** board, click the **Tokens** tab; only the owner and members with edit access see it. The **API tokens** window opens over the board.\n\nUnder **Create new token**, fill in:\n\n- **Token name**: a name you'll recognise later, such as the machine the agent runs on\n- **Agent model (optional)** and **Purpose (optional)**\n- **Agent capabilities**: a comma-separated list of the skills this agent has. Leave it empty to let the agent take every task\n\nSee the [Agent Capabilities Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md) for the capabilities and how tasks use them.",
            image: "/images/resources/guides/api-auth-step-1.png",
            image_width: 612,
            image_height: 444
          },
          %{
            title: "Complete Token Generation",
            content:
              "Click **Generate token**. The **Token created** panel shows the token once: click **Copy** and go straight to the next step. Stride keeps only a fingerprint of the token, so it can't show it to you again.\n\nThe new token appears under **Active tokens**, marked **Never used** until the agent first calls Stride with it.",
            image: "/images/resources/guides/api-auth-step-2.png",
            image_width: 612,
            image_height: 114
          },
          %{
            title: "Create .stride_auth.md",
            content:
              "Create `.stride_auth.md` in your project root and add it to `.gitignore`. An agent that calls the onboarding endpoint gets a template. Fill in the `API URL`, `API Token` (paste the token here), `User Email` and `Token Name` lines.\n\nThe agent sends the token in an `Authorization: Bearer` header on every request.",
            image: "/images/resources/guides/api-auth-step-3.png",
            image_width: 561,
            image_height: 201
          },
          %{
            title: "Using the Token",
            content:
              "The agent reads `.stride_auth.md` and sends the token every time it calls Stride. There's nothing more you need to do.\n\nA board token only works on its own board. A request with a revoked or expired token, or a token whose owner's account is disabled, gets HTTP 401.",
            image: nil
          },
          %{
            title: "Workspace Tokens",
            content:
              "An organization admin can make one token for several boards. Open **Workspace settings** from the workspace switcher, choose **Tokens**, and use **Create a workspace token**: fill in **Token name** and **Agent capabilities (comma-separated, optional)**, then click **Create token**. **Your new workspace token** is shown once, with **Copy**.\n\nA workspace token reaches every AI Optimized board in the workspace that the admin can edit. Each request names its board with the `X-Stride-Board` header, and `GET /api/boards` lists the boards it can use. The token stops working when it's revoked, when it expires, or when the admin leaves the workspace.",
            image: nil
          },
          %{
            title: "Security Best Practices",
            content:
              "- Never commit `.stride_auth.md` or paste a token into a task, a comment or a chat\n- Give each agent and each machine its own clearly named token\n- Use environment variables in CI/CD\n- Tokens expire 90 days after they are created: make a new one, update `.stride_auth.md`, then **Revoke** the old one\n\nRevoking takes effect at once. **Delete** removes a revoked token from the list.",
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
        reading_time: 12,
        thumbnail: "/images/resources/claim-complete.png",
        created_at: ~D[2026-01-16],
        steps: [
          %{
            title: "The Task Lifecycle",
            content:
              "Tasks move through the columns of an AI Optimized board:\n\n1. **Backlog** → planned work, not offered to agents (status `open`)\n2. **Ready** → waiting for an agent to claim it (status `open`)\n3. **Doing** → claimed by an agent (status `in_progress`)\n4. **Review** → waiting for a person to decide (status still `in_progress`)\n5. **Done** → finished (status `completed`)\n\nA task with an unfinished dependency has the status `blocked` until its dependencies are done.\n\nAgents automatically discover, claim, and complete tasks through the Stride API.",
            image: nil
          },
          %{
            title: "Finding Available Tasks",
            content:
              "The agent calls `GET /api/tasks/next` to find the next task. Stride only offers a task that is:\n\n- In the **Ready** column\n- A `work` or `defect` task: goals hold tasks but can't be claimed\n- Not marked **Human Task**\n- Status `open`, or `in_progress` with a claim that has run out\n- Not archived, and either unassigned or assigned to the token's owner\n- Free of unfinished dependencies\n- Within the token's capabilities: a token with no capabilities sees every task, otherwise the task must need none or only ones the token has\n- Not touching key files that a task in **Doing** or **Review** is working on\n\nOf those, it returns the highest priority (`critical`, then `high`, `medium` and `low`) and, among equal priorities, the one nearest the top of the column.",
            image: nil
          },
          %{
            title: "Before Claiming: Run the before_doing Hook",
            content:
              "Before claiming, the agent runs the `## before_doing` section of `.stride.md`. It usually pulls the latest code and installs dependencies.\n\nThe agent records the hook's `exit_code`, `output` and `duration_ms`. The `exit_code` must be `0` for the claim to go through.",
            image: nil
          },
          %{
            title: "Claiming a Task",
            content:
              "The agent calls `POST /api/tasks/claim` with:\n\n- `before_doing_result`, the hook result (required)\n- `identifier`, such as `W42`, to claim a particular task. Leave it out to take the next one\n- `agent_name`\n\nThe claim moves it to **Doing**, sets the status to `in_progress` and assigns the task to the token's owner. The response carries the task and the `before_doing` hook's details. The token's owner needs edit access to the board.\n\nA claim lasts 60 minutes. When it runs out, Stride doesn't unclaim the task: it stays in **Doing**, and the owner gets a notification.",
            image: nil
          },
          %{
            title: "Working on the Task",
            content:
              "The agent does the work: code, tests and documentation.\n\nIf it can't finish, it gives the task back with `POST /api/tasks/:id/unclaim` and an optional `reason`. The task returns to **Ready** with the status `open` and no assignee, ready for another agent.",
            image: nil
          },
          %{
            title: "Before Completing: Run Two Hooks",
            content:
              "Before calling complete, the agent runs two hooks in order:\n\n1. `after_doing`, for example the tests and the linter\n2. `before_review`, for example opening a pull request\n\nBoth must exit with `0`. If either fails, the agent fixes the problem and runs it again before completing.",
            image: nil
          },
          %{
            title: "Completing a Task",
            content:
              "The agent calls `PATCH /api/tasks/:id/complete`. The request needs `after_doing_result`, `before_review_result`, `completion_summary`, `actual_complexity` (`small`, `medium` or `large`), `actual_files_changed` and `time_spent_minutes`. Where strict completion validation is on, as it is in production by default, it also needs `explorer_result` and `reviewer_result`. `completion_notes` is optional. Only the task's assignee can complete it.\n\nWhat happens next depends on `needs_review`:\n\n- `true`: the task moves to **Review**\n- `false`: the task moves to **Done** with the status `completed`, and the response's `hooks` list includes `after_review`",
            image: nil
          },
          %{
            title: "Review Flow (if needs_review=true)",
            content:
              "The agent stops and waits. Stride doesn't message it, so it checks the task with `GET /api/tasks/:id`.\n\nA person decides in the **Review queue**:\n\n- **Approve** moves the task straight to **Done**. No hooks are sent, and a later `mark_reviewed` call is refused\n- **Request changes** leaves the task in Review with `review_status` set to `changes_requested` and the reviewer's notes\n\nA person can also set **Review Status** to **Approved**, **Changes Requested** or **Rejected** in the task form. That leaves the task in Review for the agent to act on.\n\nWhen `review_status` is `changes_requested` or `rejected`, the agent calls `mark_reviewed` with a passing `after_review_result` without running the section. The Stride plugin for Claude Code runs the `after_review` section after every `mark_reviewed` call, whatever the decision, so make merge and deploy commands check the review decision first. The task goes back to **Doing**, still assigned, and the agent returns to the work. While the status is empty or `pending`, `mark_reviewed` is refused: keep waiting.",
            image: nil
          },
          %{
            title: "After Review: Run the after_review Hook",
            content:
              "What the agent does depends on how the task got here:\n\n- Still in Review with `review_status` `approved`: run `after_review`, then call `PATCH /api/tasks/:id/mark_reviewed` with the result. The task moves to **Done** with the status `completed`\n- Already moved to Done by **Approve**: don't call `mark_reviewed`. Run the section yourself if your project relies on it\n- `needs_review` false: there's no `mark_reviewed` call. Run `after_review` from the complete response's `hooks`; its result isn't reported",
            image: nil
          },
          %{
            title: "Dependencies Automatically Unblock",
            content:
              "When a task reaches **Done**, every `blocked` task whose dependencies are now all `completed` goes back to `open`, so an agent can claim it. A task waiting in Review unblocks nothing.\n\nIf the task was the last open task of a goal, `after_goal` arrives in the `hooks` list. The agent runs it and reports the result to `PATCH /api/tasks/:id/after_goal` with the goal's id. A passing result moves the goal to **Done**. A failing one keeps it out of Done until a passing report arrives or a five-minute grace window ends.",
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
              "Hooks fail for a handful of reasons:\n\n- A non-zero exit code: tests failing or lint errors\n- Exit code 127, \"command not found\": the command isn't installed or isn't on the agent's `PATH`\n- In `before_doing`: missing git credentials, no network, or uncommitted changes in the way\n- In `before_review`: the GitHub CLI isn't installed or signed in (`gh auth login`)\n- Taking longer than the 600-second (10-minute) timeout: make the commands faster rather than dropping checks\n- Empty variables: quote them, and export them when you test by hand",
            image: nil
          },
          %{
            title: "Reading the Error",
            content:
              "The agent measures each hook's `exit_code`, `output` and `duration_ms` and sends them to Stride, for example as `after_doing_result`. If a result is missing, incomplete or failing, the call fails with HTTP 422, the task stays where it was, and the response says why:\n\n```json\n{\n  \"error\": \"after_doing is a blocking hook and failed with exit code 1. Fix the issues and try again.\",\n  \"hook\": \"after_doing\",\n  \"required_format\": {\n    \"after_doing_result\": {\n      \"exit_code\": 0,\n      \"output\": \"Hook execution output\",\n      \"duration_ms\": 1234\n    }\n  }\n}\n```\n\nThe Stride plugin for Claude Code reports a failing hook with the command that failed and its output, and the `stride:hook-diagnostician` agent turns that output into a plan for fixing it.",
            image: nil
          },
          %{
            title: "Testing Hooks Locally",
            content:
              "`.stride.md` is a Markdown file, not a shell script, so you can't source it. To test a hook, export the variables it uses and run each line of its section one at a time in the project root, checking the exit code after each:\n\n```bash\nexport TASK_IDENTIFIER=\"W1\"\nexport TASK_TITLE=\"Try the hooks\"\nexport HOOK_NAME=\"after_doing\"\nmix test\necho \"exit code: $?\"\n```\n\nNever print `.stride_auth.md` while you debug: it holds your token.",
            image: nil
          },
          %{
            title: "When a Hook Can't Be Fixed Now",
            content:
              "If a hook keeps failing for a reason outside the task, the agent can give the task back with `POST /api/tasks/:id/unclaim` and a `reason`. The task returns to **Ready** for later.\n\nA failing `after_goal` keeps the goal out of **Done** until a passing report arrives or the five-minute grace window ends.",
            image: nil
          },
          %{
            title: "Best Practices",
            content:
              "- Keep hooks fast, well under the 600-second limit\n- Put one command on each line: the agent stops at the first one that fails\n- Print meaningful output, so a failure explains itself\n- Leave a section empty when it has nothing to do\n- Check the review decision before merging or deploying in `after_review`\n- Test hooks by hand before relying on them",
            image: nil
          }
        ]
      }
    ]
  end
end
