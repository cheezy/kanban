defmodule KanbanWeb.DocsTest do
  @moduledoc """
  Guards the published-guides catalog, its priv/docs copies, the link
  rewriter and the renderer (W2898).

  KanbanWeb.Docs renders every guide at compile time, which cover does not
  count, so the Links and Renderer functions are exercised directly here.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Docs
  alias KanbanWeb.Docs.Links
  alias KanbanWeb.Docs.Renderer

  @github "https://github.com/cheezy/kanban"
  @published %{
    "docs/MCP.md" => "mcp",
    "docs/AI-WORKFLOW.md" => "ai-workflow",
    "docs/api/README.md" => "api",
    "docs/api/post_tasks_batch.md" => "api-post-tasks-batch",
    "docs/api" => "api"
  }

  describe "catalog" do
    test "every slug is unique and a flat lower-case slug" do
      slugs = Enum.map(Docs.pages(), & &1.slug)

      assert slugs == Enum.uniq(slugs)
      assert Enum.all?(slugs, &Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, &1))
    end

    test "every page has a unique title and a unique 70 to 160 character description" do
      pages = Docs.pages()

      for page <- pages do
        length = String.length(page.description)
        assert length in 70..160, "#{page.slug}: description is #{length} characters"
        assert page.title != ""
      end

      assert pages |> Enum.map(& &1.page_title) |> Enum.uniq() |> length() == length(pages)
      assert pages |> Enum.map(& &1.description) |> Enum.uniq() |> length() == length(pages)
    end

    test "every published source exists in docs/" do
      for source <- Docs.source_paths() do
        assert String.starts_with?(source, "docs/")
        assert File.regular?(source), "#{source} is on the allow-list but not in docs/"
      end
    end

    test "no security, plan, runbook or other internal doc is on the allow-list" do
      internal = ~r/security-findings|plans\/|runbook|ideation|superpowers|validation|blog/i

      for source <- Docs.source_paths() do
        refute Regex.match?(internal, source), "#{source} must not be published"
      end
    end

    test "fetch/1 looks slugs up in the allow-list and never resolves a path" do
      assert {:ok, %{source: "docs/MCP.md"}} = Docs.fetch("mcp")

      for slug <- ["MCP.md", "docs/MCP.md", "../mcp", "README", "api-me-boards", ""] do
        assert Docs.fetch(slug) == :error
      end
    end

    test "pages/1 splits the guides from the API reference, in catalog order" do
      assert :guide |> Docs.pages() |> Enum.map(& &1.slug) == [
               "getting-started-with-ai",
               "ai-workflow",
               "mcp",
               "authentication",
               "agent-hook-execution-guide"
             ]

      assert [%{slug: "api"} | rest] = Docs.pages(:api)
      assert Enum.all?(rest, &String.starts_with?(&1.slug, "api-"))
      assert length(Docs.pages()) == length(Docs.pages(:guide)) + length(Docs.pages(:api))
    end

    test "API pages are titled with their endpoint; guides with their heading" do
      {:ok, mcp} = Docs.fetch("mcp")
      {:ok, claim} = Docs.fetch("api-post-tasks-claim")

      assert mcp.page_title == mcp.title
      assert claim.page_title == "Stride API: POST /api/tasks/claim"
    end

    test "sitemap_paths/0 lists the index and every page" do
      assert ["/docs" | rest] = Docs.sitemap_paths()
      assert rest == Enum.map(Docs.pages(), &("/docs/" <> &1.slug))
    end

    test "published/0 maps every source and the api directory to its slug" do
      published = Docs.published()

      assert published["docs/api"] == "api"
      assert Enum.all?(Docs.pages(), &(published[&1.source] == &1.slug))
    end

    test "github_source_url/1 points at the page's source on GitHub" do
      {:ok, page} = Docs.fetch("ai-workflow")
      assert Docs.github_source_url(page) == @github <> "/blob/main/docs/AI-WORKFLOW.md"
    end
  end

  describe "priv/docs copies" do
    test "every published guide's priv/docs copy matches its source in docs/" do
      stale =
        for source <- Docs.source_paths(),
            copy = "priv/" <> source,
            not File.regular?(copy) or File.read!(copy) != File.read!(source),
            do: "cp #{source} #{copy}"

      assert stale == [],
             "priv/docs is out of date with docs/. Run:\n" <>
               Enum.join(stale, "\n") <> "\n(then recompile so KanbanWeb.Docs picks it up)"
    end

    test "priv/docs holds only the allow-listed guides" do
      on_disk =
        "priv/docs/**/*"
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()

      assert on_disk == Docs.source_paths() |> Enum.map(&("priv/" <> &1)) |> Enum.sort()
    end
  end

  describe "Links.rewrite/3" do
    test "keeps same-page anchors and http, https and mailto links" do
      for url <- [
            "#claiming-a-task",
            "https://example.org/x",
            "http://localhost:4000",
            "mailto:a@b.c"
          ] do
        assert Links.rewrite(url, "docs/MCP.md", @published) == {:ok, url}
      end
    end

    test "maps links between published guides onto /docs paths, keeping the anchor" do
      cases = [
        {"MCP.md", "docs/AI-WORKFLOW.md", "/docs/mcp"},
        {"./MCP.md#tools", "docs/AI-WORKFLOW.md", "/docs/mcp#tools"},
        {"api/post_tasks_batch.md", "docs/AI-WORKFLOW.md", "/docs/api-post-tasks-batch"},
        {"../AI-WORKFLOW.md#x", "docs/api/README.md", "/docs/ai-workflow#x"},
        {"README.md", "docs/api/post_tasks_batch.md", "/docs/api"},
        {"api/", "docs/AI-WORKFLOW.md", "/docs/api"},
        {"/docs/api", "docs/AI-WORKFLOW.md", "/docs/api"},
        {"./api/README.md#batch", "docs/MCP.md", "/docs/api#batch"}
      ]

      for {url, from, expected} <- cases do
        assert Links.rewrite(url, from, @published) == {:ok, expected}, url
      end
    end

    test "points links to unpublished files and directories at GitHub" do
      cases = [
        {"TASK-WRITING-GUIDE.md", "docs/AI-WORKFLOW.md", "/blob/main/docs/TASK-WRITING-GUIDE.md"},
        {"../CHANGELOG.md", "docs/AI-WORKFLOW.md", "/blob/main/CHANGELOG.md"},
        {"me_boards.md#list", "docs/api/README.md", "/blob/main/docs/api/me_boards.md#list"},
        {"../plans/X.md", "docs/api/README.md", "/blob/main/docs/plans/X.md"},
        {"../lib/kanban", "docs/AI-WORKFLOW.md", "/tree/main/lib/kanban"},
        {"../../lib/kanban/tasks.ex", "docs/api/README.md", "/blob/main/lib/kanban/tasks.ex"},
        {"My%20Doc.md", "docs/MCP.md", "/blob/main/docs/My%20Doc.md"}
      ]

      for {url, from, path} <- cases do
        assert Links.rewrite(url, from, @published) == {:ok, @github <> path}, url
      end
    end

    test "a link to the repository root points at the repository" do
      assert Links.rewrite("../", "docs/MCP.md", @published) == {:ok, @github}
    end

    test "keeps a link with only a query string as it is" do
      assert Links.rewrite("?tab=1", "docs/MCP.md", @published) == {:ok, "?tab=1"}
    end

    test "drops other schemes, scheme-relative hosts and paths above the root" do
      for url <- [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "data:text/html,x",
            "user:ID",
            "//evil.example",
            "../../x.md",
            "/../x.md"
          ] do
        assert Links.rewrite(url, "docs/MCP.md", @published) == :drop, url
      end
    end
  end

  describe "Renderer.render/3" do
    test "renders headings with GitHub ids, a title and a table of contents" do
      rendered =
        Renderer.render(
          "# The `Title`\n\n## First part\n\ntext\n\n## Second\n",
          "docs/MCP.md",
          @published
        )

      assert rendered.title == "The Title"

      assert rendered.toc == [
               %{id: "first-part", text: "First part"},
               %{id: "second", text: "Second"}
             ]

      assert rendered.html =~ ~s(<h2 id="first-part">)
    end

    test "lists level-three headings when a guide has fewer than two level-two headings" do
      rendered =
        Renderer.render("# T\n\n## Only\n\n### One\n\n### Two\n", "docs/MCP.md", @published)

      assert rendered.toc == [%{id: "one", text: "One"}, %{id: "two", text: "Two"}]
    end

    test "every published page has an outline of at least two sections" do
      for page <- Docs.pages() do
        assert length(page.toc) >= 2, "#{page.slug} has no outline"
      end
    end

    test "escapes raw HTML instead of rendering it" do
      %{html: html} =
        Renderer.render(
          "# T\n\n<script>alert(1)</script>\n\nA <b onclick=\"x()\">b</b>\n",
          "docs/MCP.md",
          @published
        )

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script"
      refute html =~ "<b onclick"
    end

    test "rewrites links and flattens dropped ones to their text" do
      %{html: html} =
        Renderer.render(
          "# T\n\n[guide](MCP.md#tools) [far](//evil.example/x) [odd](user:7) [ref][r]\n\n[r]: ../CHANGELOG.md\n",
          "docs/AI-WORKFLOW.md",
          @published
        )

      assert html =~ ~s(<a href="/docs/mcp#tools">guide</a>)
      assert html =~ ~s(<a href="#{@github}/blob/main/CHANGELOG.md">ref</a>)
      assert html =~ " far odd "
      refute html =~ "evil.example"
      refute html =~ "user:7"
    end

    test "leaves link-like text inside code alone" do
      %{html: html} =
        Renderer.render(
          "# T\n\n`[x](MCP.md)`\n\n```\n[y](MCP.md)\n```\n",
          "docs/AI-WORKFLOW.md",
          @published
        )

      assert html =~ "[x](MCP.md)"
      assert html =~ "[y](MCP.md)"
      refute html =~ "/docs/mcp"
    end

    test "renders a nested fence inside a longer outer fence as one code block" do
      %{html: html} =
        Renderer.render(
          "# T\n\n````markdown\n```bash\necho hi\n```\n````\n",
          "docs/MCP.md",
          @published
        )

      assert length(Regex.scan(~r/<pre/, html)) == 1
      assert html =~ "```bash"
    end

    test "renders tables" do
      %{html: html} =
        Renderer.render("# T\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", "docs/MCP.md", @published)

      assert html =~ "<table>"
      assert html =~ "<td>2</td>"
    end

    test "raises when a guide has no level-one heading" do
      assert_raise ArgumentError, ~r/no level-one heading/, fn ->
        Renderer.render("## Only h2\n", "docs/MCP.md", @published)
      end
    end

    test "raises when a guide contains an image" do
      assert_raise ArgumentError, ~r/contains an image/, fn ->
        Renderer.render("# T\n\n![x](pic.png)\n", "docs/MCP.md", @published)
      end
    end

    test "options/0 never enables unsafe rendering" do
      refute get_in(Renderer.options(), [:render, :unsafe])
      assert get_in(Renderer.options(), [:render, :escape]) == true
    end
  end
end
