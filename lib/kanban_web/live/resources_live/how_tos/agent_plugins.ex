defmodule KanbanWeb.ResourcesLive.HowTos.AgentPlugins do
  @moduledoc """
  Guides for the Stride plugins that drive a coding agent: installing the
  plugin in each runtime (Claude Code, GitHub Copilot CLI, Gemini CLI,
  Codex CLI, OpenCode and Pi), the lite plugins, keeping a plugin up to
  date, turning an idea into tasks with the Stride Ideation plugin,
  reviewing changes with the Stride Security Review plugin, and running a
  task's manual tests with the Stride Exploratory Testing plugin.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after `HowTos.OrgAdmin` and
  before `HowTos.Developer`. The installing guide leads with the `developer`
  tag, so the developer chain opens here: installing the plugin → setting up
  hooks → API authentication → the claim/complete workflow → debugging
  hooks → connecting an MCP client. The Ideation guide leads with
  `ai-agents` instead, so it stays out of that chain and its count: in the
  `ai-agents` chain it sits between installing the plugin and setting up
  hooks, and no guide that leads with `ai-agents` changes neighbours. The
  Security Review guide leads with `reviewing`, so it opens that chain,
  before Reviewing Completed Work and Reading a Task's Details. It carries
  neither `ai-agents` (which would move the Ideation guide's Next link) nor
  `security` nor `developer`, so no other guide changes neighbours. The
  Exploratory Testing guide leads with `automation`, which no other guide
  leads with, so in that chain it sits between the Security Review guide and
  Setting Up Hook Execution and moves no guide's neighbours.

  The guides follow the README of each plugin repository: cheezy/stride,
  stride-copilot, stride-gemini, stride-codex, stride-opencode, stride-pi,
  stride-lite, stride-copilot-lite and stride-opencode-lite; for
  Ideation stride-ideation (with its `commands/ideate.md` and
  `commands/stridify.md`), stride-copilot-ideation, stride-gemini-ideation,
  stride-codex-ideation and stride-opencode-ideation; and for Security
  Review stride-security-review (with its `commands/security-review.md` and
  `agents/security-reviewer.md`), stride-copilot-security-review,
  stride-codex-security-review, stride-gemini-security-review and
  stride-opencode-security-review, plus the Stride workflow's
  `skills/stride-workflow/optional-security-review.md` for the automatic
  review; and for Exploratory Testing stride-exploratory-testing (with its
  `commands/*.md` and `agents/explorer.md`),
  stride-copilot-exploratory-testing, stride-codex-exploratory-testing,
  stride-gemini-exploratory-testing and stride-opencode-exploratory-testing,
  plus the workflow's `skills/stride-workflow/optional-exploratory-testing.md`
  and `skills/stride-completing-tasks/manual-testing-findings.md`. Re-read
  them when a plugin's install or update command changes; no test reads
  them, because they are not checked out in CI.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "installing-the-stride-plugin",
        title: "Installing the Stride Plugin",
        description:
          "Install the Stride plugin for Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI, OpenCode or Pi, choose a lite plugin when you only want task files, and keep the plugin up to date.",
        tags: ["developer", "ai-agents", "automation"],
        content_type: "guide",
        reading_time: 8,
        created_at: ~D[2026-11-10],
        steps: [
          %{
            title: "What the Plugin Does",
            content:
              "The Stride plugin runs the Stride workflow inside your coding agent, so neither you nor the agent calls the API by hand. Ask the agent to work on your next task and the plugin claims it, runs your hooks at each point in the task's life, and completes the task with the results. In Claude Code it also hands work to subagents, such as `task-explorer`, which reads the code before work starts, and `task-reviewer`, which checks the change before the task is completed. [Understanding Claim/Complete Workflow](/resources/claim-complete-workflow) explains the loop underneath.\n\nThere is a plugin for each agent runtime: Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI, OpenCode and Pi. Install the one for the runtime you use. Each plugin's README on GitHub is the full reference, and the commands in this guide are copied from it.",
            image: nil
          },
          %{
            title: "Before You Start",
            content:
              "Every full plugin reads two files from the root of your project:\n\n- `.stride_auth.md` holds your Stride API URL and token. Add it to `.gitignore` and never commit it. [Configuring API Authentication](/resources/api-authentication) shows how to create a token and the file.\n- `.stride.md` holds the commands your hooks run. [Setting Up Hook Execution](/resources/setting-up-hooks) shows what goes in it.\n\nThe lite plugins, further down, need neither file.",
            image: nil
          },
          %{
            title: "Claude Code",
            content:
              "In Claude Code, add the Stride marketplace, then install the plugin from it:\n\n```text\n/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride@stride-marketplace\n```\n\nThe [stride repository](https://github.com/cheezy/stride) describes the plugin's skills, agents and hooks.",
            image: nil
          },
          %{
            title: "GitHub Copilot CLI",
            content:
              "Add the Stride Copilot marketplace, then install the plugin:\n\n```bash\ncopilot plugin marketplace add cheezy/stride-copilot-marketplace\ncopilot plugin install stride-copilot\n```\n\nOr install it straight from its repository with `copilot plugin install https://github.com/cheezy/stride-copilot`. Run `copilot plugin list` to check that it loaded. The [stride-copilot repository](https://github.com/cheezy/stride-copilot) has the rest.",
            image: nil
          },
          %{
            title: "Gemini CLI",
            content:
              "Install Stride as a Gemini CLI extension:\n\n```bash\ngemini extensions install https://github.com/cheezy/stride-gemini\n```\n\nThe [stride-gemini repository](https://github.com/cheezy/stride-gemini) has the rest.",
            image: nil
          },
          %{
            title: "Codex CLI",
            content:
              "The Codex plugin comes with an installer script. To install it for every project:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash\n```\n\nTo install it into the current project only:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project\n```\n\nOn Windows, run `irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 | iex` in PowerShell. Read a script before you pipe it into a shell. These come from the [stride-codex repository](https://github.com/cheezy/stride-codex), which also describes a project-only install on Windows and a manual install.",
            image: nil
          },
          %{
            title: "OpenCode",
            content:
              "OpenCode takes two steps, and you need both. First, add the plugin to your project's `opencode.json`, or to `~/.config/opencode/opencode.json` for every project:\n\n```json\n{\n  \"plugin\": [\"github:cheezy/stride-opencode\"]\n}\n```\n\nOpenCode doesn't find skills or agents inside an installed plugin, so then copy them into your project:\n\n```bash\ngit clone https://github.com/cheezy/stride-opencode.git /tmp/stride-opencode\nmkdir -p .opencode/skills\ncp -R /tmp/stride-opencode/skills/. .opencode/skills/\nmkdir -p .opencode/agents\ncp /tmp/stride-opencode/agents/*.md .opencode/agents/\nmkdir -p .opencode/commands\ncp /tmp/stride-opencode/commands/*.md .opencode/commands/\ncp /tmp/stride-opencode/AGENTS.md AGENTS.md\n```\n\nThe last line replaces any `AGENTS.md` you already have. The [stride-opencode repository](https://github.com/cheezy/stride-opencode) has the global version of the copy and how to pin a release.",
            image: nil
          },
          %{
            title: "Pi",
            content:
              "Pi also uses an installer script. To install it for every project:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash\n```\n\nTo install it into the current project only:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash -s -- --project\n```\n\nRead a script before you pipe it into a shell. The [stride-pi repository](https://github.com/cheezy/stride-pi) describes a manual install too.",
            image: nil
          },
          %{
            title: "Lite Plugins",
            content:
              "A lite plugin turns a prompt, and an optional folder of requirements, into Stride-style goal and task markdown files on your disk. It makes no API calls, so it needs no token and neither `.stride_auth.md` nor `.stride.md`; its hooks go in a `.stride_lite.md` file, which the [stride-lite repository](https://github.com/cheezy/stride-lite) explains. It never claims or completes a task on a Stride board.\n\nChoose a lite plugin when you want well-shaped tasks without a Stride board. Choose the full plugin when your agent should work tasks from a board. Three runtimes have a lite plugin:\n\n- Claude Code: after adding the Stride marketplace, run `/plugin install stride-lite@stride-marketplace` ([stride-lite](https://github.com/cheezy/stride-lite))\n- GitHub Copilot CLI: `copilot plugin install https://github.com/cheezy/stride-copilot-lite` ([stride-copilot-lite](https://github.com/cheezy/stride-copilot-lite))\n- OpenCode: add `github:cheezy/stride-opencode-lite` to the `plugin` list in `opencode.json`, then clone the repository and run its `./install.sh`. Its README says it is still in progress ([stride-opencode-lite](https://github.com/cheezy/stride-opencode-lite))\n\nGemini CLI, Codex CLI and Pi have no lite plugin.",
            image: nil
          },
          %{
            title: "Keeping the Plugin Up to Date",
            content:
              "A fix reaches your agent only after you update the plugin. Most full plugins tell you once per session when a newer release exists. To update:\n\n- Claude Code: `/plugin update stride`\n- GitHub Copilot CLI: `copilot plugin update stride-copilot`, or `copilot plugin update stride-copilot-lite` for the lite plugin\n- Gemini CLI: `gemini extensions update stride-gemini`\n- Codex CLI: run the installer again. The stride-codex README gives `codex plugin update stride-codex` for a copy installed as a Codex plugin instead\n- OpenCode: pin the new release in `opencode.json` as `github:cheezy/stride-opencode#vX.Y.Z`, or remove the cached copy under `~/.cache/opencode/`, then restart OpenCode. Copy the skills and agents again from a fresh clone of the same release: `git clone` refuses a folder that already exists, so delete the old clone first, or the copy lines reuse the old files\n- Pi: run the installer again, with `--project` for a project install. If Pi runs a clone of the stride-pi repository directly, run `git pull` in that clone instead, as its README describes\n\nThe stride-lite and stride-opencode-lite READMEs give no update command, so check their repositories for new releases.",
            image: nil
          }
        ]
      },
      %{
        id: "turning-an-idea-into-tasks",
        title: "Turning an Idea Into Tasks",
        description:
          "Use Stride Ideation to turn an idea into a committed requirements document with /ideate, then into a Stride goal and tasks with /stridify, in Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI or OpenCode.",
        tags: ["ai-agents", "tasks", "automation"],
        content_type: "guide",
        reading_time: 7,
        created_at: ~D[2026-11-10],
        steps: [
          %{
            title: "What Stride Ideation Does",
            content:
              "Stride Ideation is a companion plugin for planning work, not for doing it. You describe an idea, and it interviews you about it in a few rounds of questions, then writes a requirements document and commits it to your repository. When you're ready, a second command breaks that document into a Stride goal with tasks and creates them on your board.\n\nIt is separate from the Stride plugin that works tasks, which [Installing the Stride Plugin](/resources/installing-the-stride-plugin) covers, and you can install either one without the other. Well-specified tasks are what agents do best with, as [Writing Effective Tasks for AI Agents](/resources/writing-tasks-for-ai) explains, and Ideation's job is to write them for you.",
            image: nil
          },
          %{
            title: "Before You Start",
            content:
              "Run Ideation inside a git repository, because both commands commit what they write.\n\n- Shaping an idea needs no Stride account: the interview and the requirements document stay on your machine.\n- Creating the tasks needs a Stride account and an AI Optimized board to put them on. [Creating Your First Board](/resources/creating-your-first-board) shows how to make one.\n- It also needs a board token for that board in a `.stride_auth.md` file in the root of your project, and the tasks go to the token's board. Use a board token, not a workspace token: stridify doesn't name a board, so a workspace token can't tell Stride where the tasks go. Add the file to `.gitignore` and never commit it. [Configuring API Authentication](/resources/api-authentication) shows how to create a board token and which lines go in the file.",
            image: nil
          },
          %{
            title: "Installing in Claude Code",
            content:
              "In Claude Code, add the Stride marketplace if you haven't already, then install the plugin from it:\n\n```text\n/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride-ideation@stride-marketplace\n```\n\nIn Claude Code the two commands are `/stride-ideation:ideate` and `/stride-ideation:stridify`. The [stride-ideation repository](https://github.com/cheezy/stride-ideation) is the full reference, and the commands in this guide are copied from it and from each port's README.",
            image: nil
          },
          %{
            title: "Installing in Other Runtimes",
            content:
              "Four other runtimes have an Ideation port. In GitHub Copilot CLI, add the Stride Copilot marketplace, then install the plugin:\n\n```bash\ncopilot plugin marketplace add cheezy/stride-copilot-marketplace\ncopilot plugin install stride-copilot-ideation\n```\n\nOr install it straight from its repository with `copilot plugin install https://github.com/cheezy/stride-copilot-ideation`. Copilot has skills rather than commands: ask it to activate `stride-ideation-ideate` or `stride-ideation-stridify` ([stride-copilot-ideation](https://github.com/cheezy/stride-copilot-ideation)).\n\nIn Gemini CLI, install the extension with `gemini extensions install https://github.com/cheezy/stride-gemini-ideation`, then run `/ideate` and `/stridify` ([stride-gemini-ideation](https://github.com/cheezy/stride-gemini-ideation)).\n\nThe Codex CLI port comes with an installer script. To install it for every project, or into the current project only:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-ideation/main/install.sh | bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-ideation/main/install.sh | bash -s -- --project\n```\n\nOn Windows, run `irm https://raw.githubusercontent.com/cheezy/stride-codex-ideation/main/install.ps1 | iex` in PowerShell. Read a script before you pipe it into a shell. Codex uses the same two skills as Copilot ([stride-codex-ideation](https://github.com/cheezy/stride-codex-ideation)).\n\nFor OpenCode, clone the repository and run its installer from your project, adding `--global` to install it for every project:\n\n```bash\ngit clone https://github.com/cheezy/stride-opencode-ideation.git\n./stride-opencode-ideation/install.sh\n```\n\nThen run `/ideate` and `/stridify` ([stride-opencode-ideation](https://github.com/cheezy/stride-opencode-ideation)).\n\nPi has no Ideation port.",
            image: nil
          },
          %{
            title: "Shaping the Idea With Ideate",
            content:
              "Run the ideate command with a short topic, such as `/stride-ideation:ideate Add a notifications system` in Claude Code. If you don't choose a profile, it first recommends one: lean, the default, or product, discovery or lean-startup, which add questions for those kinds of work.\n\nThe interview runs in rounds of up to four questions each:\n\n- the goal, the problem and the outcome you want\n- your assumptions, the constraints, and what is out of scope\n- how you'll measure success\n- a premortem: imagine the work failed, and say why\n\nThen it challenges the draft and passes it to a reviewer. Both are advice: you choose which findings to address, or write the document as it is.\n\nTwo options change where it starts. `--continue` with the path of an earlier document starts from that document and commits the refined version as a new document with a new timestamp, leaving the earlier one as it was, so give stridify the new path. And `--input` with the path of a notes file seeds the drafts from your notes without ever committing the file.",
            image: nil
          },
          %{
            title: "The Requirements Document",
            content:
              "Ideate writes the document under `docs/ideation/` in your repository, with a timestamped name that ends in `-requirements.md`, and commits it. Every document has the same seven sections:\n\n- Problem\n- Goal\n- Outcome\n- Assumptions\n- Constraints\n- Non-goals\n- Success metrics\n\nIdeate stops there. It never creates tasks by itself, so the document is useful on its own as a written spec, and you can read it, edit it or refine it before anything reaches your board.",
            image: nil
          },
          %{
            title: "Creating the Tasks With Stridify",
            content:
              "When the document says what you want, run the stridify command with its path, such as `/stride-ideation:stridify docs/ideation/2026-11-10T120000-add-notifications-requirements.md` in Claude Code. Stridify:\n\n- checks that the document has all seven sections and that `.stride_auth.md` is in place\n- hands the document to a decomposer subagent, which splits it into goals and tasks\n- writes the result next to the document as a file ending in `-stride-batch.json`, and commits it\n- shows you the goal and task tree and asks before it sends anything, unless you passed `--yes`\n- sends the batch to `POST /api/tasks/batch` and prints the identifiers of the goals and tasks it created\n\nStridify sends the document's content to the Stride API, so keep secrets out of it. If you decline at the preview, the batch stays on disk, and `--batch` with the batch file's path ships it later without splitting the document again. Once a batch has been sent, don't send it again: every goal and task would be created a second time.",
            image: nil
          },
          %{
            title: "The Tasks Land in Backlog",
            content:
              "Stridify creates the tasks; it doesn't start them. The new goal and its tasks appear in the **Backlog** column of your board, and agents only claim tasks from **Ready**.\n\nRead each task before you move it on. When it's ready to work, drag it to **Ready**, or click **Promote children to Ready** on the goal's card to move all of the goal's tasks at once. [Working With Goals](/resources/working-with-goals) shows the goal card, and [Understanding Board Columns and Workflow](/resources/understanding-columns) explains each column.\n\nIn the picture, three tasks wait in **Backlog**, and a goal that has already been promoted is in **Ready** with its progress.",
            image: "/images/resources/guides/turning-an-idea-into-tasks-step-8.png",
            image_width: 588,
            image_height: 496
          },
          %{
            title: "Ideation and Writing Effective Tasks",
            content:
              "[Writing Effective Tasks for AI Agents](/resources/writing-tasks-for-ai) describes what a task needs for an agent to succeed: acceptance criteria, key files, patterns to follow, pitfalls and a testing strategy. Ideation drafts its tasks with those fields, from what you said in the interview. Use that guide as the checklist when you read the tasks in Backlog: fix anything thin or wrong on the board before you move a task to Ready.\n\nA new board hides several of the fields Ideation fills in, such as key files, pitfalls and verification steps. To see and edit them, turn them on under **Field visibility** in the board's settings. [Reading a Task's Details](/resources/reading-a-tasks-details) shows where.",
            image: nil
          }
        ]
      },
      %{
        id: "reviewing-changes-for-security",
        title: "Reviewing Changes for Security",
        description:
          "Check a change for likely security problems with Stride Security Review, by hand or automatically when a task lists security considerations, and read the verdicts a reviewer sees, in Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI or OpenCode.",
        tags: ["reviewing", "automation", "workflow"],
        content_type: "guide",
        reading_time: 7,
        created_at: ~D[2026-11-10],
        steps: [
          %{
            title: "What Stride Security Review Does",
            content:
              "Stride Security Review is a companion plugin that checks a change, or a set of files, for likely security problems: injection, gaps in authentication and authorization, data exposure such as secrets in logs, weak cryptography, missing input validation, cross-site scripting and code execution, insecure configuration, and supply-chain risks such as unpinned dependencies. In code that calls an LLM or an agent, it also looks for prompt injection and tool abuse. It reasons about what the code does rather than matching patterns, and leaves out low-impact noise.\n\nYou can use it two ways: run it yourself on what you've changed, or let the Stride workflow run it for a task that lists security considerations. It is separate from the Stride plugin that works tasks, which [Installing the Stride Plugin](/resources/installing-the-stride-plugin) covers, and the automatic review needs both.\n\nIts findings are advice. It reports likely issues for a person to check: it can miss a problem, and it can flag one that isn't there. The [stride-security-review repository](https://github.com/cheezy/stride-security-review) is the full reference, and the commands in this guide are copied from it and from each port's README.",
            image: nil
          },
          %{
            title: "Installing in Claude Code",
            content:
              "In Claude Code, add the Stride marketplace if you haven't already, then install the plugin from it:\n\n```text\n/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride-security-review@stride-marketplace\n```\n\nIts command is `/stride-security-review:security-review`. Type the full name: Claude Code has a built-in `/security-review` of its own, a simpler review that ignores this plugin's options.",
            image: nil
          },
          %{
            title: "Installing in Other Runtimes",
            content:
              "Four other runtimes have a Security Review port. In GitHub Copilot CLI, install the plugin from its repository:\n\n```bash\ncopilot plugin install https://github.com/cheezy/stride-copilot-security-review\n```\n\nCopilot has skills rather than commands: ask it to activate `security-review-essentials` ([stride-copilot-security-review](https://github.com/cheezy/stride-copilot-security-review)).\n\nIn Gemini CLI, install the extension with `gemini extensions install https://github.com/cheezy/stride-gemini-security-review`, then run `/security-review`. Its README explains starting Gemini CLI with `--include-directories` so the reviewer can read its rule files ([stride-gemini-security-review](https://github.com/cheezy/stride-gemini-security-review)).\n\nThe Codex CLI port comes with an installer script. To install it for every project, or into the current project only:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-security-review/main/install.sh | bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-security-review/main/install.sh | bash -s -- --project\n```\n\nOn Windows, run `irm https://raw.githubusercontent.com/cheezy/stride-codex-security-review/main/install.ps1 | iex` in PowerShell. Read a script before you pipe it into a shell. Codex has no slash commands: ask it to activate the `stride-security-review` skill ([stride-codex-security-review](https://github.com/cheezy/stride-codex-security-review)).\n\nFor OpenCode, clone the repository and run its installer from your project, adding `--global` to install it for every project:\n\n```bash\ngit clone https://github.com/cheezy/stride-opencode-security-review.git\n./stride-opencode-security-review/install.sh\n```\n\nThen run `/security-review` ([stride-opencode-security-review](https://github.com/cheezy/stride-opencode-security-review)).\n\nPi has no Security Review port.",
            image: nil
          },
          %{
            title: "Running a Review by Hand",
            content:
              "With no arguments, the command reviews your uncommitted changes, staged or not, against the last commit. It only sees files git already tracks: a new file you haven't added isn't reviewed, so run `git add` on it first. Name files or folders to review only those, or pass `--full` to review every tracked file, which suits a first look at an existing project but takes longer:\n\n```text\n/stride-security-review:security-review\n/stride-security-review:security-review lib/auth.ex\n/stride-security-review:security-review --full\n```\n\nIn Gemini CLI and OpenCode, put the same arguments after `/security-review`. In Copilot and Codex, give them when you ask for the skill.\n\nRun it before you push or open a pull request, and especially on a change that touches signing in, permissions, user input, secrets, database queries or shell commands.",
            image: nil
          },
          %{
            title: "Reading the Report",
            content:
              "The report opens with the number of findings and a count for each severity:\n\n```text\nSecurity review — 1 finding across 2 files\nCritical: 0   High: 1   Medium: 0   Low: 0   Info: 0\n```\n\nThe findings follow, most severe first. Each one names its kind, such as injection or data exposure, the file and line, how confident the reviewer is (high, medium or low), the CWE and OWASP entries when there are any, what is wrong, and a suggested fix. When there is nothing to review it says no security-relevant changes were detected, and a clean review says `No findings.` with the number of files it read.\n\nThe command shows every finding its reviewer returns and leaves the decision to you. Check each one against the code before you change anything, and read a clean report as nothing found, not as proof that the change is safe.",
            image: nil
          },
          %{
            title: "When the Stride Workflow Runs It",
            content:
              "When the Stride plugin works a task whose **Security considerations** list isn't empty, and Security Review is installed in the same runtime, the workflow runs it during the review before the task is completed. A list that holds only a placeholder such as None doesn't count. This works in Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI and OpenCode.\n\nThe security reviewer gets the change and each consideration, and answers mitigated, partial or unmitigated for each one, with its evidence. Then:\n\n- a consideration that isn't mitigated, or a finding of medium severity or higher, becomes a security issue in the review\n- a security issue fails the review's security considerations verdict and sends the agent back to fix the change and review it again, so a partial or unmitigated consideration blocks the task from being completed\n- low and info findings go in the task's completion notes instead\n- a missing or unreadable answer counts as not mitigated, never as a pass\n\nWithout the plugin, the agent's own reviewer still gives a verdict on the considerations, without a separate answer for each one.\n\nThe Stride plugin reads your API token from `.stride_auth.md`: add it to `.gitignore` and never commit it, as [Configuring API Authentication](/resources/api-authentication) shows.",
            image: nil
          },
          %{
            title: "What a Reviewer Sees",
            content:
              "Open the **Review queue** and select the task. Its **Security considerations** section shows the review's verdict, passed or failed, with the reviewer's note. If the task listed considerations but the review recorded no verdict, the section says they were not assessed.\n\nWhen Security Review ran, each consideration has its own row, marked **Mitigated**, **Partial** or **Unmitigated**, with the evidence beneath it, often a file and line. A task reviewed without the plugin shows the verdict with no rows.\n\nBecause a partial or unmitigated consideration sends the agent back, a task waiting in the queue normally shows every row **Mitigated**. If you see **Partial** or **Unmitigated**, or not assessed, use **Request changes**. A **Mitigated** row is the reviewer's judgement, not proof: check its evidence in the diff before you approve, as [Reviewing Completed Work](/resources/reviewing-completed-work) describes.\n\nIn the picture, the task's one consideration is **Mitigated**, with the file and line that show it.",
            image: "/images/resources/guides/reviewing-changes-for-security-step-7.png",
            image_width: 700,
            image_height: 170
          },
          %{
            title: "On the Task Detail Page",
            content:
              "The task's own page doesn't show the verdict for each consideration; the Review queue does.\n\nIts **Review report** lists the review's issues under **Critical**, **Important** and **Minor**, and an issue the security review raised starts with **Security**. If the task listed considerations but the review didn't assess them, a warning at the top of the report names **Security considerations**.\n\nThe task's own list of security considerations shows when its **Security Considerations** toggle is on under **Field visibility** in the board's settings. [Reading a Task's Details](/resources/reading-a-tasks-details) shows where.\n\nIn the picture, the review report of a task with one security consideration shows the review's summary and **No issues**, and no verdict for the consideration.",
            image: "/images/resources/guides/reviewing-changes-for-security-step-8.png",
            image_width: 722,
            image_height: 158
          }
        ]
      },
      %{
        id: "exploratory-testing-with-agents",
        title: "Exploratory Testing With Agents",
        description:
          "Run a task's manual tests as exploratory charters with Stride Exploratory Testing, know the safety boundary it works under, and write manual tests that make good charters, in Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI or OpenCode.",
        tags: ["automation", "workflow", "tasks"],
        content_type: "guide",
        reading_time: 8,
        created_at: ~D[2026-11-10],
        steps: [
          %{
            title: "What Stride Exploratory Testing Does",
            content:
              "Automated tests check what you already expected. Exploring is the other half of testing: looking for what nobody thought to write down. Stride Exploratory Testing is a companion plugin that does this with an agent, against an app that is running.\n\nIts unit of work is a charter: one mission for one short session, written as \"Explore a target with some resources to discover some information\". The agent works through a charter in a budgeted session, judges what it sees, and reports what it explored, what it found and what it couldn't check.\n\nYou can run it yourself, or let the Stride workflow run a task's manual tests with it. It is separate from the Stride plugin that works tasks, which [Installing the Stride Plugin](/resources/installing-the-stride-plugin) covers, and the automatic run needs both. The plugin itself needs no Stride account or token. The [stride-exploratory-testing repository](https://github.com/cheezy/stride-exploratory-testing) is the full reference, and the commands in this guide are copied from it and from each port's README.",
            image: nil
          },
          %{
            title: "Installing in Claude Code",
            content:
              "In Claude Code, add the Stride marketplace if you haven't already, then install the plugin from it:\n\n```text\n/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride-exploratory-testing@stride-marketplace\n```\n\nIn Claude Code each command carries the plugin's name, such as `/stride-exploratory-testing:explore`.",
            image: nil
          },
          %{
            title: "Installing in Other Runtimes",
            content:
              "Four other runtimes have an Exploratory Testing port. In GitHub Copilot CLI, install the plugin from its repository:\n\n```bash\ncopilot plugin install https://github.com/cheezy/stride-copilot-exploratory-testing\n```\n\nIf you have already added the Stride Copilot marketplace, `copilot plugin install stride-copilot-exploratory-testing` works too. Copilot has skills rather than commands: ask it to activate one by name, such as `stride-exploratory-testing-explore` ([stride-copilot-exploratory-testing](https://github.com/cheezy/stride-copilot-exploratory-testing)).\n\nIn Gemini CLI, install the extension with `gemini extensions install https://github.com/cheezy/stride-gemini-exploratory-testing`, then run `/charter`, `/explore` and the other commands ([stride-gemini-exploratory-testing](https://github.com/cheezy/stride-gemini-exploratory-testing)).\n\nThe Codex CLI port comes with an installer script. To install it for every project, or into the current project only:\n\n```bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-exploratory-testing/main/install.sh | bash\ncurl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-exploratory-testing/main/install.sh | bash -s -- --project\n```\n\nOn Windows, run `irm https://raw.githubusercontent.com/cheezy/stride-codex-exploratory-testing/main/install.ps1 | iex` in PowerShell. Read a script before you pipe it into a shell. Codex uses the same skills as Copilot ([stride-codex-exploratory-testing](https://github.com/cheezy/stride-codex-exploratory-testing)).\n\nFor OpenCode, clone the repository and run its installer from your project, adding `--global` to install it for every project:\n\n```bash\ngit clone https://github.com/cheezy/stride-opencode-exploratory-testing.git\n./stride-opencode-exploratory-testing/install.sh\n```\n\nThe installer keeps any `AGENTS.md` you already have. Then run `/charter`, `/explore` and the other commands ([stride-opencode-exploratory-testing](https://github.com/cheezy/stride-opencode-exploratory-testing)).\n\nPi has no Exploratory Testing port.",
            image: nil
          },
          %{
            title: "The Seven Commands",
            content:
              "The plugin has seven commands. Below they use their short names, as in Gemini CLI and OpenCode. In Claude Code, put `stride-exploratory-testing:` after the slash. In Copilot and Codex, ask for the skill of the same name, such as `stride-exploratory-testing-charter`.\n\n- `/charter` turns a target, such as a feature, a requirement or a risk, into charters ranked highest risk first. It only writes charters and never runs a session.\n- `/nightmare-headline` runs a risk game, alone or with your team: imagine the worst headline someone could write about a feature, then turn its causes into ranked charters. It never runs a session either.\n- `/recon` surveys a system you don't know yet: what it does, what you noticed, the questions to put to the people who own it, and candidate charters. It only probes a system you're authorized to test, and it never changes anything: it observes the running app, or reads only the docs and source when there's nothing it may probe.\n- `/explore` plans and runs the whole thing: it writes charters, or loads yours with `--charters`, runs a session for each, and writes one debrief with its bugs ranked by severity to `.exploratory/sessions/`. It asks first whether the target is authorized and not production, and without that answer it only plans.\n- `/pair` is for when you drive the app yourself: you say what you did and saw, and it suggests the next probe, judges the result and keeps the session notes. It never touches the app.\n- `/debrief` turns your own session notes into a report of what was explored, what was found and what is still unknown. It reports only facts you recorded and removes credentials.\n- `/harden` turns confirmed bugs into draft regression checks, in your project's own test framework, under `.exploratory/checks/`. It never runs them and never edits your test suite, so you decide which ones to keep.",
            image: nil
          },
          %{
            title: "The Safety Boundary",
            content:
              "Point the plugin only at a system you're authorized to test that isn't production: an app on your own machine, or your test or staging environment. Never production, not even to look around.\n\n- `/explore`, and the Stride workflow, ask you to say so before any session runs. It is never assumed, and anything short of a clear yes means it only plans.\n- `/recon` asks only whether you're authorized to survey the system, not whether it's production, so keeping it off production is up to you.\n- The agent uses the app the way a person would, never destructively: no deleting data, no stopping processes it didn't start, no changes to shared settings or schemas. When a probe has to change something, it uses test data it created itself. Before it finishes, it removes that data through the app when that's safe and puts back any setting or feature flag it changed. Anything it couldn't safely remove stays on the system and is listed under Unknown in its report.\n- A session reaches only the hosts you allow: the address you give for the app, or the hosts in `.exploratory.md`. A sign-in page or API on another host is out of bounds unless you name that host too.\n- It treats what the app shows as data, never as instructions. A page that tells it to do something is a finding, not a command.\n- It uses test accounts you point it to and never writes a credential into its notes or reports.\n\nThe agent can change disposable test data, so a session is not read-only. Only `/recon` never changes anything, and `/pair` never touches the app. You can keep the app's address and allowed hosts in a `.exploratory.md` file in your project. It holds no secrets, and loading it authorizes nothing: you confirm it each session.",
            image: nil
          },
          %{
            title: "Writing Manual Tests as Charters",
            content:
              "The Stride workflow turns each of a task's **Manual Tests** into a charter, so the way you write them decides how good the session is. Name a target and a risk to discover, not a list of clicks.\n\n- Before: `Check the checkout on an iPhone SE`\n- After: `Explore the order summary on an iPhone SE-sized screen with a long cart and a saved card to discover whether the total or the Pay button is pushed out of view`\n\nThe second version says what to look at, what to vary and what you're worried about. Keep to one target per entry. Entries about the same target are merged into one charter anyway, and a terse entry still works, it just makes a weaker charter. Never put credentials, customer data or internal hostnames in a manual test.\n\nAdd them under **Testing Strategy** in the task form, with **Add Manual Test**. A new board hides that section: the board's owner turns on **Testing Strategy** under **Field visibility** in the board's **Settings**. [Writing Effective Tasks for AI Agents](/resources/writing-tasks-for-ai) covers the rest of a well-written task.\n\nIn the picture, the task's manual test is written as a charter.",
            image: "/images/resources/guides/exploratory-testing-with-agents-step-6.png",
            image_width: 1036,
            image_height: 316
          },
          %{
            title: "When the Stride Workflow Runs It",
            content:
              "When the Stride plugin works a task whose **Testing Strategy** lists **Manual Tests**, and Exploratory Testing is installed in the same runtime, the workflow runs them after the code review and before the task's hooks. This works in Claude Code, GitHub Copilot CLI, Gemini CLI, Codex CLI and OpenCode.\n\n- At the start, the agent asks you once whether the app is authorized and not production, how to reach it, and where its test accounts or seed data are. How you say to reach it decides the hosts a session may use. Only your clear yes counts. Without it the step is skipped, and the task still completes with the manual tests left to a person.\n- Manual tests become charters, with tests that share a target merged into one, alongside charters for the change's own risks. They run highest risk first, about five at most for a task and about three for a small one, and a manual test past the limit is left to a person. Each session has a budget of probes, 12 by default.\n- The workflow only ever runs sessions. It never runs the commands that wait for a person, such as `/pair`.\n- An app that isn't running, or a budget that runs out, never fails the task: the agent records what it couldn't check.\n\n[Understanding Claim/Complete Workflow](/resources/claim-complete-workflow) explains the rest of the loop.",
            image: nil
          },
          %{
            title: "What a Reviewer Sees",
            content:
              "Exploratory testing adds no new field to a task. Open the **Review queue** and select the task:\n\n- **Completion summary** has a line such as `Exploratory coverage: 1 performed, 0 partial, 0 not performed`, and names the worst finding when there was one.\n- **Completion notes** has a line for each charter, with how its session ended, how many probes it ran, and whether it was performed, partial or not performed. A line starting `HANDED BACK:` names a check left for a person.\n\nPartial or not performed means part of the risk wasn't checked, so check it yourself before you approve. A bug caused by the change is fixed in the same task, and a critical one blocks the task from being completed until it is. A bug the change didn't cause is recorded in the completion notes, and a serious one gets a follow-up task. [Reviewing Completed Work](/resources/reviewing-completed-work) explains the rest of the review.\n\nIn the picture, the completion summary and notes show one charter, performed with 12 probes.",
            image: "/images/resources/guides/exploratory-testing-with-agents-step-8.png",
            image_width: 704,
            image_height: 231
          },
          %{
            title: "Keeping Session Files Out of Git",
            content:
              "The plugin writes its files to an `.exploratory/` folder in the project you test: a backlog of charters, a coverage map, session reports and draft checks. They can quote what the app showed, so add one line to your project's `.gitignore` before your first session:\n\n```text\n.exploratory/\n```\n\nA `.gitignore` line doesn't untrack a file git already has, so run `git rm --cached` on anything that was committed before. A hook that runs `git add -A` or `git add .` would sweep the folder in too, which is one more reason to add the line first. The Stride workflow reminds you of this line but never edits your `.gitignore` for you.\n\nThe Stride plugin's `.stride_auth.md` belongs in `.gitignore` as well: never commit it, as [Configuring API Authentication](/resources/api-authentication) shows.",
            image: nil
          }
        ]
      }
    ]
  end
end
