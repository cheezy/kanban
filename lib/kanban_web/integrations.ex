defmodule KanbanWeb.Integrations do
  @moduledoc """
  The agent runtimes Stride has a plugin for, published at `/integrations` and
  `/integrations/:runtime` (W2899).

  Each runtime has a fixed slug, its install steps, the marketplace or
  repository it is listed in, its README and what the plugin adds. A slug is
  only ever looked up in this list (`fetch/1`), never turned into a path.

  The install commands are copied by hand from each plugin's README, never
  fetched at runtime, and are never translated. Every command must be the
  whole body of one fenced code block in the README named by its step's
  `:source`. The plugin repositories are not part of this repository, so a
  copy of each README's install section is committed under
  `test/support/fixtures/plugin_readmes/`, and
  `test/kanban_web/integrations_test.exs` checks every command against it. When
  a plugin checkout sits beside the app, the same test also fails when its
  README's install section no longer matches the committed copy.
  `docs/integrations-pages.md` explains how to update a command or add a
  runtime.

  The prose (taglines, capabilities and step titles) goes through `gettext`
  in `all/0`, so it follows the request's locale. Names, commands and URLs are
  literals.
  """

  use Gettext, backend: KanbanWeb.Gettext

  defmodule Step do
    @moduledoc """
    One install step: a translated title and a command copied verbatim from
    the README of the repository named by `:source`.
    """
    @enforce_keys [:title, :command, :lang, :source]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            title: String.t(),
            command: String.t(),
            lang: String.t(),
            source: String.t()
          }
  end

  defmodule Runtime do
    @moduledoc """
    One agent runtime and its Stride plugin.

    `listing_kind` says what `listing_url` points at: a plugin marketplace, an
    extension index (Gemini CLI has no marketplace of its own) or, where the
    runtime has neither, the plugin's repository.

    `install_note`, when set, is a step the commands alone do not cover, shown
    after them with a link to `install_note_url` in the plugin's README.
    """
    @enforce_keys [
      :slug,
      :name,
      :tagline,
      :capabilities,
      :install,
      :listing_kind,
      :listing_url,
      :docs_url,
      :preview
    ]
    defstruct @enforce_keys ++ [install_note: nil, install_note_url: nil]

    @type listing_kind :: :marketplace | :extension_index | :repository

    @type t :: %__MODULE__{
            slug: String.t(),
            name: String.t(),
            tagline: String.t(),
            capabilities: [String.t()],
            install: [KanbanWeb.Integrations.Step.t()],
            listing_kind: listing_kind(),
            listing_url: String.t(),
            docs_url: String.t(),
            preview: boolean(),
            install_note: String.t() | nil,
            install_note_url: String.t() | nil
          }
  end

  @slugs ~w(claude-code codex gemini-cli github-copilot opencode pi)

  @five_agents "task-explorer, task-enricher, task-decomposer, task-reviewer, hook-diagnostician"

  @doc """
  Every runtime, in the order the index lists them.
  """
  @spec all() :: [Runtime.t()]
  def all do
    [claude_code(), codex(), gemini_cli(), github_copilot(), opencode(), pi()]
  end

  @doc """
  The slugs of every runtime, in index order.
  """
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc """
  Looks a runtime up by its slug. Anything that is not one of `slugs/0`
  answers `:error`.
  """
  @spec fetch(String.t()) :: {:ok, Runtime.t()} | :error
  def fetch(slug) when slug in @slugs, do: {:ok, Enum.find(all(), &(&1.slug == slug))}
  def fetch(_slug), do: :error

  @doc """
  The paths `/sitemap.xml` lists for the integrations: the index and every
  runtime page.
  """
  @spec sitemap_paths() :: [String.t()]
  def sitemap_paths, do: ["/integrations" | Enum.map(@slugs, &("/integrations/" <> &1))]

  @doc """
  The `<title>` of a runtime's page.
  """
  @spec page_title(Runtime.t()) :: String.t()
  def page_title(%Runtime{name: name}),
    do: gettext("Stride for %{name}: install steps", name: name)

  @doc """
  The meta description of a runtime's page.
  """
  @spec meta_description(Runtime.t()) :: String.t()
  def meta_description(%Runtime{name: name}) do
    gettext(
      "Install Stride for %{name}: the command to run, what the plugin adds to your agent, and how to have it claim its first task on a Stride board.",
      name: name
    )
  end

  defp claude_code do
    %Runtime{
      slug: "claude-code",
      name: "Claude Code",
      tagline:
        gettext("The original Stride plugin, with automatic hooks, subagents and slash commands."),
      capabilities: [
        lifecycle_skills(),
        automatic_hooks(),
        subagents(@five_agents),
        commands("/stride:create-tasks, /stride:create-goals")
      ],
      install: [
        %Step{
          title: gettext("In Claude Code, add the Stride marketplace and install the plugin"),
          command:
            "/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride@stride-marketplace",
          lang: "text",
          source: "stride"
        }
      ],
      listing_kind: :marketplace,
      listing_url: "https://github.com/cheezy/stride-marketplace",
      docs_url: "https://github.com/cheezy/stride#readme",
      preview: false
    }
  end

  defp codex do
    %Runtime{
      slug: "codex",
      name: "Codex CLI",
      tagline: gettext("Stride skills and agents for OpenAI's Codex CLI."),
      capabilities: [
        lifecycle_skills(),
        subagents(@five_agents),
        gettext(
          "A hook that records loop state and downloads a claimed task's attachments. The agent runs your .stride.md commands itself."
        )
      ],
      install: [
        %Step{
          title: install_globally(),
          command:
            "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash",
          lang: "bash",
          source: "stride-codex"
        },
        %Step{
          title: install_project_only(),
          command:
            "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project",
          lang: "bash",
          source: "stride-codex"
        },
        %Step{
          title: gettext("On Windows, in PowerShell"),
          command:
            "irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 | iex",
          lang: "powershell",
          source: "stride-codex"
        },
        %Step{
          title: gettext("Or add the Stride marketplace for Codex"),
          command: "codex plugin marketplace add cheezy/stride-codex-marketplace",
          lang: "bash",
          source: "stride-codex-marketplace"
        },
        %Step{
          title: gettext("Then install the plugin from it"),
          command: "codex plugin install stride-codex",
          lang: "bash",
          source: "stride-codex-marketplace"
        }
      ],
      listing_kind: :marketplace,
      listing_url: "https://github.com/cheezy/stride-codex-marketplace",
      docs_url: "https://github.com/cheezy/stride-codex#readme",
      preview: false,
      install_note:
        gettext(
          "The script installs copy the hook, but Codex does not load it from there: register it once by hand. The marketplace install needs no extra step."
        ),
      install_note_url: "https://github.com/cheezy/stride-codex#registering-the-hook"
    }
  end

  defp gemini_cli do
    %Runtime{
      slug: "gemini-cli",
      name: "Gemini CLI",
      tagline:
        gettext("A Gemini CLI extension with Stride skills, custom agents and automatic hooks."),
      capabilities: [
        lifecycle_skills(),
        automatic_hooks(),
        subagents(@five_agents)
      ],
      install: [
        %Step{
          title: gettext("Install the extension from GitHub"),
          command: "gemini extensions install https://github.com/cheezy/stride-gemini",
          lang: "bash",
          source: "stride-gemini"
        }
      ],
      listing_kind: :extension_index,
      listing_url: "https://github.com/cheezy/stride-gemini-marketplace",
      docs_url: "https://github.com/cheezy/stride-gemini#readme",
      preview: false
    }
  end

  defp github_copilot do
    %Runtime{
      slug: "github-copilot",
      name: "GitHub Copilot",
      tagline:
        gettext(
          "A GitHub Copilot CLI plugin with Stride skills, custom agents and automatic hooks."
        ),
      capabilities: [
        lifecycle_skills(),
        automatic_hooks(),
        subagents(@five_agents)
      ],
      install: [
        %Step{
          title: gettext("Add the Stride marketplace for Copilot and install the plugin"),
          command:
            "copilot plugin marketplace add cheezy/stride-copilot-marketplace\ncopilot plugin install stride-copilot",
          lang: "bash",
          source: "stride-copilot"
        },
        %Step{
          title: gettext("Or install straight from the repository"),
          command: "copilot plugin install https://github.com/cheezy/stride-copilot",
          lang: "bash",
          source: "stride-copilot"
        }
      ],
      listing_kind: :marketplace,
      listing_url: "https://github.com/cheezy/stride-copilot-marketplace",
      docs_url: "https://github.com/cheezy/stride-copilot#readme",
      preview: false
    }
  end

  defp opencode do
    %Runtime{
      slug: "opencode",
      name: "OpenCode",
      tagline:
        gettext(
          "An OpenCode plugin that runs your hooks, plus Stride skills, subagents and commands."
        ),
      capabilities: [
        lifecycle_skills(),
        automatic_hooks(),
        subagents(@five_agents),
        commands("/create-tasks, /create-goals")
      ],
      install: [
        %Step{
          title:
            gettext("Add the plugin to opencode.json, in your project or in ~/.config/opencode/"),
          command: ~s({\n  "plugin": ["github:cheezy/stride-opencode"]\n}),
          lang: "json",
          source: "stride-opencode"
        },
        %Step{
          title: gettext("Copy the skills, subagents and commands into your project"),
          command: """
          # Clone once somewhere
          git clone https://github.com/cheezy/stride-opencode.git /tmp/stride-opencode

          # Copy the 7 skills (each is a directory with a SKILL.md)
          mkdir -p .opencode/skills
          cp -R /tmp/stride-opencode/skills/. .opencode/skills/

          # Copy the 5 subagent markdown files
          mkdir -p .opencode/agents
          cp /tmp/stride-opencode/agents/*.md .opencode/agents/

          # Copy the 2 native commands (/create-tasks, /create-goals)
          mkdir -p .opencode/commands
          cp /tmp/stride-opencode/commands/*.md .opencode/commands/

          # Copy the project-level AGENTS.md (orientation for the main agent)
          cp /tmp/stride-opencode/AGENTS.md AGENTS.md\
          """,
          lang: "bash",
          source: "stride-opencode"
        }
      ],
      listing_kind: :repository,
      listing_url: "https://github.com/cheezy/stride-opencode",
      docs_url: "https://github.com/cheezy/stride-opencode#readme",
      preview: false
    }
  end

  defp pi do
    %Runtime{
      slug: "pi",
      name: "Pi",
      tagline: gettext("Stride skills for Pi, with extensions for hooks and subagents."),
      capabilities: [
        lifecycle_skills(),
        automatic_hooks(),
        gettext(
          "A subagent-dispatch extension that runs the explorer, the reviewer and the other agents in their own context."
        )
      ],
      install: [
        %Step{
          title: install_globally(),
          command:
            "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash",
          lang: "bash",
          source: "stride-pi"
        },
        %Step{
          title: install_project_only(),
          command:
            "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash -s -- --project",
          lang: "bash",
          source: "stride-pi"
        }
      ],
      listing_kind: :repository,
      listing_url: "https://github.com/cheezy/stride-pi",
      docs_url: "https://github.com/cheezy/stride-pi#readme",
      preview: false
    }
  end

  defp lifecycle_skills do
    gettext(
      "Lifecycle skills, led by the stride-workflow orchestrator, that take a task from claim to completion."
    )
  end

  defp automatic_hooks do
    gettext("Runs your .stride.md hook commands automatically at each step of a task.")
  end

  defp subagents(names) do
    gettext(
      "Agents that explore the code, review the change and diagnose failing hooks: %{names}.",
      names: names
    )
  end

  defp commands(commands) do
    gettext("Two commands that create tasks and goals: %{commands}.", commands: commands)
  end

  defp install_globally, do: gettext("Install globally, for every project")
  defp install_project_only, do: gettext("Or install into the current project only")
end
