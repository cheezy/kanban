defmodule KanbanWeb.ChangelogFeedTest do
  @moduledoc """
  Guards the Atom feed of releases at /changelog/feed.xml, its rel=alternate
  link on /changelog, and the changelog parse both are built from (W2896).
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.Changelog
  alias KanbanWeb.ChangelogFeed
  alias KanbanWeb.Endpoint
  alias KanbanWeb.PageHTML
  alias KanbanWeb.SeoComponents

  @atom_ns "http://www.w3.org/2005/Atom"

  defp parse!(xml) do
    {:ok, root} = Saxy.SimpleForm.parse_string(xml)
    root
  end

  defp elements(children), do: for({_, _, _} = element <- children, do: element)

  defp child(children, name), do: children |> elements() |> Enum.find(&match?({^name, _, _}, &1))

  defp text({_, _, content}), do: content |> Enum.filter(&is_binary/1) |> Enum.join()

  defp attrs({_, attrs, _}), do: Map.new(attrs)

  defp entries(xml) do
    {"feed", _attrs, children} = parse!(xml)
    for {"entry", _, _} = entry <- elements(children), do: entry
  end

  defp entry_link({_, _, children}),
    do: children |> child("link") |> attrs() |> Map.fetch!("href")

  defp feed_xml(conn), do: conn |> get(~p"/changelog/feed.xml") |> response(200)

  defp section(heading, notes) do
    ~s(      <section class="mb-10">\n        <h2\n          class="m-0"\n        >\n          #{heading}\n        </h2>\n#{notes}\n      </section>\n)
  end

  defp release(version, date, notes),
    do: %{
      version: version,
      date: Date.from_iso8601!(date),
      anchor: Changelog.anchor(version),
      notes: notes
    }

  describe "Changelog.parse/1" do
    test "gives each release section an id and returns the dated releases in order" do
      html =
        section("[Unreleased]", "<p>soon</p>") <>
          section("[1.1.0] - 2026-02-03", ~s(<ul class="list-disc"><li>Two</li></ul>)) <>
          section("[1.0.0] - 2026-01-02", "<p>One</p>")

      %{body: body, releases: releases} = Changelog.parse(html)

      assert body =~ ~s(<section class="mb-10" id="unreleased">)
      assert body =~ ~s(<section class="mb-10" id="release-1-1-0">)
      assert body =~ ~s(<section class="mb-10" id="release-1-0-0">)
      refute body =~ ~s(<section class="mb-10">)

      assert releases == [
               release("1.1.0", "2026-02-03", ~s(<ul class="list-disc"><li>Two</li></ul>)),
               release("1.0.0", "2026-01-02", "<p>One</p>")
             ]
    end

    test "keeps everything but the section tags exactly as written" do
      html = section("[1.0.0] - 2026-01-02", "<p>One &amp; two</p>")
      %{body: body} = Changelog.parse(html)

      assert String.replace(body, ~s( id="release-1-0-0"), "") == html
    end

    test "an undated version gets an id but no feed entry, and an odd heading neither" do
      html = section("[2.0.0]", "<p>Undated</p>") <> section("Notes", "<p>Other</p>")
      %{body: body, releases: releases} = Changelog.parse(html)

      assert body =~ ~s(id="release-2-0-0")
      assert length(Regex.scan(~r/ id="/, body)) == 1
      assert releases == []
    end

    test "an impossible date is not a release" do
      assert %{releases: []} = "[1.0.0] - 2026-02-30" |> section("<p>x</p>") |> Changelog.parse()
    end

    test "an empty body yields no releases" do
      assert Changelog.parse("") == %{body: "", releases: []}
    end

    test "anchor/1 turns the version's dots into dashes" do
      assert Changelog.anchor("3.2.0") == "release-3-2-0"
    end
  end

  describe "the feed" do
    test "/changelog/feed.xml has one entry per release with version, date and link",
         %{conn: conn} do
      releases = PageHTML.changelog_releases()
      entries = conn |> feed_xml() |> entries()

      assert [_ | _] = releases
      assert length(entries) == length(releases)

      for {{"entry", _, children} = entry, release} <- Enum.zip(entries, releases) do
        date = Date.to_iso8601(release.date) <> "T00:00:00Z"
        url = Endpoint.url() <> "/changelog#" <> release.anchor

        assert text(child(children, "title")) == "Stride " <> release.version
        assert text(child(children, "updated")) == date
        assert text(child(children, "published")) == date
        assert text(child(children, "id")) == url
        assert entry_link(entry) == url
        assert attrs(child(children, "content")) == %{"type" => "html"}
      end
    end

    test "the feed is valid Atom with absolute URLs", %{conn: conn} do
      conn = get(conn, ~p"/changelog/feed.xml")
      xml = response(conn, 200)

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))

      {"feed", feed_attrs, children} = parse!(xml)
      assert {"xmlns", @atom_ns} in feed_attrs
      assert {"xml:base", Endpoint.url() <> "/"} in feed_attrs

      for name <- ~w(id title updated author) do
        assert child(children, name), "the feed has no <#{name}>"
      end

      newest = PageHTML.changelog_releases() |> hd()
      assert text(child(children, "updated")) == Date.to_iso8601(newest.date) <> "T00:00:00Z"
      assert text(child(children, "id")) == Endpoint.url() <> "/changelog"

      links = for {"link", _, _} = link <- elements(children), do: attrs(link)

      assert %{"rel" => "self", "href" => Endpoint.url() <> "/changelog/feed.xml"} in Enum.map(
               links,
               &Map.take(&1, ["rel", "href"])
             )

      assert %{"rel" => "alternate", "href" => Endpoint.url() <> "/changelog"} in Enum.map(
               links,
               &Map.take(&1, ["rel", "href"])
             )

      hrefs = Enum.map(links, & &1["href"]) ++ (xml |> entries() |> Enum.map(&entry_link/1))

      for href <- hrefs do
        assert %URI{scheme: scheme, host: host} = URI.parse(href)
        assert scheme in ["http", "https"] and is_binary(host) and host != "", href
      end
    end

    test "an empty changelog still yields a valid feed" do
      {"feed", attrs, children} = parse!(ChangelogFeed.atom([]))

      assert {"xmlns", @atom_ns} in attrs
      assert text(child(children, "updated")) == "1970-01-01T00:00:00Z"
      assert text(child(children, "title")) == "Stride releases"
      assert entries(ChangelogFeed.atom([])) == []
    end

    test "release notes are escaped, so an ampersand or angle bracket cannot add markup" do
      notes = ~s(<p class="x" style="color: red">Fish &amp; chips <code>&lt;b&gt;</code></p>)
      xml = ChangelogFeed.atom([release("1.0.0", "2026-01-02", notes)])

      [{"entry", _, children}] = entries(xml)
      content = child(children, "content")

      assert elements(elem(content, 2)) == []
      assert text(content) == "<p>Fish &amp; chips <code>&lt;b&gt;</code></p>"
      refute xml =~ "<p>"
      refute xml =~ "<code>"
    end

    test "attributes on their own lines are dropped with the space before the >" do
      notes = ~s{<h3\n  class="m-0"\n  style="color: var(--ink);"\n>Added</h3><a href="/x">x</a>}

      [{"entry", _, children}] =
        entries(ChangelogFeed.atom([release("1.0.0", "2026-01-02", notes)]))

      assert text(child(children, "content")) == ~s(<h3>Added</h3><a href="/x">x</a>)
    end

    test "a version cannot inject markup into an entry" do
      xml = ChangelogFeed.atom([release("1.0.0<x>", "2026-01-02", "")])

      [{"entry", _, children}] = entries(xml)
      assert text(child(children, "title")) == "Stride 1.0.0<x>"
    end

    test "HEAD /changelog/feed.xml answers 200 with no body", %{conn: conn} do
      conn = head(conn, ~p"/changelog/feed.xml")

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "an Atom Accept header is served, and no cookie is set", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/atom+xml")
        |> get(~p"/changelog/feed.xml")

      assert response(conn, 200)
      assert get_resp_header(conn, "set-cookie") == []

      assert get_resp_header(conn, "content-security-policy") ==
               ["default-src 'none'; frame-ancestors 'none'"]
    end
  end

  describe "the feed and the page" do
    test "the page and the feed list the same releases", %{conn: conn} do
      page_versions =
        conn
        |> get(~p"/changelog")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-changelog] section h2")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
        |> Enum.flat_map(
          # Only dated releases are feed entries, so an undated version on the
          # page is not expected in the feed.
          &(Regex.run(~r/^\[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}$/, &1, capture: :all_but_first) ||
              [])
        )

      feed_versions =
        for {"entry", _, children} <- conn |> feed_xml() |> entries(),
            do: children |> child("title") |> text() |> String.replace_prefix("Stride ", "")

      assert feed_versions == page_versions
    end

    test "every entry link resolves to an anchor on /changelog", %{conn: conn} do
      document = conn |> get(~p"/changelog") |> html_response(200) |> LazyHTML.from_document()

      ids =
        document
        |> LazyHTML.query("[data-changelog] section[id]")
        |> LazyHTML.attribute("id")

      assert ids == Enum.uniq(ids), "two changelog sections share an id"

      for link <- conn |> feed_xml() |> entries() |> Enum.map(&entry_link/1) do
        %URI{path: path, fragment: fragment} = URI.parse(link)

        assert path == "/changelog"
        assert fragment in ids, "#{link} names no section on /changelog"
      end
    end

    test "the changelog page links the feed with a rel=alternate tag", %{conn: conn} do
      document = conn |> get(~p"/changelog") |> html_response(200) |> LazyHTML.from_document()
      link = LazyHTML.query(document, ~s(head link[rel="alternate"][type="application/atom+xml"]))

      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "href") == [Endpoint.url() <> "/changelog/feed.xml"]
      assert LazyHTML.attribute(link, "title") == ["Stride releases"]
    end

    test "other pages carry no feed link", %{conn: conn} do
      for path <- [~p"/", ~p"/about", ~p"/pricing"] do
        body = conn |> get(path) |> html_response(200)
        refute body =~ "application/atom+xml", path
      end
    end
  end

  describe "seo_head/1 feed link" do
    test "is left out without a feed_path" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SeoComponents.seo_head path="/changelog" />
        """)

      refute html =~ ~s(rel="alternate")
    end

    test "makes the feed path absolute" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SeoComponents.seo_head feed_path="/changelog/feed.xml" feed_title="Feed" />
        """)

      assert html =~ ~s(href="#{Endpoint.url()}/changelog/feed.xml")
      assert html =~ ~s(title="Feed")
    end
  end
end
