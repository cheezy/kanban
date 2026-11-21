defmodule KanbanWeb.DocsControllerTest do
  @moduledoc """
  The published guides at /docs and /docs/:slug (W2898).
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Docs
  alias KanbanWeb.Docs.Renderer

  @github "https://github.com/cheezy/kanban"
  @raw "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/"

  defp hrefs(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main a[href]")
    |> LazyHTML.attribute("href")
  end

  defp ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[id]")
    |> LazyHTML.attribute("id")
    |> MapSet.new()
  end

  defp page_html(conn, slug), do: conn |> get(~p"/docs/#{slug}") |> html_response(200)

  describe "GET /docs" do
    test "/docs lists the published guides", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      for page <- Docs.pages() do
        assert html =~ ~s(href="/docs/#{page.slug}"), page.slug
      end

      linked = html |> hrefs() |> Enum.filter(&String.starts_with?(&1, "/docs/"))
      assert Enum.sort(linked) == Docs.pages() |> Enum.map(&("/docs/" <> &1.slug)) |> Enum.sort()

      refute html =~ "security-findings"
      refute html =~ "/plans"
      refute html =~ "runbook"
    end

    test "/docs renders under the marketing layout with a title and description", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      # Inside .stride-marketing, where the design tokens the page uses resolve.
      inside_marketing =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(".stride-marketing main[data-docs-index]")

      assert Enum.count(inside_marketing) == 1
      assert html =~ ~r/<title[^>]*>\s*Stride documentation/
      assert html =~ ~s(<meta name="description" content="Guides for running AI coding agents)
    end

    test "/docs translates its chrome", %{conn: conn} do
      html =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> get(~p"/docs")
        |> html_response(200)

      assert html =~ "Référence de"
      refute html =~ "API reference"
    end
  end

  describe "GET /docs/:slug" do
    test "/docs/:slug renders a guide's markdown as HTML", %{conn: conn} do
      {:ok, page} = Docs.fetch("ai-workflow")
      html = page_html(conn, "ai-workflow")

      assert html =~ "<table>"
      assert html =~ ~s(class="language-)
      assert html =~ ~s(<h2 id=")
      assert html =~ "<h1 id=\"ai-workflow-integration-guide\">AI Workflow Integration Guide"
      assert html =~ ~r/<title[^>]*>\s*AI Workflow Integration Guide/
      assert html =~ ~s(<meta name="description" content="#{page.description})
      assert html =~ ~s(href="#{@github}/blob/main/docs/AI-WORKFLOW.md")
    end

    test "relative links between published guides are rewritten to /docs paths", %{conn: conn} do
      getting_started = page_html(conn, "getting-started-with-ai")
      assert getting_started =~ ~s(href="/docs/api-post-tasks-batch")
      refute getting_started =~ ~s(href="./api/post_tasks_batch.md")

      assert page_html(conn, "ai-workflow") =~ ~s(href="/docs/api")
      assert page_html(conn, "api-get-agent-onboarding") =~ ~s(href="/docs/ai-workflow")
      assert page_html(conn, "api-post-tasks-claim") =~ ~r{href="/docs/api(#[^"]*)?"}
    end

    test "a link to an unpublished doc points at GitHub", %{conn: conn} do
      getting_started = page_html(conn, "getting-started-with-ai")

      assert getting_started =~ ~s(href="#{@github}/blob/main/docs/TASK-WRITING-GUIDE.md")
      assert getting_started =~ ~s(href="#{@github}/blob/main/CHANGELOG.md")
      assert page_html(conn, "api") =~ ~s(href="#{@github}/blob/main/docs/api/me_boards.md")
    end

    test "an unknown slug answers 404", %{conn: conn} do
      for slug <- ["nope", "README", "api-me-boards", "security-findings", "..%2Fplans", "MCP.md"] do
        body = build_conn() |> get("/docs/" <> slug) |> html_response(404)

        assert length(String.split(body, "<!DOCTYPE")) == 2, "#{slug}: one document"
        refute body =~ "stride-docs-prose"
      end

      assert conn |> get("/docs/api/README.md") |> response(404)
    end

    test "raw HTML in a guide is escaped", %{conn: conn} do
      %{html: html} =
        Renderer.render("# T\n\n<script>alert(1)</script>\n", "docs/MCP.md", Docs.published())

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script"

      for page <- Docs.pages() do
        body = page_html(conn, page.slug)
        [article] = Regex.run(~r/<article.*?<\/article>/s, body)
        refute article =~ "<script", page.slug
      end
    end

    test "a heading anchor link within the same guide is kept", %{conn: conn} do
      html = page_html(conn, "mcp")
      [article] = Regex.run(~r/<article.*?<\/article>/s, html)

      # docs/MCP.md links to its own Errors section in the body text.
      assert article =~ ~s(<a href="#errors">Errors</a>)
      assert html |> ids() |> MapSet.member?("errors")
    end

    test "every table-of-contents entry points at a heading on the page", %{conn: conn} do
      for page <- Docs.pages(), page.toc != [] do
        page_ids = ids(page_html(conn, page.slug))
        assert Enum.all?(page.toc, &MapSet.member?(page_ids, &1.id)), page.slug
      end
    end
  end

  describe "links" do
    test "every link on every published guide resolves", %{conn: conn} do
      pages = Map.new(Docs.pages(), &{&1.slug, page_html(conn, &1.slug)})
      page_ids = Map.new(pages, fn {slug, html} -> {slug, ids(html)} end)
      published_sources = MapSet.new(Docs.source_paths())

      for {slug, html} <- pages, href <- hrefs(html) do
        check_link(href, slug, page_ids, published_sources)
      end
    end
  end

  defp check_link("#" <> fragment, slug, page_ids, _published) do
    assert MapSet.member?(page_ids[slug], fragment), "/docs/#{slug}: no id for ##{fragment}"
  end

  defp check_link("/docs" <> _ = href, slug, page_ids, _published) do
    %URI{path: path, fragment: fragment} = URI.parse(href)

    case path do
      "/docs" ->
        :ok

      "/docs/" <> target ->
        assert Map.has_key?(page_ids, target), "/docs/#{slug} links to unpublished #{href}"

        if fragment,
          do: assert(MapSet.member?(page_ids[target], fragment), "/docs/#{slug}: #{href}")
    end
  end

  defp check_link(@github <> rest = href, slug, _page_ids, published) do
    case Regex.run(~r{^/(blob|tree)/main/([^#?]+)}, rest) do
      [_, kind, encoded] ->
        check_github_path(kind, URI.decode(encoded), href, slug, published)

      nil ->
        assert rest in ["", "/issues"], "/docs/#{slug}: unexpected GitHub link #{href}"
    end
  end

  # A raw GitHub URL is written by hand, so the rewriter never sees it as a
  # link to a guide. One that names a published guide skips its /docs page.
  defp check_link(@raw <> path = href, slug, _page_ids, published) do
    refute MapSet.member?(published, path |> URI.parse() |> Map.fetch!(:path)),
           "/docs/#{slug} sends #{href} to raw GitHub instead of its /docs page"
  end

  defp check_link(href, slug, _page_ids, _published) do
    scheme = URI.parse(href).scheme
    assert scheme in ["http", "https", "mailto"], "/docs/#{slug} renders the link #{href}"
  end

  defp check_github_path(kind, path, href, slug, published) do
    exists = if kind == "blob", do: File.regular?(path), else: File.dir?(path)

    assert exists,
           "/docs/#{slug} links to #{href}, which names no #{kind} in the repo" <>
             if(kind == "blob" and File.dir?(path),
               do: ". It is a directory: add #{path} to @directories in KanbanWeb.Docs",
               else: ""
             )

    # The page's own "View this page on GitHub" link is the one GitHub link to
    # a published file.
    {:ok, page} = Docs.fetch(slug)

    refute MapSet.member?(published, path) and path != page.source,
           "/docs/#{slug} sends #{href} to GitHub"
  end
end
