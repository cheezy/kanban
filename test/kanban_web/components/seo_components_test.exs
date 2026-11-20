defmodule KanbanWeb.SeoComponentsTest do
  @moduledoc """
  Contract tests for `KanbanWeb.SeoComponents.seo_head/1` and its helpers.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.SeoComponents

  @english_description "Stride is a kanban board where humans and AI agents plan, claim and ship work together."

  defp render_head(attrs) do
    assigns = %{attrs: Map.new(attrs)}

    rendered_to_string(~H"""
    <SeoComponents.seo_head {@attrs} />
    """)
  end

  defp attr_of(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  defp base, do: KanbanWeb.Endpoint.url()

  describe "seo_head/1 — happy path" do
    test "renders description, canonical, og and twitter tags from the assigns" do
      html =
        render_head(
          title: "Pricing",
          description: "Plans for teams",
          path: "/pricing",
          locale: "en"
        )

      assert attr_of(html, ~s(meta[name="description"]), "content") == ["Plans for teams"]
      assert attr_of(html, ~s(link[rel="canonical"]), "href") == [base() <> "/pricing"]
      assert attr_of(html, ~s(meta[property="og:url"]), "content") == [base() <> "/pricing"]
      assert attr_of(html, ~s(meta[property="og:type"]), "content") == ["website"]
      assert attr_of(html, ~s(meta[property="og:site_name"]), "content") == ["Stride"]
      assert attr_of(html, ~s(meta[property="og:title"]), "content") == ["Pricing"]
      assert attr_of(html, ~s(meta[property="og:description"]), "content") == ["Plans for teams"]
      assert attr_of(html, ~s(meta[property="og:locale"]), "content") == ["en_US"]
      assert attr_of(html, ~s(meta[name="twitter:card"]), "content") == ["summary_large_image"]
      assert attr_of(html, ~s(meta[name="twitter:title"]), "content") == ["Pricing"]
      assert attr_of(html, ~s(meta[name="twitter:description"]), "content") == ["Plans for teams"]

      assert attr_of(html, ~s(meta[name="theme-color"]), "content") == ["#f8f8f8", "#151618"]

      assert attr_of(html, ~s(meta[name="theme-color"]), "media") == [
               "(prefers-color-scheme: light)",
               "(prefers-color-scheme: dark)"
             ]

      default_image = base() <> "/images/og/stride-og.png"
      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [default_image]
      assert attr_of(html, ~s(meta[name="twitter:image"]), "content") == [default_image]
      assert attr_of(html, ~s(meta[name="keywords"]), "content") == []
    end

    test "renders og:image and twitter:image when an image is given" do
      html = render_head(path: "/", og_image: "https://cdn.test/og.png")

      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [
               "https://cdn.test/og.png"
             ]

      assert attr_of(html, ~s(meta[name="twitter:image"]), "content") == [
               "https://cdn.test/og.png"
             ]

      fragment = LazyHTML.from_fragment(html)
      assert fragment |> LazyHTML.query(~s(meta[property="og:image:width"])) |> Enum.empty?()
      assert fragment |> LazyHTML.query(~s(meta[property="og:image:alt"])) |> Enum.empty?()
    end
  end

  describe "seo_head/1 — canonical" do
    test "canonical drops the query string, so ?locale=fr and utm params point at the bare path" do
      html = render_head(path: "/pricing?locale=fr&utm_source=x")

      assert attr_of(html, ~s(link[rel="canonical"]), "href") == [base() <> "/pricing"]
      assert attr_of(html, ~s(meta[property="og:url"]), "content") == [base() <> "/pricing"]
      refute html =~ "utm_source"
      refute html =~ "locale=fr"
    end

    test "canonical drops a fragment and a trailing slash, but keeps the root path" do
      assert SeoComponents.canonical_url("/pricing#faq") == base() <> "/pricing"
      assert SeoComponents.canonical_url("/pricing/") == base() <> "/pricing"
      assert SeoComponents.canonical_url("/pricing//") == base() <> "/pricing"
      assert SeoComponents.canonical_url("//resources") == base() <> "/resources"

      assert SeoComponents.canonical_url("/resources//getting-started") ==
               base() <> "/resources/getting-started"

      assert SeoComponents.canonical_url("//") == base() <> "/"
      assert SeoComponents.canonical_url("/") == base() <> "/"
      assert SeoComponents.canonical_url("/?utm_source=x") == base() <> "/"
    end

    test "canonical is omitted for a path with a dot segment" do
      for path <- ["/resources/..", "/resources/.", "/resources/%2e%2e", "/resources/%2E%2E/x"] do
        assert SeoComponents.canonical_url(path) == nil
      end

      assert SeoComponents.canonical_url("/resources/v1.2") == base() <> "/resources/v1.2"
    end

    test "canonical keeps percent-encoded characters byte for byte" do
      assert SeoComponents.canonical_url("/resources/caf%C3%A9") ==
               base() <> "/resources/caf%C3%A9"
    end

    test "canonical and og:url are omitted when there is no usable path" do
      for path <- [nil, "", "pricing", "https://evil.test/x"] do
        html = render_head(path: path)

        assert attr_of(html, ~s(link[rel="canonical"]), "href") == []
        assert attr_of(html, ~s(meta[property="og:url"]), "content") == []
      end
    end

    test "canonical and og:url are omitted on a path that carries a secret token" do
      for path <- [
            "/invitations/secret-invite-token",
            "/users/reset-password/secret-reset-token",
            "/users/confirm/secret-confirm-token",
            "/users/settings/confirm-email/secret-email-token",
            "/users//confirm//secret-confirm-token?x=1",
            "/%69nvitations/secret-invite-token",
            "/users/reset%2Dpassword/secret-reset-token",
            "/users/settings/confirm%2Demail/secret-email-token"
          ] do
        html = render_head(path: path)

        assert attr_of(html, ~s(link[rel="canonical"]), "href") == []
        assert attr_of(html, ~s(meta[property="og:url"]), "content") == []
        refute html =~ "secret-"
      end

      assert SeoComponents.canonical_url("/users/confirmation-pending") ==
               base() <> "/users/confirmation-pending"
    end

    test "request_path/1 reads the conn path without the query and is nil-safe" do
      conn = Phoenix.ConnTest.build_conn(:get, "/pricing?locale=fr")

      assert SeoComponents.request_path(conn) == "/pricing"
      assert SeoComponents.request_path(nil) == nil
    end
  end

  describe "seo_head/1 — escaping" do
    test "escapes quotes and angle brackets in a title or description" do
      title = ~s[Tom's "Board" <script>alert(1)</script>]
      description = ~s[A "quoted" <b>bold</b> description]

      html = render_head(title: title, description: description, path: "/")

      refute html =~ "<script>"
      refute html =~ "<b>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "&quot;Board&quot;"

      assert attr_of(html, ~s(meta[property="og:title"]), "content") == [title]
      assert attr_of(html, ~s(meta[name="twitter:title"]), "content") == [title]
      assert attr_of(html, ~s(meta[name="description"]), "content") == [description]
    end
  end

  describe "seo_head/1 — fallbacks" do
    test "falls back to the default title and the translated default description when the page sets neither" do
      for blank <- [nil, "", "   "] do
        html = render_head(title: blank, description: blank, path: "/", locale: "en")

        assert attr_of(html, ~s(meta[property="og:title"]), "content") == ["Stride"]
        assert attr_of(html, ~s(meta[name="twitter:title"]), "content") == ["Stride"]
        assert attr_of(html, ~s(meta[name="description"]), "content") == [@english_description]

        assert attr_of(html, ~s(meta[property="og:description"]), "content") == [
                 @english_description
               ]
      end
    end

    test "the default description is translated in every non-English locale" do
      for locale <- ~w(de es fr ja pt zh) do
        description =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            render_head(path: "/")
            |> attr_of(~s(meta[name="description"]), "content")
          end)

        assert [translated] = description
        assert translated != @english_description, "#{locale} is untranslated"
        assert translated =~ "Stride"
      end
    end

    test "default_description/0 is the English text in the en locale" do
      assert Gettext.with_locale(KanbanWeb.Gettext, "en", &SeoComponents.default_description/0) ==
               @english_description
    end
  end

  describe "seo_head/1 — robots and og:locale" do
    test "emits robots noindex only when the noindex assign is true" do
      html = render_head(path: "/", noindex: true)
      assert attr_of(html, ~s(meta[name="robots"]), "content") == ["noindex, nofollow"]

      for attrs <- [[path: "/"], [path: "/", noindex: false], [path: "/", noindex: nil]] do
        assert attr_of(render_head(attrs), ~s(meta[name="robots"]), "content") == []
      end
    end

    test "og:locale follows the current Gettext locale" do
      expected = %{
        "de" => "de_DE",
        "en" => "en_US",
        "es" => "es_ES",
        "fr" => "fr_FR",
        "ja" => "ja_JP",
        "pt" => "pt_BR",
        "zh" => "zh_CN"
      }

      for {locale, og_locale} <- expected do
        html = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> render_head(path: "/") end)
        assert attr_of(html, ~s(meta[property="og:locale"]), "content") == [og_locale]
      end
    end

    test "an explicit locale wins over the process locale, and unknown locales fall back to en_US" do
      html = Gettext.with_locale(KanbanWeb.Gettext, "de", fn -> render_head(locale: "fr") end)
      assert attr_of(html, ~s(meta[property="og:locale"]), "content") == ["fr_FR"]

      assert SeoComponents.og_locale("xx") == "en_US"
      assert SeoComponents.og_locale(nil) == "en_US"
    end
  end
end
