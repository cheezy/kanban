defmodule KanbanWeb.LlmsTxtTest do
  @moduledoc """
  Guards /llms.txt and the AI crawler groups in /robots.txt (W2900).
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Docs
  alias KanbanWeb.Endpoint
  alias KanbanWeb.Integrations
  alias KanbanWeb.LlmsTxt
  alias KanbanWeb.PageController
  alias KanbanWeb.Pricing
  alias KanbanWeb.RobotsTxt
  alias KanbanWeb.SeoComponents
  alias KanbanWeb.TokenPaths

  @link ~r/^- \[[^\]]+\]\(([^)\s]+)\): \S/m

  defp canonical(conn), do: %{conn | host: Endpoint.host()}

  defp llms_txt(conn), do: conn |> get(~p"/llms.txt") |> response(200)

  defp links(body), do: for([_, url] <- Regex.scan(@link, body), do: url)

  # The robots.txt group whose User-agent line names `user_agent`, as its
  # lines.
  defp group(body, user_agent) do
    body
    |> String.split("\n\n")
    |> Enum.map(&(&1 |> String.split("\n", trim: true) |> Enum.reject(fn l -> l =~ ~r/^#/ end)))
    |> Enum.find(&match?(["User-agent: " <> ^user_agent | _], &1))
  end

  describe "GET /llms.txt" do
    test "/llms.txt is plain text with a title, a summary and links to the docs and onboarding",
         %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")
      body = response(conn, 200)

      assert response_content_type(conn, :text) =~ "text/plain"
      assert String.starts_with?(body, "# Stride\n\n> #{SeoComponents.default_description()}\n\n")

      for heading <- ["Docs", "API", "Integrations", "Optional"] do
        assert body =~ "\n## #{heading}\n\n", heading
      end

      urls = links(body)

      for page <- Docs.pages(:guide) do
        assert (Endpoint.url() <> "/docs/" <> page.slug) in urls, page.slug
        assert body =~ page.description
      end

      for runtime <- Integrations.all() do
        assert (Endpoint.url() <> "/integrations/" <> runtime.slug) in urls, runtime.slug
        assert body =~ runtime.name
      end

      {init, [last]} = Integrations.all() |> Enum.map(& &1.name) |> Enum.split(-1)
      assert body =~ "Stride plugins add the workflow to #{Enum.join(init, ", ")} and #{last}."

      assert (Endpoint.url() <> "/docs/api") in urls
      assert (Endpoint.url() <> "/api/agent/onboarding") in urls
      assert (Endpoint.url() <> "/api/openapi.json") in urls
    end

    test "every link in llms.txt is absolute and answers 200", %{conn: conn} do
      urls = conn |> llms_txt() |> links()

      assert urls == LlmsTxt.urls()
      assert length(urls) == length(Enum.uniq(urls))

      for url <- urls do
        assert String.starts_with?(url, Endpoint.url() <> "/"), url

        path = URI.parse(url).path
        assert build_conn() |> get(path) |> response(200), url
      end
    end

    test "llms.txt links only public pages and the public API documents", %{conn: conn} do
      for url <- conn |> llms_txt() |> links() do
        path = URI.parse(url).path

        refute TokenPaths.token_path?(path), path

        if String.starts_with?(path, "/api/") do
          assert path in RobotsTxt.public_api_paths(), path
        end

        refute Enum.any?(
                 ~w(/users /boards /admin /invitations /oauth),
                 &String.starts_with?(path, &1)
               ),
               path
      end
    end

    test "llms.txt states the plan prices from KanbanWeb.Pricing", %{conn: conn} do
      body = llms_txt(conn)

      for %{name: name} = plan <- Pricing.plans() do
        if is_integer(plan.amount) do
          assert body =~ name <> ", " <> Pricing.price_label(plan)
        else
          assert body =~ name <> ", priced on request"
        end
      end

      assert body =~ "Organization, $12 CAD per user per month"
    end

    test "llms.txt reuses the descriptions the linked pages give themselves", %{conn: conn} do
      body = llms_txt(conn)

      for page <- [:product, :workflows, :security, :changelog] do
        assert body =~ page |> PageController.seo() |> Keyword.fetch!(:meta_description),
               "#{page}"
      end
    end

    test "llms.txt is the same on every host and in English in every locale", %{conn: conn} do
      expected = conn |> canonical() |> llms_txt()

      for host <- ["www.example.com", "kanban-prod.fly.dev"] do
        body = llms_txt(%{build_conn() | host: host})

        assert body == expected
        refute body =~ host
      end

      # The request runs in the test process, so it starts in this locale.
      Gettext.put_locale(KanbanWeb.Gettext, "fr")

      assert llms_txt(build_conn()) == expected
    end
  end

  describe "the AI crawler groups in /robots.txt" do
    test "robots.txt on the canonical host names the AI crawlers according to the configured policy",
         %{conn: conn} do
      body = conn |> canonical() |> get(~p"/robots.txt") |> response(200)

      assert body == RobotsTxt.canonical(RobotsTxt.ai_crawler_policy())
      assert RobotsTxt.ai_crawler_policy() == :allow
      assert body =~ "# AI crawlers: allowed"

      for user_agent <- RobotsTxt.ai_crawlers() do
        assert group(body, user_agent) == [
                 "User-agent: " <> user_agent,
                 "Allow: /api/agent/onboarding",
                 "Allow: /api/openapi.json",
                 "Disallow: /api/"
               ]
      end

      # Non-canonical hosts still disallow everything, AI crawlers included.
      for host <- ["www.example.com", "kanban-prod.fly.dev"] do
        other = %{build_conn() | host: host} |> get(~p"/robots.txt") |> response(200)

        assert other == "User-agent: *\nDisallow: /\n"
        refute Enum.any?(RobotsTxt.ai_crawlers(), &(other =~ &1))
      end
    end

    test "the AI crawler list names the four crawlers the policy covers" do
      assert RobotsTxt.ai_crawlers() == ~w(GPTBot ClaudeBot PerplexityBot Google-Extended)
    end

    test "the :disallow policy gives every AI crawler Disallow: / and keeps the other rules" do
      body = RobotsTxt.canonical(:disallow)

      assert String.starts_with?(body, "User-agent: *\nDisallow: /api/\n\n")
      assert body =~ "# AI crawlers: not allowed."
      assert String.ends_with?(body, "\n\nSitemap: #{Endpoint.url()}/sitemap.xml\n")

      for user_agent <- RobotsTxt.ai_crawlers() do
        assert group(body, user_agent) == ["User-agent: " <> user_agent, "Disallow: /"]
      end
    end
  end
end
