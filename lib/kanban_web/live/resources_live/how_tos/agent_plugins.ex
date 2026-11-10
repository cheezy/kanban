defmodule KanbanWeb.ResourcesLive.HowTos.AgentPlugins do
  @moduledoc """
  Guides for the Stride plugins that drive a coding agent: installing the
  plugin in each runtime (Claude Code, GitHub Copilot CLI, Gemini CLI,
  Codex CLI, OpenCode and Pi), the lite plugins, and keeping a plugin up
  to date.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after `HowTos.OrgAdmin` and
  before `HowTos.Developer`, and every guide leads with the `developer` tag,
  so the developer chain opens here: installing the plugin → setting up
  hooks → API authentication → the claim/complete workflow → debugging
  hooks → connecting an MCP client. A later plugin guide added to this
  module runs on into setting up hooks the same way.

  The guides follow the README of each plugin repository: cheezy/stride,
  stride-copilot, stride-gemini, stride-codex, stride-opencode, stride-pi,
  stride-lite, stride-copilot-lite and stride-opencode-lite. Re-read them
  when a plugin's install or update command changes; no test reads them,
  because they are not checked out in CI.
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
      }
    ]
  end
end
