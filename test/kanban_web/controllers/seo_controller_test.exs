defmodule KanbanWeb.SeoControllerTest do
  @moduledoc """
  Guards /robots.txt per host and /sitemap.xml (W2891), and the headers
  /llms.txt shares with them (W2900).
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Endpoint
  alias KanbanWeb.ResourcesLive.HowToData
  alias KanbanWeb.RobotsTxt
  alias KanbanWeb.SeoController
  alias KanbanWeb.SeoXML
  alias KanbanWeb.TokenPaths

  @sitemaps_ns "http://www.sitemaps.org/schemas/sitemap/0.9"

  @disallow_all "User-agent: *\nDisallow: /\n"

  # The router's public PageController pages. A new one fails "lists every
  # public page" until SeoXML.public_paths/0 lists it too.
  @page_paths KanbanWeb.Router
              |> Phoenix.Router.routes()
              |> Enum.filter(&(&1.plug == KanbanWeb.PageController and &1.verb == :get))
              |> Enum.map(& &1.path)

  @private_prefixes ~w(/users /api /boards /admin /invitations /oauth /locked /notifications)

  defp canonical(conn), do: %{conn | host: Endpoint.host()}

  defp parse!(xml) do
    {:ok, root} = Saxy.SimpleForm.parse_string(xml)
    root
  end

  defp locs(xml) do
    {"urlset", _attrs, urls} = parse!(xml)

    for {"url", _, children} <- urls, {"loc", _, [loc]} <- children, do: loc
  end

  defp absolute(paths), do: Enum.map(paths, &(Endpoint.url() <> &1))

  defp sitemap_locs(conn), do: conn |> get(~p"/sitemap.xml") |> response(200) |> locs()

  describe "GET /robots.txt" do
    test "robots.txt on the canonical host allows crawling, disallows /api/ and names the sitemap",
         %{conn: conn} do
      conn = conn |> canonical() |> get(~p"/robots.txt")

      body = response(conn, 200)

      assert String.starts_with?(body, "User-agent: *\nDisallow: /api/\n\n")
      assert String.ends_with?(body, "\n\nSitemap: #{Endpoint.url()}/sitemap.xml\n")
      assert body == RobotsTxt.canonical()

      assert response_content_type(conn, :text) =~ "text/plain"
    end

    test "robots.txt on the canonical host ignores case and the port" do
      for url <- ["http://LOCALHOST/robots.txt", "http://LocalHost:8080/robots.txt"] do
        body = build_conn() |> get(url) |> response(200)
        assert body =~ "Disallow: /api/\n"
        assert body =~ "Sitemap: "
      end
    end

    test "robots.txt on any other host disallows everything" do
      for host <- ["www.example.com", "kanban-prod.fly.dev", "localhost.evil.com", "127.0.0.1"] do
        body = %{build_conn() | host: host} |> get(~p"/robots.txt") |> response(200)

        assert body == @disallow_all
        refute body =~ host
      end
    end

    test "robots.txt on the endpoint host of a deployment that is not indexable disallows everything",
         %{conn: conn} do
      # The review app: PHX_HOST makes it its own endpoint host, but
      # SEO_INDEXABLE is not set there.
      previous = Application.get_env(:kanban, SeoController)
      on_exit(fn -> Application.put_env(:kanban, SeoController, previous) end)

      for config <- [[indexable: false], [], [indexable: "true"]] do
        Application.put_env(:kanban, SeoController, config)
        assert conn |> canonical() |> get(~p"/robots.txt") |> response(200) == @disallow_all
      end
    end
  end

  describe "GET /sitemap.xml" do
    test "sitemap.xml lists every public page and every published how-to with absolute URLs",
         %{conn: conn} do
      how_to_paths = Enum.map(HowToData.all_how_tos(), &("/resources/" <> &1.id))

      expected =
        absolute(
          @page_paths ++
            ["/issue", "/resources", "/demo"] ++
            KanbanWeb.Docs.sitemap_paths() ++
            KanbanWeb.Integrations.sitemap_paths() ++
            KanbanWeb.Comparisons.sitemap_paths() ++ how_to_paths
        )

      locs = sitemap_locs(conn)

      assert Enum.sort(locs) == Enum.sort(expected)
      assert length(locs) == length(Enum.uniq(locs))
      assert Enum.all?(locs, &String.starts_with?(&1, Endpoint.url() <> "/"))
    end

    test "sitemap.xml lists no token, account or signed-in path", %{conn: conn} do
      for loc <- sitemap_locs(conn) do
        path = URI.parse(loc).path

        refute TokenPaths.token_path?(path)
        refute Enum.any?(@private_prefixes, &String.starts_with?(path, &1)), path

        page = build_conn() |> get(path)
        assert get_resp_header(page, "x-robots-tag") == [], path
        refute html_response(page, 200) =~ ~s(<meta name="robots" content="noindex), path
      end
    end

    test "sitemap.xml is well-formed XML served as application/xml", %{conn: conn} do
      conn = get(conn, ~p"/sitemap.xml")
      body = response(conn, 200)

      assert response_content_type(conn, :xml) =~ "application/xml"
      assert String.starts_with?(body, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      assert {"urlset", [{"xmlns", @sitemaps_ns}], _urls} = parse!(body)
    end

    test "sitemap.xml escapes every value it writes" do
      id = ~s(a&b<c>"d'e)
      xml = SeoXML.sitemap([%{id: id}])

      refute xml =~ id
      assert xml |> locs() |> List.last() == Endpoint.url() <> "/resources/" <> id
    end

    test "an empty how-to list still yields a valid sitemap of the public pages" do
      assert locs(SeoXML.sitemap([])) == absolute(SeoXML.public_paths())
    end

    test "every loc in the sitemap answers 200 when requested", %{conn: conn} do
      for loc <- sitemap_locs(conn) do
        assert build_conn() |> get(URI.parse(loc).path) |> response(200), loc
      end
    end
  end

  describe "HEAD, caching and the static file" do
    test "HEAD /robots.txt, HEAD /sitemap.xml and HEAD /llms.txt answer 200 with no body",
         %{conn: conn} do
      for path <- ["/robots.txt", "/sitemap.xml", "/llms.txt"] do
        conn = head(conn, path)

        assert response(conn, 200) == ""
        assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
      end
    end

    test "the response sets no cookie", %{conn: conn} do
      for path <- [~p"/robots.txt", ~p"/sitemap.xml", ~p"/llms.txt"] do
        assert get_resp_header(get(conn, path), "set-cookie") == []
      end
    end

    test "the responses carry a content security policy that allows nothing", %{conn: conn} do
      for path <- [~p"/robots.txt", ~p"/sitemap.xml", ~p"/llms.txt"] do
        assert get_resp_header(get(conn, path), "content-security-policy") ==
                 ["default-src 'none'; frame-ancestors 'none'"]
      end
    end

    test "robots.txt is no longer a static file" do
      refute "robots.txt" in KanbanWeb.static_paths()
      refute :kanban |> Application.app_dir("priv/static/robots.txt") |> File.exists?()
    end
  end
end
