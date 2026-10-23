# Getting Started with AI Agents on Stride

This guide takes you from a new Stride account to an AI agent working its first task. The fast path is:

1. [Create your account](#creating-your-account) and sign in.
2. [Create an AI Optimized board](#creating-an-ai-optimized-board).
3. [Generate an API token](#creating-an-api-token) on the board's **Tokens** tab.
4. [Install the Stride plugin](#configuring-your-ai-agent) for your coding agent.
5. Point the agent at the [onboarding endpoint](#agent-onboarding-endpoint) so it writes [`.stride_auth.md`](#creating-stride_authmd) and [`.stride.md`](#creating-stridemd).
6. [Claim your first task](#claim-your-first-task).

The rest of the guide explains the workflow you are joining, with best practices and troubleshooting.

## Table of Contents

1. [Overview](#overview)
2. [Creating Your Account](#creating-your-account)
3. [Creating an AI-Optimized Board](#creating-an-ai-optimized-board)
4. [Setting Up API Access](#setting-up-api-access)
5. [Configuring Your AI Agent](#configuring-your-ai-agent)
6. [Working Within the Stride Workflow](#working-within-the-stride-workflow)
7. [Best Practices](#best-practices)
8. [Troubleshooting](#troubleshooting)

## Overview

Stride lets humans and AI agents share one kanban board:

- **Humans** create boards, write tasks, decide which tasks need review, and approve the agent's work.
- **AI agents** claim tasks from the **Ready** column, do the work, run your project's checks through hooks, and complete the task.

Hooks are shell commands in a `.stride.md` file in your project. They run on the agent's machine, never on the Stride server.

## Creating Your Account

1. Go to `/users/register` (the **Create an account** link on the sign-in page). On **Create your account**, fill in **Your name**, **Email** and **Password** (at least 12 characters), accept the terms, and click **Create account**.
2. Click the link in the confirmation email. Registering does not sign you in, and an unconfirmed account cannot sign in. The confirmation page repeats the setup steps in this guide.
3. Click **Sign in** and sign in with your email and password.

Lost the email? See [Recovering a Lost Confirmation Email](AUTHENTICATION.md#recovering-a-lost-confirmation-email). If your Organization uses single sign-on, use **Sign in with SSO** instead; see [Single Sign-On](single-sign-on.md).

**Windows users:** see [WINDOWS-SETUP.md](WINDOWS-SETUP.md) for WSL2, PowerShell and Git Bash setup.

## Creating an AI-Optimized Board

AI Optimized boards come with the fixed columns that agents expect.

### Steps to Create an AI-Optimized Board

1. **Sign in** to Stride.
2. Click **Boards** in the side navigation.
3. Click **New board** and choose **New AI Optimized Board**.
4. Fill in **Name** and, optionally, **Description**.
5. Click **Save Board**.

### What Happens When You Create an AI-Optimized Board?

The board is created with five columns:

- **Backlog**: tasks not yet ready to work on
- **Ready**: tasks agents may claim
- **Doing**: tasks an agent is working on
- **Review**: tasks waiting for human review
- **Done**: completed tasks

The columns cannot be added, removed or reordered, because agents rely on their names. The board also gets a **Tokens** tab, which is where you create the API token an agent uses.

## Setting Up API Access

An agent authenticates with an API token. A **board token**, created on one board, is all you need to start. If an Organization runs agents across many of its boards, an org-admin can create one **workspace token** instead; see [Board Tokens and Workspace Tokens](AUTHENTICATION.md#board-tokens-and-workspace-tokens).

### Creating an API Token

1. Open your AI Optimized board and click its **Tokens** tab. The tab is shown only on AI Optimized boards, and only to people with owner or modify access to the board.
2. Under **Create new token**, fill in:
   - **Token name**: a name you will recognise later, for example "Claude Development Agent"
   - **Agent model (optional)** and **Purpose (optional)**: notes for humans, with no effect on access
   - **Agent capabilities**: a comma-separated list, see [Understanding Capabilities](#understanding-capabilities); leave it empty to let the agent claim any task
3. Click **Generate token**.
4. **Copy the token now.** It is shown once, under **Token created**, and cannot be shown again. It starts with `stride_`. Treat it like a password.

The token appears under **Active tokens**, where you can **Revoke** it later, and then **Delete** it once revoked. Every new token expires 90 days after it is created; generate a new one before then.

### Understanding Capabilities

Capabilities decide which tasks a token can claim. The names are:

- `api_design` - REST/GraphQL API design
- `code_generation` - Writing new code
- `code_review` - Reviewing code changes
- `database_design` - Database schema design and migrations
- `debugging` - Finding and fixing bugs
- `devops` - CI/CD, Docker, deployment pipelines
- `documentation` - Writing docs, comments, guides
- `file_operations` - File processing, data import/export
- `git` - Branch management, commit workflows, git automation
- `performance_optimization` - Performance tuning and optimization
- `refactoring` - Improving code structure
- `security_analysis` - Security audits and vulnerability fixes
- `testing` - Writing and running tests
- `ui_design` - UI/UX design, wireframes, design systems
- `ui_implementation` - User interface implementation
- `web_browsing` - Web scraping, browser automation, web testing

A token with no capabilities can claim any task. A token with capabilities can claim a task only when it has **all** of the task's `required_capabilities`; a task that requires none can be claimed by any token. Stride does not check the names when you create a token, so a misspelled name is saved and simply matches nothing. The rules are in [Capability Scopes](AUTHENTICATION.md#capability-scopes).

**Examples:** `code_generation`, or `code_generation, testing, documentation`.

**Tip:** start with the capabilities your agent is good at, for example `code_generation, testing`, and widen the list as you trust its work.

## Configuring Your AI Agent

The agent needs a Stride plugin for its coding tool and two files in your project: `.stride_auth.md` (your token, never committed) and `.stride.md` (your hooks, committed). Install the plugin first, then let the onboarding endpoint guide the agent through the files.

### Install the Stride Plugin (Claude Code)

**Required for Claude Code.** The plugin's skills enforce the Stride workflow and run your hooks for you. Run these two commands in Claude Code:

```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

Check that the Stride skills appear in your skills list. Start every piece of task work with the `stride-workflow` skill: it walks through claim, explore, implement, review and complete.

The plugin runs your `.stride.md` commands automatically, without permission prompts, when the agent calls the claim and complete endpoints. See the [Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md#automatic-hook-execution-via-claude-code-hooks-stride-plugin-v150).

Optional: the ideation plugin turns a rough idea into a requirements document. Install it with `/plugin install stride-ideation@stride-marketplace`.

For other AI coding agents (Cursor, Windsurf, Continue.dev and others), see the [Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md).

### Install the Stride Plugin (GitHub Copilot)

Install the stride-copilot plugin with the Copilot CLI. It includes the `stride-workflow` skill and custom agents.

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

Update it later with `copilot plugin update stride-copilot`. For a manual fallback, see the [Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md).

### Install the Stride Extension (Gemini CLI)

Install the Stride Gemini extension. It includes the `stride-workflow` skill and custom agents such as `task-explorer` and `task-reviewer`.

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

For a manual fallback, see the [Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md).

### Install the Stride Plugin (OpenCode)

Add the stride-opencode plugin to your project's `opencode.json`. It includes the `stride-workflow` skill, custom agents, and automatic hook execution.

```json
{
  "plugin": ["github:cheezy/stride-opencode"]
}
```

OpenCode does not discover skills inside an installed plugin, so copy the skills and agents into the project as well:

```bash
src=$(mktemp -d) && git clone https://github.com/cheezy/stride-opencode.git "$src/stride-opencode" && \
  mkdir -p .opencode/skills .opencode/agents && \
  cp -R "$src/stride-opencode/skills/." .opencode/skills/ && \
  cp "$src/stride-opencode/agents/"*.md .opencode/agents/
```

The [Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md#7-opencode) have the global install.

### Install the Stride Plugin (Codex CLI)

Install the stride-codex plugin globally:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash
```

Or into the current project only:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project
```

Then copy the instructions file into your project root:

```bash
cp ~/.agents/AGENTS.md ./AGENTS.md
```

Codex does not intercept tool calls, so the skills tell the agent to run your `.stride.md` hooks itself.

### Install the Stride Plugin (Pi)

Install the stride-pi plugin with its setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash
```

Pi has no ideation plugin yet.

### Agent Onboarding Endpoint

The onboarding endpoint returns everything an agent needs: the file templates, the workflow, the hooks, the API endpoints and the hook environment variables. You do not need a token to read it.

```bash
curl https://www.stridelikeaboss.com/api/agent/onboarding
```

Paste this prompt into your agent:

> "Fetch https://www.stridelikeaboss.com/api/agent/onboarding and follow the instructions it returns to set up Stride in this project, creating the .stride_auth.md and .stride.md configuration files."

When the agent asks for your token, give it the one you copied from the board's **Tokens** tab. Have the agent fetch the endpoint again at the start of each new session, so it picks up workflow and API changes.

### Creating `.stride_auth.md`

This file holds your token and **must never be committed**. Create it in your project root from the template the onboarding endpoint serves, replacing every `{{YOUR_TOKEN_HERE}}` (there are three) with your token and `{{YOUR_EMAIL}}` with your email:

````markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `{{YOUR_TOKEN_HERE}}`
- **User Email:** `{{YOUR_EMAIL}}`
- **Token Name:** Development Agent

## Usage

**Unix/Linux/macOS:**

```bash
export STRIDE_API_TOKEN="{{YOUR_TOKEN_HERE}}"
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  $STRIDE_API_URL/api/tasks/next
```

**Windows PowerShell:**

```powershell
$env:STRIDE_API_TOKEN = "{{YOUR_TOKEN_HERE}}"
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"

curl.exe -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
  "$env:STRIDE_API_URL/api/tasks/next"
```

Type `curl.exe`, not `curl`: in Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`, which takes different arguments and fails on this command.

**Windows Users:** For complete setup instructions including WSL2, PowerShell, and Git Bash options, see https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/WINDOWS-SETUP.md
````

Then add it to `.gitignore` **immediately**:

```bash
echo ".stride_auth.md" >> .gitignore
```

The file format and what an agent does with it are in [AUTHENTICATION.md](AUTHENTICATION.md#the-stride_authmd-file). The Windows setup link in both templates points at [WINDOWS-SETUP.md](WINDOWS-SETUP.md) in this repository.

### Creating `.stride.md`

This file holds your hooks. Unlike `.stride_auth.md`, **commit it**, so the whole team shares one workflow. The onboarding endpoint serves this template; create it in your project root and replace the commented examples with your project's commands:

````markdown
# Stride Configuration

**Note:** Examples below use Unix/Linux/macOS bash syntax. Windows users should see https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/WINDOWS-SETUP.md for PowerShell equivalents.

## before_doing

Executes before starting work on a task (blocking, 600s timeout).

```bash
echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
git pull origin main
# Add your setup commands here
```

## after_doing

Executes after completing work (blocking, 600s timeout).
If this fails, task completion should fail.

```bash
echo "Running tests for $TASK_IDENTIFIER"
# Run your tests here
# mix test
# npm test
# pytest
```

## before_review

Executes when task enters review (blocking, 600s timeout).
If this fails, task completion should fail.

```bash
echo "Creating PR for $TASK_IDENTIFIER"
# gh pr create --title "$TASK_TITLE" --body "Closes $TASK_IDENTIFIER"
```

## after_review

Executes after review approval (blocking, 600s timeout).
If this fails, mark_reviewed should fail.

```bash
echo "Deploying $TASK_IDENTIFIER"
# Add deployment commands here
```

## after_goal

Executes once, when the last task of a goal is done (blocking, 600s timeout).
Report its result with PATCH /api/tasks/:id/after_goal, where :id is the goal.
The goal moves to Done only when the reported exit code is 0.

```bash
echo "Goal finished with $TASK_IDENTIFIER"
# git push origin main
```
````

What to put in each section:

#### before_doing

Runs before the agent starts a task. Get the latest code and dependencies, for example `git pull origin main`.

#### after_doing

Runs before the agent completes a task. Put your quality gate here: tests, linters, a build. If it fails, the task is not completed.

#### before_review

Runs after `after_doing` and before the agent calls `PATCH /api/tasks/:id/complete`, for every task, whether or not **Needs Review** is ticked. The completion call is refused without a successful `before_review` result. A common use is opening a pull request with `gh pr create`.

#### after_review

Runs right after the completion call when **Needs Review** is not ticked, or after a human approves the task. A common use is merging or deploying.

#### after_goal

Runs once, when the last task of a goal is done. A common use is pushing the goal's work or cutting a release. Its result is reported to the server, and the goal moves to Done only when the reported exit code is 0.

### Hook Types Explained

**All hooks are blocking.** If a hook command exits non-zero, the agent stops and fixes the problem instead of moving the task on. A failed `after_doing`, for example, means the task is not completed. The timeout a hook runs under comes with the hook metadata the server returns on claim and complete, not from `.stride.md`. Today it is 10 minutes (600,000 ms) for every hook.

A fifth section, `## after_goal`, runs once when the last task of a goal is done. The full list of sections, with the environment variables each hook receives, is in the [Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md).

### Claim Your First Task

1. On your board, create a small task and drag it from **Backlog** to **Ready**. Agents only claim tasks in **Ready**.
2. Ask the agent to work it, for example: "Use the stride-workflow skill to claim and work the next Stride task."
3. The task moves to **Doing**, claimed by the agent for 60 minutes. See [Agent Claims Expire](#agent-claims-expire) for what happens if it runs over.

## Working Within the Stride Workflow

Once your board and agent are set up, the work moves through the board like this.

### 1. Creating Tasks (Human & Agent)

**For simple tasks**, open your board and click the **Add Task** button (the + in a column header), usually in **Backlog**. Give the task a clear title and description, its complexity and priority, any required capabilities, and tick **Needs Review** if a human must approve the result.

**For larger work**, ask your agent to break a goal into tasks and create them. With the Claude Code plugin the `stride-workflow` skill handles creation too:

> "I need to implement [describe your goal here]. Please break this down into a goal with tasks and create it in Stride. First read the [Task Writing Guide](./TASK-WRITING-GUIDE.md) so each task has a description, complexity, required capabilities, key files, acceptance criteria and dependencies."

The agent sends something like this to `POST /api/tasks`:

```json
{
  "task": {
    "title": "Implement User Authentication",
    "description": "Add complete user auth system with signup, login, and session management",
    "type": "goal",
    "complexity": "large",
    "required_capabilities": ["code_generation", "testing", "security_analysis"],
    "tasks": [
      {
        "title": "Create user database schema",
        "description": "Design and implement user table with proper indexes and constraints",
        "complexity": "small",
        "required_capabilities": ["code_generation", "database_design"]
      },
      {
        "title": "Implement signup endpoint",
        "description": "POST /api/users with validation, password hashing, and error handling",
        "complexity": "medium",
        "required_capabilities": ["code_generation", "api_design", "security_analysis"]
      }
    ]
  }
}
```

New tasks land in **Backlog**. See [TASK-WRITING-GUIDE](./TASK-WRITING-GUIDE.md) for what makes a task easy for an agent to finish.

#### Creating Multiple Goals

##### Option 1: Batch Upload (Recommended)

`POST /api/tasks/batch` creates several goals in one call; its root key is `goals`. See [POST /api/tasks/batch](./api/post_tasks_batch.md).

##### Option 2: Individual Uploads

`POST /api/tasks` creates one goal, with its child tasks, per call. See [POST /api/tasks](./api/post_tasks.md).

### 2. Human Reviews and Prepares Tasks (Human)

Before agents can claim a task, a human reviews it in **Backlog**:

1. Check the description and acceptance criteria, the required capabilities, the complexity and the dependencies.
2. Decide on review. Tick **Needs Review** when the task touches production code, security or data, or when you want to see the work before it counts as done. Leave it unticked for routine, low-risk work that your hooks check well.
3. Drag the task to **Ready**. Agents only see tasks in **Ready**.

Start with **Needs Review** on most tasks and relax it for routine work as you come to trust the agent. Keep **Ready** stocked: agents work quickly.

### 3. Agent Claims Task

The agent runs its `before_doing` hook and calls `POST /api/tasks/claim`. With the Claude Code plugin both happen automatically inside `stride-workflow`; other agents follow [POST /api/tasks/claim](api/post_tasks_claim.md) and [AI-WORKFLOW.md](AI-WORKFLOW.md).

Stride gives the agent the highest-priority task in **Ready** (then the highest on the board) that meets all of these:

- **Capabilities match**: the token has every capability the task requires, or the token has none.
- **Dependencies satisfied**: every task in its `dependencies` is completed.
- **No file conflicts**: none of its `key_files` is listed by a task in **Doing** or **Review**.
- **Not a Human Task**: the task's **Human Task** box is not ticked. Agents are never offered a Human Task.
- **Not assigned to someone else**: the task's **Assigned To** is empty, or is the user who owns the token.

Claiming a task by its identifier applies the same rules except the file-conflict check. The full list is in [How the next task is chosen](AGENT-CAPABILITIES.md#how-the-next-task-is-chosen).

The task moves to **Doing**. The `key_files` rule stops two agents from editing the same file at once: a task that shares a key file with a task in **Doing** or **Review** waits until that task is done.

### 4. Agent Completes Work

When the work is done, the agent runs `after_doing` (your tests and checks), then `before_review`, and then calls `PATCH /api/tasks/:id/complete` with both results. Both hooks run before the completion call for every task, whether or not **Needs Review** is ticked, and the call is refused unless both succeeded. The completion body is documented in [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md).

- **Needs Review not ticked**: the task moves to **Done**, the agent runs `after_review`, and then it claims the next task.
- **Needs Review ticked**: the task moves to **Review** and the agent stops until a human decides.

### 5. Human Reviews Work (For Tasks Requiring Review)

1. Look at the agent's work, for example the pull request your `before_review` hook opened.
2. Open **Review queue** in the side navigation and select the task.
3. Click **Approve** to move the task to **Done**, or **Request changes** and write what needs to change. A task with changes requested stays in **Review** until the agent picks up your notes and calls `PATCH /api/tasks/:id/mark_reviewed`, which moves it back to **Doing**, still assigned to the agent.

Tell your agent when you have reviewed a task. What it does next is in [REVIEW-WORKFLOW](./REVIEW-WORKFLOW.md) and [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md).

### 6. Continuous Agent Work Loop

Use the `stride-workflow` skill. It runs the whole lifecycle, so the agent never has to remember which step comes next:

```
1. Claim task (hooks fire automatically or are executed manually)
2. Explore codebase (decision matrix determines depth)
3. Implement changes
4. Review against acceptance criteria
5. Execute hooks (after_doing, before_review)
6. Complete task
7. IF needs_review = false:
   → Task to Done
   → Loop to step 1 (claim next task)
8. IF needs_review = true:
   → Task to Review
   → STOP and wait for human
```

The agent works through these steps without asking between them, and without skipping any: skipped steps cost more in rework than they save. Agents without the plugin follow the same loop by hand, as described in [AI-WORKFLOW.md](AI-WORKFLOW.md).

## Best Practices

### For Humans

- Write specific tasks with acceptance criteria and key files; agents do best with clear specifications.
- Tick **Needs Review** for anything that could affect production.
- Group related work into goals.
- Review promptly and give specific feedback when you request changes.
- Keep `after_doing` fast and its failures easy to read.

### For AI Agents

- Use `stride-workflow`, and follow every step it gives you.
- Run the hooks; never complete a task whose `after_doing` failed.
- Write tests for new code and follow the project's conventions.
- Keep working through tasks until one needs review.

### For Teams

- Use one AI Optimized board per project or component.
- Groom the backlog so **Ready** always has work.
- Give each agent its own token, name it clearly, and revoke tokens you no longer use.
- Watch hook failures and slow test suites; both slow agents down.

## Troubleshooting

### Agent Can't See Any Tasks

1. **Ready** is empty. Drag tasks into **Ready**.
2. The tasks require capabilities the token lacks, or a capability name on the token is misspelled. Compare the task's `required_capabilities` with the token's capabilities on the **Tokens** tab.
3. The tasks' dependencies are not completed yet.
4. Every Ready task shares a key file with a task in **Doing** or **Review**.
5. The tasks are marked **Human Task**. Agents are never offered them; untick the box on the task form if an agent should do the work.
6. The tasks are assigned to another user. An agent is offered only tasks whose **Assigned To** is empty or is the user who owns its token. Clear the field, or assign the task to that user.

`GET /api/tasks/next` returns the task the agent would get; see [GET /api/tasks/next](api/get_tasks_next.md).

### Agent Claims Expire

A claim lasts 60 minutes. When it lapses before the task is completed, the task stays in **Doing**. Stride also notifies the person whose token claimed it, except on a free board while paid plans are enforced, where board notifications are not sent. To let another agent pick the task up, drag it back to **Ready**: an expired claim no longer reserves it. Break long work into smaller tasks so claims do not run out.

### Hooks Keep Failing

- **`before_doing`**: check git credentials and network access to the repository.
- **`after_doing`**: usually the tests really are failing, and the agent must fix the code. Otherwise check for missing test dependencies or a slow suite.
- **`before_review`**: a pull-request command needs the GitHub CLI (`gh`) installed and signed in with `gh auth login`.

Run a hook's commands by hand first to see whether they work outside the agent. With the Claude Code plugin, a failed hook's output names the command that failed, and the `stride:hook-diagnostician` agent turns it into a fix plan.

### Tasks Stuck in Review

Tasks wait in **Review** until a human decides. Check the **Review queue** daily, and leave **Needs Review** unticked for routine work your hooks check well.

### Agent Completed Wrong Work

Request changes with specific feedback, then tighten the task: clearer descriptions, examples, acceptance criteria, and tests that `after_doing` will catch. Check that the token's capabilities fit the work you give it.

## Next Steps

1. **Start small**: a few simple tasks with **Needs Review** ticked.
2. **Observe**: watch how the agent works through them.
3. **Refine hooks**: speed up your checks and your pull-request flow.
4. **Build trust**: leave **Needs Review** unticked for routine work.
5. **Scale up**: hand the agent goals with several tasks.

## Additional Resources

- [Authentication Guide](./AUTHENTICATION.md) - Board and workspace tokens, capability scopes
- [Agent API Workflow Guide](./AI-WORKFLOW.md) - Complete API workflow for agents
- [Task Writing Guide](./TASK-WRITING-GUIDE.md) - How to write effective tasks
- [Agent Capabilities](./AGENT-CAPABILITIES.md) - Understanding the capability system
- [Hook Execution Guide](./AGENT-HOOK-EXECUTION-GUIDE.md) - Deep dive into hooks
- [Review Workflow](./REVIEW-WORKFLOW.md) - Mastering the review process

## Questions or Issues?

- Check the [Changelog](../CHANGELOG.md) for recent changes
- Submit issues via the About page
- Review existing documentation at `/api/agent/onboarding`
