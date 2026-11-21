defmodule KanbanWeb.Docs do
  @moduledoc """
  The guides published on the site at `/docs` (W2898).

  `docs/` stays the source of truth: the guides are written and reviewed there
  and read on GitHub. Only the pages in the explicit allow-list below are
  published, each under a fixed slug. The release image does not copy `docs/`,
  so each published file has a committed copy at the same path under `priv/`
  (`priv/docs/...`), which this module reads and renders at compile time.
  `test/kanban_web/docs_test.exs` fails when a copy differs from its source,
  and prints the `cp` command that fixes it. `docs/docs-site.md` explains how
  to publish another guide.

  A slug is only ever looked up in the allow-list (`fetch/1`), never turned
  into a file path. Security findings, plans, runbooks and other internal docs
  are not on the list, so they are never published; a link to one from a
  published guide points at GitHub instead (`KanbanWeb.Docs.Links`).

  Guides stay in English. Their meta descriptions are authored English data
  here, like the how-to descriptions in `KanbanWeb.ResourcesLive.Seo`; the page
  chrome around them is translated.
  """

  alias KanbanWeb.Docs.Renderer
  alias KanbanWeb.MarketingClosing

  @type group :: :guide | :api

  @type page :: %{
          slug: String.t(),
          source: String.t(),
          group: group(),
          description: String.t(),
          title: String.t(),
          page_title: String.t(),
          html: String.t(),
          toc: [Renderer.toc_entry()]
        }

  @catalog [
    %{
      slug: "getting-started-with-ai",
      source: "docs/GETTING-STARTED-WITH-AI.md",
      group: :guide,
      description:
        "Set up an AI coding agent to work Stride tasks: create an API token, add the config files, install the plugin and claim your first task."
    },
    %{
      slug: "ai-workflow",
      source: "docs/AI-WORKFLOW.md",
      group: :guide,
      description:
        "How AI agents move work through a Stride board: finding tasks, claiming them, running hooks, completing the work and handing it to review."
    },
    %{
      slug: "mcp",
      source: "docs/MCP.md",
      group: :guide,
      description:
        "Connect an MCP client to the Stride MCP server so AI agents can list, claim and complete tasks through Model Context Protocol tools."
    },
    %{
      slug: "authentication",
      source: "docs/AUTHENTICATION.md",
      group: :guide,
      description:
        "How AI agents authenticate to the Stride API with bearer tokens: creating a token, sending it, keeping it secret and handling errors."
    },
    %{
      slug: "agent-hook-execution-guide",
      source: "docs/AGENT-HOOK-EXECUTION-GUIDE.md",
      group: :guide,
      description:
        "How agents run Stride's lifecycle hooks on their own machine: the .stride.md format, environment variables, timeouts and blocking rules."
    },
    %{
      slug: "api",
      source: "docs/api/README.md",
      group: :api,
      description:
        "The Stride REST API for AI agents: the endpoints for finding, claiming, completing and reviewing tasks, with request and response examples."
    },
    %{
      slug: "api-get-agent-onboarding",
      source: "docs/api/get_agent_onboarding.md",
      group: :api,
      description:
        "GET /api/agent/onboarding gives a new AI agent what it needs to start on Stride, with no token required: setup steps, templates and hooks."
    },
    %{
      slug: "api-get-boards",
      source: "docs/api/get_boards.md",
      group: :api,
      description:
        "GET /api/boards lists the boards an API token can be used on, so a workspace token can find the board ids it sends with each request."
    },
    %{
      slug: "api-get-openapi-json",
      source: "docs/api/get_openapi_json.md",
      group: :api,
      description:
        "GET /api/openapi.json serves the machine-readable OpenAPI 3.1 description of the whole Stride API, for generating clients."
    },
    %{
      slug: "api-get-tasks",
      source: "docs/api/get_tasks.md",
      group: :api,
      description:
        "GET /api/tasks lists the tasks on a Stride board, with opt-in cursor pagination and filters, so an agent can see the whole queue."
    },
    %{
      slug: "api-get-tasks-id",
      source: "docs/api/get_tasks_id.md",
      group: :api,
      description:
        "GET /api/tasks/:id returns one Stride task with all its fields: description, acceptance criteria, key files, tests and review state."
    },
    %{
      slug: "api-get-tasks-id-after-goal-status",
      source: "docs/api/get_tasks_id_after_goal_status.md",
      group: :api,
      description:
        "GET /api/tasks/:id/after_goal_status says whether completing a task armed its goal's after_goal hook, with the variables to run it."
    },
    %{
      slug: "api-get-tasks-id-attachments-attachment-id",
      source: "docs/api/get_tasks_id_attachments_attachment_id.md",
      group: :api,
      description:
        "GET /api/tasks/:id/attachments/:attachment_id downloads one file attached to a Stride task or to one of its comments."
    },
    %{
      slug: "api-get-tasks-id-comments",
      source: "docs/api/get_tasks_id_comments.md",
      group: :api,
      description:
        "GET /api/tasks/:id/comments lists the comments on a Stride task, so an agent can read the questions and notes people left on it."
    },
    %{
      slug: "api-get-tasks-id-dependencies",
      source: "docs/api/get_tasks_id_dependencies.md",
      group: :api,
      description:
        "GET /api/tasks/:id/dependencies returns the full dependency tree of a Stride task: every task that must be done before it can begin."
    },
    %{
      slug: "api-get-tasks-id-dependents",
      source: "docs/api/get_tasks_id_dependents.md",
      group: :api,
      description:
        "GET /api/tasks/:id/dependents lists the tasks that depend on a Stride task and are unblocked once that task is completed."
    },
    %{
      slug: "api-get-tasks-id-tree",
      source: "docs/api/get_tasks_id_tree.md",
      group: :api,
      description:
        "GET /api/tasks/:id/tree returns a Stride task, usually a goal, with all of its child tasks in one hierarchical tree."
    },
    %{
      slug: "api-get-tasks-next",
      source: "docs/api/get_tasks_next.md",
      group: :api,
      description:
        "GET /api/tasks/next returns the next available task in the Ready column that matches the capabilities of the agent asking for work."
    },
    %{
      slug: "api-patch-tasks-id",
      source: "docs/api/patch_tasks_id.md",
      group: :api,
      description:
        "PATCH /api/tasks/:id updates the fields of an existing Stride task, such as its key files, testing strategy or acceptance criteria."
    },
    %{
      slug: "api-patch-tasks-id-after-goal",
      source: "docs/api/patch_tasks_id_after_goal.md",
      group: :api,
      description:
        "PATCH /api/tasks/:id/after_goal reports the result of the after_goal hook an agent ran when the last task of a goal was completed."
    },
    %{
      slug: "api-patch-tasks-id-complete",
      source: "docs/api/patch_tasks_id_complete.md",
      group: :api,
      description:
        "PATCH /api/tasks/:id/complete marks a claimed Stride task finished, with its hook results, review report and a summary of the work."
    },
    %{
      slug: "api-patch-tasks-id-mark-done",
      source: "docs/api/patch_tasks_id_mark_done.md",
      group: :api,
      description:
        "PATCH /api/tasks/:id/mark_done moves a Stride task from the Review column straight to Done, bypassing the normal review process."
    },
    %{
      slug: "api-patch-tasks-id-mark-reviewed",
      source: "docs/api/patch_tasks_id_mark_reviewed.md",
      group: :api,
      description:
        "PATCH /api/tasks/:id/mark_reviewed records the outcome of reviewing a Stride task: approved, changes requested or rejected."
    },
    %{
      slug: "api-post-tasks",
      source: "docs/api/post_tasks.md",
      group: :api,
      description:
        "POST /api/tasks creates a Stride work task, defect or goal, with its key files, dependencies, tests and acceptance criteria."
    },
    %{
      slug: "api-post-tasks-batch",
      source: "docs/api/post_tasks_batch.md",
      group: :api,
      description:
        "POST /api/tasks/batch creates several Stride goals and their child tasks in a single request, so an agent can upload a whole plan."
    },
    %{
      slug: "api-post-tasks-claim",
      source: "docs/api/post_tasks_claim.md",
      group: :api,
      description:
        "POST /api/tasks/claim reserves a Stride task for an agent and returns the before_doing hook the agent runs before it starts work."
    },
    %{
      slug: "api-post-tasks-id-comments",
      source: "docs/api/post_tasks_id_comments.md",
      group: :api,
      description:
        "POST /api/tasks/:id/comments adds a comment to a Stride task, so an agent can ask a question or leave a note for the people on it."
    },
    %{
      slug: "api-post-tasks-id-unclaim",
      source: "docs/api/post_tasks_id_unclaim.md",
      group: :api,
      description:
        "POST /api/tasks/:id/unclaim releases a task an agent claimed, moving it back to the Ready column and unassigning it from the agent."
    },
    %{
      slug: "api-put-tasks-id-changed-files",
      source: "docs/api/put_tasks_id_changed_files.md",
      group: :api,
      description:
        "PUT /api/tasks/:id/changed_files uploads the per-file diff snapshot of a Stride task, which reviewers see next to the finished work."
    }
  ]

  # Repository path -> slug, for the link rewriter. "docs/api" is the API
  # directory itself, which guides link to as `api/`.
  @published @catalog |> Map.new(&{&1.source, &1.slug}) |> Map.put("docs/api", "api")

  # The unpublished repository directories the guides link to, so the link
  # rewriter sends them to GitHub's `tree` view; every other unpublished path
  # gets `blob`. The release build has no docs/, test/ or root files to look
  # at, so this is written down rather than read from disk. The docs
  # controller test fails when a guide links to a directory missing here, and
  # test/kanban_web/docs_test.exs when an entry is no longer a linked
  # directory. No guide links to one today.
  @directories MapSet.new([])

  for %{source: source} <- @catalog do
    @external_resource Path.expand("../../priv/" <> source, __DIR__)
  end

  @pages (for entry <- @catalog do
            # The path comes from the allow-list above, never from a request.
            # sobelow_skip ["Traversal.FileModule"]
            markdown = ("../../priv/" <> entry.source) |> Path.expand(__DIR__) |> File.read!()
            rendered = Renderer.render(markdown, entry.source, @published, @directories)

            prefix = if entry.group == :api, do: "Stride API: ", else: ""

            entry
            |> Map.merge(rendered)
            |> Map.put(:page_title, prefix <> rendered.title)
          end)

  @by_slug Map.new(@pages, &{&1.slug, &1})

  @doc """
  Every published page, in catalog order.
  """
  @spec pages() :: [page()]
  def pages, do: @pages

  @doc """
  The published pages in `group`, in catalog order.
  """
  @spec pages(group()) :: [page()]
  def pages(group), do: Enum.filter(@pages, &(&1.group == group))

  @doc """
  Looks a slug up in the allow-list. Any other value, including a path, is
  `:error`.
  """
  @spec fetch(String.t()) :: {:ok, page()} | :error
  def fetch(slug), do: Map.fetch(@by_slug, slug)

  @doc """
  Repository path of each published file, as listed in the allow-list.
  """
  @spec source_paths() :: [String.t()]
  def source_paths, do: Enum.map(@catalog, & &1.source)

  @doc """
  Repository path -> slug map the link rewriter resolves links against.
  """
  @spec published() :: %{String.t() => String.t()}
  def published, do: @published

  @doc """
  The unpublished repository directories the guides link to, which the link
  rewriter sends to GitHub's `tree` view.
  """
  @spec directories() :: MapSet.t(String.t())
  def directories, do: @directories

  @doc """
  The paths `/sitemap.xml` lists for the docs: the index and every page.
  """
  @spec sitemap_paths() :: [String.t()]
  def sitemap_paths, do: ["/docs" | Enum.map(@catalog, &("/docs/" <> &1.slug))]

  @doc """
  The GitHub URL of a page's source file.
  """
  @spec github_source_url(page()) :: String.t()
  def github_source_url(%{source: source}),
    do: MarketingClosing.github_url() <> "/blob/main/" <> source
end
