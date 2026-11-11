defmodule KanbanWeb.ResourcesLive.HowTos.AgentPlugins do
  @moduledoc """
  Guides for the Stride plugins that drive a coding agent: installing the
  plugin in each runtime (Claude Code, GitHub Copilot CLI, Gemini CLI,
  Codex CLI, OpenCode and Pi), the lite plugins, keeping a plugin up to
  date, and turning an idea into tasks with the Stride Ideation plugin.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after `HowTos.OrgAdmin` and
  before `HowTos.Developer`. The installing guide leads with the `developer`
  tag, so the developer chain opens here: installing the plugin → setting up
  hooks → API authentication → the claim/complete workflow → debugging
  hooks → connecting an MCP client. The Ideation guide leads with
  `ai-agents` instead, so it stays out of that chain and its count: in the
  `ai-agents` chain it sits between installing the plugin and setting up
  hooks, and no guide that leads with `ai-agents` changes neighbours.

  The guides follow the README of each plugin repository: cheezy/stride,
  stride-copilot, stride-gemini, stride-codex, stride-opencode, stride-pi,
  stride-lite, stride-copilot-lite and stride-opencode-lite, and for
  Ideation stride-ideation (with its `commands/ideate.md` and
  `commands/stridify.md`), stride-copilot-ideation, stride-gemini-ideation,
  stride-codex-ideation and stride-opencode-ideation. Re-read them when a
  plugin's install or update command changes; no test reads them, because
  they are not checked out in CI.
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
      }
    ]
  end
end
