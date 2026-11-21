defmodule KanbanWeb.LlmsTxt do
  @moduledoc """
  Builds `/llms.txt` (W2900), which `KanbanWeb.SeoController` serves, so that
  AI assistants that read it describe Stride correctly and can follow its
  links to the docs.

  It follows the llms.txt convention (llmstxt.org): an H1 with the name, a
  blockquote summary, a paragraph of detail, then `##` sections of Markdown
  links, the last one named `Optional` for pages an assistant can skip.

  Every link is built from something that exists, so no unshipped page is
  linked: the guides and the API reference from the `KanbanWeb.Docs`
  allow-list, the runtime pages from `KanbanWeb.Integrations.all/0`, the plan
  prices from `KanbanWeb.Pricing.plans/0`, a fixed list of public pages whose
  descriptions come from `KanbanWeb.PageController.seo/1`, the release feed,
  and the two public API documents, the agent onboarding endpoint and the
  OpenAPI document (`KanbanWeb.RobotsTxt.public_api_paths/0`).
  `test/kanban_web/controllers/llms_txt_test.exs` requests every link and
  fails unless it answers 200. Every URL is absolute, built by
  `KanbanWeb.SeoComponents.canonical_url/1` from the endpoint URL, never from
  the request, and only public pages and those two API documents are listed,
  never an authenticated API path.

  The file is in English whatever the request, like the guides it links: the
  translated strings it reuses (the default description, the runtime
  taglines and the price labels) are read in the `"en"` locale.
  """

  alias KanbanWeb.Docs
  alias KanbanWeb.Integrations
  alias KanbanWeb.PageController
  alias KanbanWeb.Pricing
  alias KanbanWeb.SeoComponents

  @doc """
  The body of `/llms.txt`, as Markdown text.
  """
  @spec body() :: String.t()
  def body do
    Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
      IO.iodata_to_binary([
        "# Stride\n\n",
        "> ",
        SeoComponents.default_description(),
        "\n\n",
        detail(),
        "\n\n",
        Enum.map(sections(), &section/1)
      ])
    end)
  end

  @doc """
  Every URL `/llms.txt` links, in the order it links them.
  """
  @spec urls() :: [String.t()]
  def urls do
    Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
      for {_heading, links} <- sections(), {_title, url, _note} <- links, do: url
    end)
  end

  defp detail do
    runtimes = Integrations.all() |> Enum.map(& &1.name) |> join_names()

    "Humans write and prioritise tasks on a board. AI agents find and claim " <>
      "tasks through the Stride REST API, run the project's lifecycle hooks " <>
      "from a `.stride.md` file on their own machine, and complete the work, " <>
      "which goes to a human for review when the task needs it. A new agent " <>
      "can read the onboarding endpoint with no token. Stride plugins add the " <>
      "workflow to " <> runtimes <> "."
  end

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp sections do
    [
      {"Docs", docs_links()},
      {"API", api_links()},
      {"Integrations", integration_links()},
      {"Optional", optional_links()}
    ]
  end

  defp docs_links do
    guides =
      for page <- Docs.pages(:guide) do
        {page.title, url("/docs/" <> page.slug), page.description}
      end

    guides ++ [{"All guides", url("/docs"), "Every published guide and the REST API reference."}]
  end

  defp api_links do
    {:ok, reference} = Docs.fetch("api")

    [
      {reference.title, url("/docs/" <> reference.slug), reference.description},
      {"Agent onboarding", url("/api/agent/onboarding"),
       "JSON with the setup steps, file templates and hooks a new agent needs. No token required."},
      {"OpenAPI document", url("/api/openapi.json"),
       "The OpenAPI description of the Stride REST API."}
    ]
  end

  defp integration_links do
    runtimes =
      for runtime <- Integrations.all() do
        {"Stride for " <> runtime.name, url("/integrations/" <> runtime.slug), runtime.tagline}
      end

    runtimes ++
      [
        {"All integrations", url("/integrations"),
         "What each Stride plugin adds and the command that installs it."}
      ]
  end

  defp optional_links do
    [
      {"Product", url("/product"), page_description(:product)},
      {"Workflows", url("/workflows"), page_description(:workflows)},
      {"Pricing", url("/pricing"), "Plans: " <> plan_summary() <> "."},
      {"Security", url("/security"), page_description(:security)},
      {"Changelog", url("/changelog"), page_description(:changelog)},
      {"Release feed", url("/changelog/feed.xml"), "An Atom feed of the releases."}
    ]
  end

  defp page_description(page),
    do: page |> PageController.seo() |> Keyword.fetch!(:meta_description)

  defp plan_summary, do: Enum.map_join(Pricing.plans(), "; ", &plan_text/1)

  defp plan_text(%{amount: nil, name: name}), do: name <> ", priced on request"

  defp plan_text(%{unit: :user_month, name: name} = plan),
    do: name <> ", " <> Pricing.price_label(plan) <> " per user per month"

  defp plan_text(%{name: name} = plan), do: name <> ", " <> Pricing.price_label(plan)

  defp section({heading, links}) do
    ["## ", heading, "\n\n", Enum.map(links, &link/1), "\n"]
  end

  defp link({title, url, note}), do: ["- [", title, "](", url, "): ", note, "\n"]

  defp url(path), do: SeoComponents.canonical_url(path)
end
