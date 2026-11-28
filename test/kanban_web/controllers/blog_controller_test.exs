defmodule KanbanWeb.BlogControllerTest do
  @moduledoc """
  The flag-gated blog experiment at /blog and /blog/:slug (W2951).

  Feature flags are stored through the sandboxed repo with the cache off in
  test, so toggling `:blog` here never leaks into another test.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.FeatureFlags
  alias KanbanWeb.Blog

  @slugs ~w(tw-retreat-response how-much)
  @paths ["/blog" | Enum.map(@slugs, &("/blog/" <> &1))]
  @noindex ["noindex, nofollow"]

  defp document(html), do: LazyHTML.from_document(html)

  defp query(html, selector), do: html |> document() |> LazyHTML.query(selector)

  defp attributes(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name)

  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp none?(html, selector), do: html |> query(selector) |> Enum.empty?()

  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp assert_not_found(conn, path) do
    conn = get(conn, path)
    html = html_response(conn, 404)

    # Like every other public 404: no x-robots-tag that would tell the hidden
    # experiment apart from a URL that does not exist.
    assert get_resp_header(conn, "x-robots-tag") == []

    # The normal 404 page, not the marketing layout or a blog page.
    assert html =~ "Page not found" or html =~ "404"
    assert none?(html, ".stride-marketing")
    assert none?(html, "[data-blog-index], [data-blog-post]")
    html
  end

  describe "with :blog off" do
    test "both pages answer 404 to a signed-out visitor", %{conn: conn} do
      for path <- @paths, do: assert_not_found(conn, path)
    end

    test "both pages answer 404 to a signed-in visitor", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      for path <- @paths, do: assert_not_found(conn, path)
    end

    test "POST /blog answers 404 rather than crashing" do
      assert build_conn() |> post("/blog") |> response(404)
    end
  end

  describe "with :blog on for one user" do
    test "that user sees both pages and other visitors get 404", %{conn: conn} do
      previewer = user_fixture()
      other = user_fixture()
      :ok = FeatureFlags.enable_for_user(:blog, previewer)

      previewer_conn = log_in_user(build_conn(), previewer)

      for path <- @paths do
        assert previewer_conn |> get(path) |> html_response(200)
      end

      other_conn = log_in_user(build_conn(), other)

      for path <- @paths do
        assert_not_found(other_conn, path)
        assert_not_found(conn, path)
      end
    end
  end

  describe "with :blog on for everyone" do
    setup do
      :ok = FeatureFlags.enable_for_everyone(:blog)
      :ok
    end

    test "/blog lists both posts newest first with title, date, author, avatar, tags and description",
         %{conn: conn} do
      html = conn |> get(~p"/blog") |> html_response(200)

      assert count(html, ".stride-marketing main[data-blog-index]") == 1
      assert attributes(html, "[data-blog-link]", "data-blog-link") == @slugs
      assert attributes(html, "[data-blog-link]", "href") == Enum.map(@slugs, &("/blog/" <> &1))

      for post <- Blog.posts() do
        card = html |> document() |> LazyHTML.query(~s([data-blog-link="#{post.slug}"]))
        card_html = LazyHTML.to_html(card)
        author = KanbanWeb.BlogHTML.post_author(post)

        assert card_html =~ escaped(post.title)
        assert card_html =~ escaped(author.name)
        assert card_html =~ ~s(src="#{author.avatar}")

        assert card_html =~
                 escaped(post.description)

        assert card |> LazyHTML.query("time[datetime]") |> LazyHTML.attribute("datetime") ==
                 [DateTime.to_iso8601(post.date)]

        for tag <- post.tags, do: assert(card_html =~ tag)
      end
    end

    test "each post shows its title, byline with avatar and bio, date, tags, body and a back link",
         %{conn: conn} do
      for slug <- @slugs do
        {:ok, post} = Blog.fetch(slug)
        {:ok, author} = Blog.author(post.author)
        html = conn |> get(~p"/blog/#{slug}") |> html_response(200)

        assert count(html, ".stride-marketing main[data-blog-post]") == 1
        assert text(html, "article h1") =~ post.title
        assert text(html, "[data-blog-author]") == author.name
        assert text(html, "article footer") =~ author.bio
        assert attributes(html, "article footer img", "src") == [author.avatar]
        assert attributes(html, "article footer img", "alt") == [author.name]

        assert attributes(html, "article header time", "datetime") ==
                 [DateTime.to_iso8601(post.date)]

        for tag <- post.tags, do: assert(text(html, "article header") =~ tag)

        assert attributes(html, "article", "lang") == ["en"]
        refute none?(html, "[data-blog-body].stride-docs-prose p")
        assert attributes(html, "[data-blog-back]", "href") == ["/blog"]
      end
    end

    test "/blog/how-much shows both images, lazy-loaded, from /images/blog/", %{conn: conn} do
      html = conn |> get(~p"/blog/how-much") |> html_response(200)
      images = query(html, ~s([data-blog-body] img))

      srcs = LazyHTML.attribute(images, "src")
      assert length(srcs) == 2
      assert Enum.all?(srcs, &String.starts_with?(&1, "/images/blog/"))
      assert images |> LazyHTML.attribute("alt") |> Enum.all?(&(String.trim(&1) != ""))
      assert LazyHTML.attribute(images, "loading") == ["lazy", "lazy"]

      for src <- srcs do
        assert build_conn() |> get(src) |> response(200)
      end
    end

    test "an unknown slug answers 404", %{conn: conn} do
      assert_not_found(conn, "/blog/unknown")
      assert_not_found(conn, "/blog/..%2Fposts")
    end

    test "both pages send noindex and neither is in the sitemap", %{conn: conn} do
      for path <- @paths do
        conn = get(conn, path)
        html = html_response(conn, 200)

        assert attributes(html, ~s(head meta[name="robots"]), "content") == @noindex
        assert get_resp_header(conn, "x-robots-tag") == @noindex
      end

      sitemap = build_conn() |> get(~p"/sitemap.xml") |> response(200)
      refute sitemap =~ "/blog"
    end

    test "the index has a translated title and description", %{conn: conn} do
      html = conn |> get(~p"/blog") |> html_response(200)

      assert html =~ ~r/<title[^>]*>\s*Stride blog/
      assert html =~ ~s(<meta name="description" content="Posts from the Stride team)

      fr =
        build_conn()
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> get(~p"/blog")
        |> html_response(200)

      refute fr =~ "The posts are written in English."
      refute fr =~ ~r/<title[^>]*>\s*Stride blog/
    end

    test "a post's title, description and BlogPosting structured data come from the post",
         %{conn: conn} do
      {:ok, post} = Blog.fetch("how-much")
      html = conn |> get(~p"/blog/how-much") |> html_response(200)

      escaped_title = escaped(post.title)
      assert html =~ ~r/<title[^>]*>\s*#{Regex.escape(escaped_title)}/

      assert attributes(html, ~s(meta[name="description"]), "content") == [post.description]

      [script] =
        html |> query(~s(script[type="application/ld+json"])) |> Enum.to_list()

      assert [_nonce] = LazyHTML.attribute(script, "nonce")
      data = script |> LazyHTML.text() |> Jason.decode!()

      assert data["@type"] == "BlogPosting"
      assert data["headline"] == post.title
      assert data["author"]["name"] == "Jeff \"Cheezy\" Morgan"
      assert data["url"] =~ "/blog/how-much"
    end

    for locale <- ~w(ja zh) do
      test "the #{locale} chrome is translated while the post body stays English", %{conn: conn} do
        html =
          conn
          |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
          |> get(~p"/blog/how-much")
          |> html_response(200)

        refute text(html, "[data-blog-back]") =~ "All posts"
        refute text(html, "article footer") =~ "Written by"
        assert attributes(html, "article", "lang") == ["en"]
        assert text(html, "[data-blog-body]") =~ "developer"
      end
    end

    test "turning the flag off answers 404 on the next request", %{conn: conn} do
      assert conn |> get(~p"/blog/how-much") |> html_response(200)

      :ok = FeatureFlags.disable_for_everyone(:blog)

      assert_not_found(build_conn(), "/blog/how-much")
    end
  end
end
