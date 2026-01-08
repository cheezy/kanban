# Getting Started with AI Agents on Stride

This guide will walk you through setting up Stride to work with AI agents, from creating your first AI-optimized board to managing the complete workflow of AI-human collaboration.

## Table of Contents

1. [Overview](#overview)
2. [Creating an AI-Optimized Board](#creating-an-ai-optimized-board)
3. [Setting Up API Access](#setting-up-api-access)
4. [Configuring Your AI Agent](#configuring-your-ai-agent)
5. [Working Within the Stride Workflow](#working-within-the-stride-workflow)
6. [Best Practices](#best-practices)
7. [Troubleshooting](#troubleshooting)

## Overview

Stride is designed to enable seamless collaboration between humans and AI agents. AI agents can autonomously claim and complete tasks while humans maintain control through review workflows and client-side execution hooks.

**The Collaboration Model:**
- **Humans**: Create boards, define tasks, review AI work, approve changes
- **AI Agents**: Claim tasks, execute work, run tests, create pull requests
- **Together**: Complete projects faster with AI handling repetitive work while humans focus on architecture and quality

## Creating an AI-Optimized Board

AI-optimized boards come pre-configured with the standard workflow columns that AI agents expect.

### Steps to Create an AI-Optimized Board

1. **Log in to Stride** at your Stride instance

2. **Navigate to Boards** by clicking "Boards" in the navigation

3. **Click the "New Board" button** and select **"New AI Optimized Board"** from the dropdown options

4. **Fill in the board details:**
   - **Name**: Give your board a descriptive name (e.g., "My Project - AI Development")
   - **Description**: Optional description of what this board is for

5. **Click "Create Board"**

### What Happens When You Create an AI-Optimized Board?

An AI-optimized board is automatically created with five standard columns:

- **Backlog**: Tasks not yet ready to work on
- **Ready**: Tasks ready for agents to claim
- **Doing**: Tasks currently being worked on
- **Review**: Tasks awaiting human review
- **Done**: Completed tasks

**Important Characteristics:**
- ✅ Columns cannot be added, removed, or reordered
- ✅ Column names are standardized for AI agent compatibility
- ✅ API token management is available
- ✅ Workflow hooks are fully supported

**Windows Users:** See [WINDOWS-SETUP.md](WINDOWS-SETUP.md) for Windows-specific installation instructions including WSL2, PowerShell, and Git Bash setup options.

## Setting Up API Access

AI agents need an API token to authenticate with your Stride instance.

### Creating an API Token

1. **Open your AI-optimized board**

2. **Click "API Tokens"** in the board header

3. **Configure the token:**
   - **Name**: Descriptive name for this token (e.g., "Claude Development Agent")
   - **Agent Model**: Optional - helps track which AI model is being used
   - **Capabilities**: Select what this agent can do (see [AGENT-CAPABILITIES](./AGENT-CAPABILITIES.md))

4. **Click "Create Token"**

5. **CRITICAL: Copy the token immediately!**
   - The full token is only shown **once** for security reasons
   - You'll need this token for the `.stride_auth.md` file
   - It starts with `stride_` followed by a long random string
   - Store it securely - treat it like a password

### Understanding Capabilities

Capabilities determine which tasks an agent can see and claim. Stride will only assign capabilities that match what your agent can actually do:

**Standard Capabilities:**
- `code_generation` - Writing new code
- `code_review` - Reviewing code changes
- `testing` - Writing and running tests
- `debugging` - Finding and fixing bugs
- `documentation` - Writing docs
- `refactoring` - Improving code structure
- `database` - Database migrations and queries
- `frontend` - UI/UX development
- `backend` - Server-side development
- `devops` - Deployment and infrastructure
- `security` - Security reviews and fixes
- `performance` - Performance optimization

**Pro Tip**: Start with a focused set of capabilities (e.g., just `code_generation` and `testing`) and expand as you gain confidence in your agent's work.

## Configuring Your AI Agent

AI agents need two configuration files in their working directory to operate with Stride.

### Agent Onboarding Endpoint

Before configuring files, have your AI agent call the onboarding endpoint to understand the full system:

```bash
curl https://www.stridelikeaboss.com/api/agent/onboarding
```

This endpoint returns everything the agent needs to know:
- File templates for both configuration files
- Complete workflow documentation
- Available hooks and their purpose
- All API endpoints
- Environment variables available in hooks

**If you're using Claude Code or another AI coding assistant**, just tell it:
> "Please read the Stride onboarding documentation at https://www.stridelikeaboss.com/api/agent/onboarding"

### Creating `.stride_auth.md`

This file contains your API credentials and **must never be committed to version control**.

**1. Create the file in your project root:**

Create a file named `.stride_auth.md` with the following content:

```markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_abc123def456...` (your actual token)
- **User Email:** `your-email@example.com`
- **Token Name:** Development Agent
- **Capabilities:** code_generation, testing

## Usage

Replace `{{YOUR_TOKEN_HERE}}` with your actual token, then set environment variables:

**Unix/Linux/macOS:**

```bash
export STRIDE_API_TOKEN="stride_abc123def456..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  $STRIDE_API_URL/api/tasks/next
```

**Windows PowerShell:**

```powershell
$env:STRIDE_API_TOKEN = "stride_abc123def456..."
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
  $env:STRIDE_API_URL/api/tasks/next
```

**Windows Command Prompt:**

```cmd
set STRIDE_API_TOKEN=stride_abc123def456...
set STRIDE_API_URL=https://www.stridelikeaboss.com

curl -H "Authorization: Bearer %STRIDE_API_TOKEN%" %STRIDE_API_URL%/api/tasks/next
```

**2. Add it to `.gitignore` IMMEDIATELY:**

```bash
echo ".stride_auth.md" >> .gitignore
```

**CRITICAL**: This file contains secrets. Never commit it to Git!

### Creating `.stride.md`

This file defines the hooks that execute at key points in the workflow. Unlike `.stride_auth.md`, this file **should be committed** to version control so the whole team shares the same workflow.

**Create the file in your project root:**

Create a file named `.stride.md` with the following content. Each section defines a hook with its bash commands:

#### before_doing

Executes before starting work on a task (blocking, 60s timeout).

```bash
echo "Starting task $TASK_IDENTIFIER: $TASK_TITLE"
git pull origin main
# Ensure we have latest code before starting
```

#### after_doing

Executes after completing work (blocking, 120s timeout). If this fails, task completion should fail.

```bash
echo "Running tests for $TASK_IDENTIFIER"
mix test
# Or: npm test, pytest, cargo test, etc.
echo "All tests passed for $TASK_IDENTIFIER"
```

#### before_review

Executes before completing task (blocking, 60s timeout).

```bash
echo "Creating PR for $TASK_IDENTIFIER"
gh pr create --title "$TASK_TITLE" --body "Resolves $TASK_IDENTIFIER

This task was completed by an AI agent and is ready for human review."
```

#### after_review

Executes after review approval (blocking, 60s timeout).

```bash
echo "Task $TASK_IDENTIFIER approved and completed"
# Optional: Trigger deployment, update docs, etc.
```

**Customize the hooks for your project:**
- Replace `mix test` with your project's test command
- Add linting: `mix credo`, `npm run lint`, `cargo clippy`
- Add build steps: `mix compile`, `npm run build`
- Add deployment commands in `after_review`

### Hook Types Explained

**Blocking Hooks** (`before_doing`, `after_doing`):
- ❌ If these fail, the task operation fails
- ⏱️ Must complete within timeout
- 🎯 Use for: Tests, required checks, critical setup

**Non-Blocking Hooks** (`before_review`, `after_review`):
- ✅ Task operation succeeds even if these fail
- 📝 Failures are logged but don't block progress
- 🎯 Use for: PR creation, notifications, documentation

## Working Within the Stride Workflow

Once your board and agent are configured, here's how the collaboration works:

### 1. Creating Tasks (Human & Agent)

**For Simple Tasks:**
1. Open your AI-optimized board
2. Click "Add task" in the appropriate column (usually **Backlog** or **Ready**)
3. Fill in the task details:
   - **Title**: Clear, actionable description
   - **Description**: Detailed requirements, acceptance criteria
   - **Complexity**: Estimate (helps with planning)
   - **Priority**: How urgent is this?
   - **Required Capabilities**: What skills are needed? (e.g., `code_generation`)
   - **Needs Review**: ✅ Check this for AI work that needs human approval

**For Larger Tasks or Goals:**

For complex features that need to be broken down into multiple tasks, you can work with your AI agent to decompose the goal and upload it to Stride. This collaborative approach ensures that large projects are properly structured.

**Working with Your AI Agent:**

Give your AI agent this prompt to break down and upload a goal:

> "I need to implement [describe your goal here]. Please break this down into a goal with tasks and upload it to Stride.
>
> **Important**: First read the [Task Writing Guide](./TASK-WRITING-GUIDE.md) to understand how to create complete, well-structured tasks. Each task should include all relevant fields such as:
>
> - Title and description
> - Complexity and estimated hours
> - Required capabilities
> - Key files to modify
> - Test scenarios and acceptance criteria
> - Dependencies (if any)
> - Any other fields from the Task Writing Guide that apply
>
> Create a goal with multiple complete child tasks, then upload to Stride using the API at the base URL and token from .stride_auth.md. The endpoint is POST /api/tasks and you'll need to create a JSON structure with type: 'goal' and a tasks array.
>
> **Important**: The API only supports uploading ONE goal per request. If you need to create multiple goals, you must make separate API calls for each goal."

**✨ Claude Code Skills Available:**
- Use `stride-creating-tasks` for individual tasks and defects
- Use `stride-completing-tasks` before marking tasks complete
- Use `stride-creating-goals` for goals with nested tasks (coming soon)

These skills are automatically provided via the onboarding endpoint and enforce best practices:
- `stride-creating-tasks`: Prevents 3+ hour exploration failures from minimal task specifications
- `stride-completing-tasks`: Ensures proper hook execution order and prevents quality gate bypasses

**Example: If you ask your agent to implement user authentication, it would:**

1. Analyze the requirement and break it into logical tasks
2. Create a JSON structure like this:

```json
{
  "task": {
    "title": "Implement User Authentication",
    "description": "Add complete user auth system with signup, login, and session management",
    "type": "goal",
    "complexity": "high",
    "required_capabilities": ["code_generation", "testing", "security"],
    "tasks": [
      {
        "title": "Create user database schema",
        "description": "Design and implement user table with proper indexes and constraints",
        "complexity": "low",
        "required_capabilities": ["code_generation", "database"]
      },
      {
        "title": "Implement signup endpoint",
        "description": "POST /api/users with validation, password hashing, and error handling",
        "complexity": "medium",
        "required_capabilities": ["code_generation", "backend", "security"]
      },
      {
        "title": "Add login endpoint",
        "description": "POST /api/login with JWT token generation and secure session handling",
        "complexity": "medium",
        "required_capabilities": ["code_generation", "backend", "security"]
      }
    ]
  }
}
```

3. Upload it to Stride using curl or API client
4. Confirm the goal and tasks appear in your board

#### Creating Multiple Goals

When you need to upload several related goals (such as planning a sprint or project phase), you have two options:

##### Option 1: Batch Upload (Recommended)

- Use `POST /api/tasks/batch` to create multiple goals in a single API call
- More efficient than making separate requests
- Ideal for project planning and sprint setup
- See [POST /api/tasks/batch](./api/post_tasks_batch.md) for complete documentation

##### Option 2: Individual Uploads

- Use `POST /api/tasks` for each goal separately
- Useful when goals are created individually or over time
- Each API call creates ONE goal with its child tasks

**Benefits of This Approach:**
- Your AI agent helps decompose complex work into actionable tasks
- Tasks are automatically linked as parent-child relationships
- The agent can then claim and work through tasks sequentially
- You maintain visibility of overall progress through the goal structure

See [TASK-WRITING-GUIDE](./TASK-WRITING-GUIDE.md) for more details on creating effective tasks.

### 2. Human Reviews and Prepares Tasks (Human)

Once tasks are created (either manually or by an AI agent), humans should review them before making them available for agents to claim.

**Review Process:**

1. **Review tasks in the Backlog column**
   - Check that task descriptions are clear and complete
   - Read the acceptance criteria and make sure you agree with it
   - Verify required capabilities are appropriate
   - Ensure complexity estimates are reasonable
   - Confirm dependencies are set correctly

2. **Decide on review requirements**
   - **Check "Needs Review"** if:
     - Task affects production code or critical functionality
     - Task involves security, authentication, or data handling
     - You want to review the AI's work before it's considered done
     - Task is complex or has potential for significant impact
   - **Leave "Needs Review" unchecked** if:
     - Task is routine or low-risk (e.g., documentation updates, simple bug fixes)
     - You trust the agent to handle it autonomously
     - Tests and hooks provide sufficient quality control

3. **Move tasks to the Ready column**
   - Drag tasks from **Backlog** to **Ready** when they're ready for agents to claim
   - Agents can only see and claim tasks in the **Ready** column
   - Prioritize tasks by position (agents claim highest priority tasks first)

**Best Practices:**

- Keep the Ready column populated so agents always have work available
- Start with `needs_review=true` for most tasks until you build trust with your agent
- Gradually shift to `needs_review=false` for routine tasks as confidence grows
- Review and prioritize the Ready column frequently as the Agent will complete the task quickly

### 3. Agent Claims Task

**From the agent's perspective:**

```bash
# CRITICAL: Execute before_doing hook FIRST and capture result
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'git pull origin main' 2>&1)
EXIT_CODE=$?
DURATION=$(($(date +%s%3N) - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "before_doing hook failed - cannot claim task"
  exit 1
fi

# Agent calls the claim endpoint WITH hook result (required)
curl -X POST https://your-stride-instance.com/api/tasks/claim \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"Claude Sonnet 4.5\",
    \"before_doing_result\": {
      \"exit_code\": $EXIT_CODE,
      \"output\": \"$OUTPUT\",
      \"duration_ms\": $DURATION
    }
  }"
```

**What happens:**
1. ⚡ **Agent executes `before_doing` hook FIRST** (pulls latest code, etc.) and captures result
2. ✅ Stride validates hook was executed successfully (exit_code 0)
3. ✅ Stride selects the highest priority task that matches:
   - Agent's capabilities
   - All dependencies are completed
   - No file conflicts with tasks currently in Doing or Review
4. 📝 Task moves to **Doing** column
5. 💻 Agent begins work

**Important Selection Criteria:**

Agents can only claim tasks that meet ALL of these requirements:
- **Capabilities match**: Task's `required_capabilities` must be a subset of the agent's capabilities
- **Dependencies satisfied**: All tasks listed in the task's `dependencies` field must be completed
- **No file conflicts**: If the task has `key_files` specified, none of those files can overlap with files in tasks currently in Doing or Review columns

**Key Files and Conflict Prevention:**

Tasks can specify `key_files` - a list of file paths that will be modified. This prevents merge conflicts by ensuring only one task modifies a given file at a time:

- If a task specifies `key_files: ["lib/auth.ex", "lib/user.ex"]`
- And another task in Doing or Review also lists `"lib/auth.ex"` in its `key_files`
- The second task will NOT be claimable until the first task is completed

This automatic conflict prevention ensures agents don't create competing changes to the same files.

### 4. Agent Completes Work

**From the agent's perspective:**

```bash
# CRITICAL: Execute after_doing hook FIRST and capture result
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 120 bash -c 'mix test' 2>&1)
EXIT_CODE=$?
DURATION=$(($(date +%s%3N) - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
  echo "after_doing hook failed - tests did not pass, cannot complete task"
  exit 1
fi

# Agent completes the task WITH hook result (required)
curl -X PATCH https://your-stride-instance.com/api/tasks/123/complete \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_name\": \"Claude Sonnet 4.5\",
    \"time_spent_minutes\": 45,
    \"completion_notes\": \"All tests passing\",
    \"after_doing_result\": {
      \"exit_code\": $EXIT_CODE,
      \"output\": \"$OUTPUT\",
      \"duration_ms\": $DURATION
    }
  }"
```

**What happens:**
1. ⚡ **Agent executes `after_doing` hook FIRST** (runs tests - **must pass**) and captures result
2. ✅ Stride validates hook was executed successfully (exit_code 0)
3. 🔧 Agent receives remaining hook metadata: `before_review`, and conditionally `after_review`
4. ⚡ Agent executes `before_review` hook (creates PR)
5. 📋 **If `needs_review=true`**: Task moves to **Review** column → STOP and wait for human
6. 📋 **If `needs_review=false`**: Agent executes `after_review` hook, task moves to **Done** → Agent claims next task

### 5. Human Reviews Work (For Tasks Requiring Review)

**As a human reviewer:**

1. **View the PR** created by the `before_review` hook

2. **Review the code changes:**
   - Check logic and correctness
   - Verify tests are adequate
   - Ensure it meets requirements
   - Look for security issues

3. **In Stride, open the task in Review column**

4. **Make your decision:**

   **Option A: Approve**
   - Click "Approve" in the task
   - Task status changes to "approved"
   - Inform your AI agent that the review is complete

   **Option B: Request Changes**
   - Click "Request Changes"
   - Add detailed feedback in the comment
   - Task moves back to **Ready**
   - Inform your AI agent that changes are needed
   - Agent can claim it again and address feedback

5. **Notify the agent that review is complete**

Once you've approved or requested changes in Stride, tell your AI agent:

> "The review for task [task identifier] is complete. Please finalize it."

**From the agent's perspective:**

```bash
# Agent calls the mark_reviewed endpoint
curl -X PATCH https://your-stride-instance.com/api/tasks/123/mark_reviewed \
  -H "Authorization: Bearer $STRIDE_API_TOKEN"
```

**What happens:**
- **If approved**:
  - ✅ Agent receives `after_review` hook metadata
  - ⚡ Agent executes `after_review` hook (merge PR, deploy, etc.)
  - 📋 Task moves to **Done**
  - 🔄 Agent claims next task from Ready
- **If changes requested**:
  - 📋 Task is already back in **Ready** column
  - 🔄 Agent can claim it again to address feedback

### 6. Continuous Agent Work Loop

**The ideal agent workflow:**

```
1. Execute before_doing hook (capture exit_code, output, duration_ms)
2. Claim task from Ready with before_doing_result
3. Do the work
4. Execute after_doing hook (tests must pass - capture exit_code, output, duration_ms)
5. Complete task with after_doing_result
6. Execute before_review hook (create PR)
7. IF needs_review = false:
   → Execute after_review hook
   → Task to Done
   → GOTO step 1 (claim next task)
8. IF needs_review = true:
   → Task to Review
   → STOP and wait for human
```

**Key Point**: Agents should work continuously, claiming and completing tasks until they hit a task that requires review. This maximizes productivity.

See [REVIEW-WORKFLOW](./REVIEW-WORKFLOW.md) for more details.

## Best Practices

### For Humans

**Task Writing:**
- ✅ Be specific in descriptions - AI agents need clarity
- ✅ Include acceptance criteria
- ✅ Set appropriate complexity levels
- ✅ Use `needs_review=true` for anything that could impact production
- ✅ Group related work into Goals with tasks

**Review Process:**
- ✅ Review promptly - don't let agents sit idle
- ✅ Give detailed feedback when requesting changes
- ✅ Trust the agent for routine work, focus on architecture and edge cases
- ✅ Check test coverage, not just functionality

**Workflow Hooks:**
- ✅ Keep `after_doing` fast (under 2 minutes)
- ✅ Make test failures clear and actionable
- ✅ Use PR templates to guide agent's commit messages

### For AI Agents

**Task Selection:**
- ✅ Only claim tasks matching your capabilities
- ✅ Check dependencies before claiming
- ✅ Respect complexity estimates in planning

**Work Quality:**
- ✅ Write tests for all new code
- ✅ Follow project conventions and style guides
- ✅ Commit frequently with clear messages
- ✅ Document non-obvious decisions

**Hook Execution:**
- ✅ Execute hooks BEFORE calling API endpoints (mandatory)
- ✅ Include hook results in API requests (exit_code, output, duration_ms)
- ✅ Handle hook failures gracefully
- ✅ Read hook output for error messages
- ✅ Don't call claim endpoint if `before_doing` fails
- ✅ Don't call complete endpoint if `after_doing` fails

**Continuous Work:**
- ✅ Keep claiming tasks until you hit `needs_review=true`
- ✅ Don't wait between tasks
- ✅ Maximize throughput while maintaining quality

### For Teams

**Board Organization:**
- ✅ Use one AI-optimized board per project/component
- ✅ Regular backlog grooming to keep Ready column full
- ✅ Set up notifications for Review column
- ✅ Use board description to document project-specific conventions

**Agent Management:**
- ✅ Rotate API tokens regularly
- ✅ Review agent activity logs
- ✅ Adjust capabilities based on agent performance
- ✅ Revoke tokens for inactive agents

**Workflow Optimization:**
- ✅ Monitor hook success rates
- ✅ Optimize slow test suites
- ✅ Automate merge after approval (if confident)
- ✅ Set up metrics to track agent productivity

## Troubleshooting

### Agent Can't See Any Tasks

**Possible causes:**
1. ❌ No tasks in Ready column → Add tasks
2. ❌ Tasks require capabilities agent doesn't have → Check `required_capabilities` on tasks
3. ❌ Agent token doesn't have right capabilities → Check API token configuration
4. ❌ Tasks have unmet dependencies → Ensure dependency tasks are completed

**Solution**: Call `/api/tasks/next` to see what's available and why

### Agent Claims Expire

**Symptom**: Task goes back to Ready after 60 minutes

**Cause**: Automatic claim expiration prevents tasks from being stuck

**Solution**:
- Agent should complete tasks within 60 minutes
- For long-running tasks, break them into smaller tasks
- Agent can re-claim if needed

### Hooks Keep Failing

**Common issues:**

**`before_doing` fails:**
- Check git credentials for pulling latest
- Ensure agent has file system access
- Verify network access to repositories

**`after_doing` fails:**
- **Most common**: Tests are actually failing → Agent needs to fix code
- Missing test dependencies → Update setup
- Test timeout → Increase hook timeout or optimize tests

**`before_review` fails:**
- PR creation requires GitHub CLI (`gh`) → Install it
- GitHub auth issues → Configure `gh auth login`
- Branch naming conflicts → Use unique branch names

**General debugging:**
- Check hook output in agent logs
- Test hooks manually before using with agents
- Simplify hooks initially, add complexity gradually

### Tasks Stuck in Review

**Causes:**
- Humans not reviewing promptly
- Notifications not working
- Unclear what needs review

**Solutions:**
- Set up Slack/email notifications for Review column
- Daily review standup
- PR template with checklist
- Empower agent to mark routine tasks as `needs_review=false`

### Agent Completed Wrong Work

**Prevention:**
- Write clearer task descriptions
- Include examples in task description
- Use `needs_review=true` for critical tasks
- Improve test coverage so `after_doing` catches issues

**Recovery:**
- Request changes with specific feedback
- Update task description for clarity
- Consider if agent has wrong capabilities assigned

## Next Steps

Now that you're set up:

1. **Start small**: Create a few simple tasks with `needs_review=true`
2. **Observe**: Watch how your agent works through tasks
3. **Refine hooks**: Optimize your test suite and PR process
4. **Build trust**: Gradually use `needs_review=false` for routine work
5. **Scale up**: Add more complex tasks and goals

## Additional Resources

- [Agent API Workflow Guide](./AI-WORKFLOW.md) - Complete API workflow for agents
- [Task Writing Guide](./TASK-WRITING-GUIDE.md) - How to write effective tasks
- [Agent Capabilities](./AGENT-CAPABILITIES.md) - Understanding the capability system
- [Hook Execution Guide](./AGENT-HOOK-EXECUTION-GUIDE.md) - Deep dive into hooks
- [Review Workflow](./REVIEW-WORKFLOW.md) - Mastering the review process

## Questions or Issues?

- Check the [Changelog](../CHANGELOG.md) for recent changes
- Submit issues via the About page
- Review existing documentation at `/api/agent/onboarding`

---

**Remember**: The goal of Stride is to amplify human capability through AI collaboration. Humans focus on architecture, design decisions, and quality oversight while AI agents handle the repetitive implementation work. Together, you can achieve more than either could alone.
