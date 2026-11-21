defmodule KanbanWeb.Comparisons do
  @moduledoc """
  The comparison pages published at `/compare/:competitor` (W2901): Stride
  against GitHub Projects, Linear and Jira for work done by AI coding agents.

  Each comparison says where Stride fits and where the other product is the
  better choice. Every statement about the other product is a `Claim` with
  at least one source, and every source is a page of that product's own
  documentation. The rules are in `docs/compare-pages.md`:

    * Never state a price, a plan limit or a numeric cap of another product.
    * Never say another product lacks something. An absence claim cannot be
      sourced and goes stale the day the product ships the feature.
    * Paraphrase. Never copy another product's wording or use its logo.
    * Re-check every source and bump `last_reviewed` whenever a comparison is
      touched.

  The points about Stride (`stride_fits/0`) only state what this repository's
  own docs say, and each one names that doc in a comment.

  The prose goes through `gettext` in `all/0`, so it follows the request's
  locale. Product names and source URLs are literals and are never
  translated. A slug is only ever looked up in this list (`fetch/1`).
  """

  use Gettext, backend: KanbanWeb.Gettext

  defmodule Claim do
    @moduledoc """
    One statement about another product, with the pages of that product's own
    documentation that support it.
    """
    @enforce_keys [:text, :sources]
    defstruct @enforce_keys

    @type t :: %__MODULE__{text: String.t(), sources: [String.t(), ...]}
  end

  defmodule Comparison do
    @moduledoc """
    Stride against one other product. `better_choice` holds the cases where
    the other product is the better choice, each a sourced `Claim`.
    """
    @enforce_keys [:slug, :competitor, :last_reviewed, :better_choice]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            slug: String.t(),
            competitor: String.t(),
            last_reviewed: Date.t(),
            better_choice: [KanbanWeb.Comparisons.Claim.t()]
          }
  end

  @competitors [
    {"github-projects", "GitHub Projects"},
    {"linear", "Linear"},
    {"jira", "Jira"}
  ]

  @slugs Enum.map(@competitors, &elem(&1, 0))

  @github_docs "https://docs.github.com/en/issues/planning-and-tracking-with-projects"
  @about_projects @github_docs <> "/learning-about-projects/about-projects"

  @doc """
  Every comparison, in the order the footer lists them.
  """
  @spec all() :: [Comparison.t()]
  def all, do: [github_projects(), linear(), jira()]

  @doc """
  The slugs of every comparison, in footer order.
  """
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc """
  `{slug, product name}` for every comparison, in footer order. Builds no
  claims, so the footer can call it on every page.
  """
  @spec footer_links() :: [{String.t(), String.t()}]
  def footer_links, do: @competitors

  @doc """
  Looks a comparison up by its slug. Anything that is not one of `slugs/0`
  answers `:error`.
  """
  @spec fetch(String.t()) :: {:ok, Comparison.t()} | :error
  def fetch(slug) when slug in @slugs, do: {:ok, Enum.find(all(), &(&1.slug == slug))}
  def fetch(_slug), do: :error

  @doc """
  The paths `/sitemap.xml` lists for the comparisons. There is no index page.
  """
  @spec sitemap_paths() :: [String.t()]
  def sitemap_paths, do: Enum.map(@slugs, &("/compare/" <> &1))

  @doc """
  The `<title>` of a comparison's page.
  """
  @spec page_title(Comparison.t()) :: String.t()
  def page_title(%Comparison{competitor: name}),
    do: gettext("Stride vs %{name} for AI agent work", name: name)

  @doc """
  The meta description of a comparison's page.
  """
  @spec meta_description(Comparison.t()) :: String.t()
  def meta_description(%Comparison{competitor: name}) do
    gettext(
      "How Stride and %{name} compare for work done by AI coding agents: where each one fits, with a source for every claim about %{name}.",
      name: name
    )
  end

  @doc """
  Where Stride fits for AI agent work. The same on every comparison, and only
  what Stride's own docs state.
  """
  @spec stride_fits() :: [String.t()]
  def stride_fits do
    [
      # docs/AI-WORKFLOW.md, "It is not already claimed."
      gettext(
        "An agent claims a task from the Ready column before it starts, and the claim expires after 60 minutes."
      ),
      # docs/TASK-WRITING-GUIDE.md, "key_files"
      gettext(
        "When an agent asks for its next task, Stride skips a Ready task whose key files overlap a task already in Doing or Review."
      ),
      # docs/TASK-WRITING-GUIDE.md, task fields
      gettext(
        "Tasks carry what an agent needs to work without guessing: key files, patterns to follow, pitfalls, acceptance criteria, a testing strategy and verification steps."
      ),
      # docs/AGENT-HOOK-EXECUTION-GUIDE.md, "Overview"
      gettext(
        "Hooks you write in .stride.md run on the agent's own machine before work starts, after it is done, and around review, so your tests and checks gate every task."
      ),
      # docs/REVIEW-WORKFLOW.md
      gettext(
        "A task that needs a person moves to Review when the agent finishes, and waits there until someone approves it."
      ),
      # docs/MCP.md and KanbanWeb.Integrations
      gettext(
        "Agents connect through a REST API or an MCP server, and Stride has plugins for Claude Code, Codex CLI, Gemini CLI, GitHub Copilot, OpenCode and Pi."
      )
    ]
  end

  defp github_projects do
    %Comparison{
      slug: "github-projects",
      competitor: "GitHub Projects",
      last_reviewed: ~D[2026-11-21],
      better_choice: [
        %Claim{
          text:
            gettext(
              "Your work already lives in GitHub issues and pull requests. A project is built from them, and changes sync both ways."
            ),
          sources: [@about_projects]
        },
        %Claim{
          text:
            gettext(
              "You want an agent that works inside GitHub. Assigning an issue to Copilot starts a session that opens a pull request and asks you to review it."
            ),
          sources: [
            "https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/overview"
          ]
        },
        %Claim{
          text:
            gettext(
              "You need several views of the same work: table, board and roadmap layouts, with custom fields such as text, number, date, single select and iteration."
            ),
          sources: [@about_projects]
        },
        %Claim{
          text:
            gettext(
              "You automate with GitHub's own tools. Built-in workflows update fields as items change, and GitHub Actions and the GraphQL API cover the rest."
            ),
          sources: [
            @github_docs <> "/automating-your-project/using-the-built-in-automations",
            @github_docs <> "/automating-your-project/using-the-api-to-manage-projects"
          ]
        }
      ]
    }
  end

  defp linear do
    %Comparison{
      slug: "linear",
      competitor: "Linear",
      last_reviewed: ~D[2026-11-21],
      better_choice: [
        %Claim{
          text:
            gettext(
              "You plan in cycles and projects. Cycles are repeating, time-boxed periods in which unfinished issues usually roll over, and projects group issues toward an outcome."
            ),
          sources: ["https://linear.app/docs/use-cycles", "https://linear.app/docs/projects"]
        },
        %Claim{
          text:
            gettext(
              "You want issue status to follow your pull requests. With the GitHub integration, an issue moves to in progress when its pull request opens and to done when it merges."
            ),
          sources: ["https://linear.app/docs/github"]
        },
        %Claim{
          text:
            gettext(
              "You want agents inside your team's tracker. You can delegate an issue to an agent while a person stays its assignee and stays responsible for it."
            ),
          sources: [
            "https://linear.app/docs/agents-in-linear",
            "https://linear.app/docs/assigning-issues"
          ]
        },
        %Claim{
          text:
            gettext(
              "You want to build your own integration or agent. Linear has a public GraphQL API, and an agent API for agents that take delegated issues."
            ),
          sources: [
            "https://linear.app/developers/graphql",
            "https://linear.app/developers/agents"
          ]
        }
      ]
    }
  end

  defp jira do
    %Comparison{
      slug: "jira",
      competitor: "Jira",
      last_reviewed: ~D[2026-11-21],
      better_choice: [
        %Claim{
          text:
            gettext(
              "Your team runs Scrum or Kanban. Jira has Kanban boards, and Scrum backlogs in which you plan sprints."
            ),
          sources: [
            "https://support.atlassian.com/jira-software-cloud/docs/create-a-kanban-board-based-on-projects/",
            "https://support.atlassian.com/jira-software-cloud/docs/use-your-scrum-backlog/"
          ]
        },
        %Claim{
          text:
            gettext(
              "You need workflows shaped to your process. A workflow is a set of statuses and transitions that admins can edit."
            ),
          sources: [
            "https://support.atlassian.com/jira-cloud-administration/docs/work-with-issue-workflows/"
          ]
        },
        %Claim{
          text:
            gettext(
              "You automate across your work. Automation rules are built from triggers, conditions and actions."
            ),
          sources: [
            "https://support.atlassian.com/cloud-automation/docs/create-and-edit-jira-automation-rules/"
          ]
        },
        %Claim{
          text:
            gettext(
              "You want agents across Atlassian's tools. Work items can be assigned to Rovo agents, to agents your team builds or to third-party agents, and an agent can start when an item reaches a status."
            ),
          sources: [
            "https://support.atlassian.com/rovo/docs/agents/",
            "https://support.atlassian.com/jira-software-cloud/docs/collaborate-on-work-items-with-ai-agents/"
          ]
        }
      ]
    }
  end
end
