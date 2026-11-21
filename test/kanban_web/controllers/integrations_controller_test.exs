defmodule KanbanWeb.IntegrationsControllerTest do
  @moduledoc """
  The agent runtime pages at /integrations and /integrations/:runtime (W2899).
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.Integrations

  @locales ~w(de en es fr ja pt zh)

  defp query(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
  end

  defp texts(html, selector) do
    html |> query(selector) |> Enum.map(&LazyHTML.text/1)
  end

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp hrefs(html, selector), do: html |> query(selector) |> LazyHTML.attribute("href")

  defp page_html(conn, slug), do: conn |> get(~p"/integrations/#{slug}") |> html_response(200)

  defp in_locale(conn, locale), do: Plug.Test.init_test_session(conn, %{"locale" => locale})

  describe "GET /integrations" do
    test "/integrations lists every supported agent runtime", %{conn: conn} do
      html = conn |> get(~p"/integrations") |> html_response(200)

      linked = hrefs(html, "main a[data-integration-link]")

      assert linked == Enum.map(Integrations.slugs(), &("/integrations/" <> &1))
      assert length(linked) == 6

      for runtime <- Integrations.all() do
        assert html =~ runtime.name
      end
    end

    test "/integrations renders under the marketing layout with a title and description",
         %{conn: conn} do
      html = conn |> get(~p"/integrations") |> html_response(200)

      assert count(html, ".stride-marketing main[data-integrations-index]") == 1
      assert html =~ ~r/<title[^>]*>\s*Stride integrations for AI coding agents/
      assert html =~ ~s(<meta name="description" content="Stride plugins for Claude Code)
      assert hrefs(html, "main a[href='/docs/getting-started-with-ai']") != []
    end

    test "/integrations translates its chrome", %{conn: conn} do
      html = conn |> in_locale("fr") |> get(~p"/integrations") |> html_response(200)

      assert html =~ "Intégrations Stride pour les agents de code IA"
      assert html =~ "Étapes d&#39;installation"
      refute html =~ "Install steps"
    end
  end

  describe "GET /integrations/:runtime" do
    test "each runtime page shows its install command and marketplace link", %{conn: conn} do
      for runtime <- Integrations.all() do
        html = page_html(conn, runtime.slug)

        assert texts(html, "[data-install-command]") == Enum.map(runtime.install, & &1.command),
               runtime.slug

        assert hrefs(html, "a[data-listing-link]") == [runtime.listing_url]
        assert hrefs(html, "a[data-docs-link]") == [runtime.docs_url]

        for link <- query(html, "a[data-listing-link], a[data-docs-link]") do
          assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer"]
        end

        assert count(html, ".stride-marketing main[data-integration-page]") == 1

        assert html =~
                 ~r/<title[^>]*>\s*#{Regex.escape(Integrations.page_title(runtime))}/

        assert html =~
                 ~s(<meta name="description" content="#{Integrations.meta_description(runtime)}")
      end
    end

    test "each runtime page lists only what that plugin adds", %{conn: conn} do
      html = page_html(conn, "codex")

      assert html =~ "The agent runs your .stride.md commands itself"
      refute html =~ "Runs your .stride.md hook commands automatically"

      html = page_html(conn, "gemini-cli")

      assert html =~ "Extension index"
      assert html =~ "Gemini CLI has no marketplace of its own"

      for slug <- Integrations.slugs(), slug != "pi" do
        assert page_html(conn, slug) =~ "task-enricher", slug
      end
    end

    test "the Codex page says the script installs need the hook registered by hand",
         %{conn: conn} do
      html = page_html(conn, "codex")

      assert texts(html, "[data-install-note]") |> Enum.join() =~ "register it once by hand"

      assert hrefs(html, "a[data-install-note-link]") ==
               ["https://github.com/cheezy/stride-codex#registering-the-hook"]

      assert query(html, "a[data-install-note-link]") |> LazyHTML.attribute("rel") ==
               ["noopener noreferrer"]

      for slug <- Integrations.slugs(), slug != "codex" do
        assert count(page_html(conn, slug), "[data-install-note]") == 0, slug
      end
    end

    test "each runtime page walks through the first task and links the guide", %{conn: conn} do
      html = page_html(conn, "pi")

      assert html =~ "Your first task"
      assert html =~ "/api/agent/onboarding"
      assert hrefs(html, "main a[href='/docs/getting-started-with-ai']") != []
      assert hrefs(html, "main a[href='/integrations']") != []
    end

    test "install commands are not translated in any locale", %{conn: conn} do
      for locale <- @locales, runtime <- Integrations.all() do
        html = conn |> in_locale(locale) |> page_html(runtime.slug)

        assert texts(html, "[data-install-command]") == Enum.map(runtime.install, & &1.command),
               "#{locale} #{runtime.slug}"

        assert count(html, "pre[translate=no]") == length(runtime.install) + 1
      end
    end

    test "a runtime page translates its chrome", %{conn: conn} do
      html = conn |> in_locale("de") |> page_html("claude-code")

      assert html =~ "Stride für Claude Code"
      assert html =~ "Ihre erste Aufgabe"
      refute html =~ "Your first task"
    end

    test "an unknown runtime answers 404", %{conn: conn} do
      for slug <- ["nope", "CODEX", "codex.md", "stride", "%2e%2e"] do
        conn = get(conn, "/integrations/" <> slug)
        assert html_response(conn, 404), slug
      end
    end
  end

  describe "preview_badge/1" do
    test "a runtime in preview shows the badge and one that is not shows nothing" do
      assigns = %{}

      assert rendered_to_string(~H"<KanbanWeb.IntegrationsHTML.preview_badge preview={true} />") =~
               "data-preview-badge"

      assert rendered_to_string(~H"<KanbanWeb.IntegrationsHTML.preview_badge preview={false} />")
             |> String.trim() == ""
    end

    test "listing_label/1 names every listing kind" do
      assert KanbanWeb.IntegrationsHTML.listing_label(:marketplace) == "Marketplace"
      assert KanbanWeb.IntegrationsHTML.listing_label(:extension_index) == "Extension index"
      assert KanbanWeb.IntegrationsHTML.listing_label(:repository) == "Repository"
    end

    test "display_url/1 drops the scheme" do
      assert KanbanWeb.IntegrationsHTML.display_url("https://github.com/cheezy/stride") ==
               "github.com/cheezy/stride"
    end
  end

  describe "the home page" do
    test "the home page links /integrations", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert hrefs(html, "footer a[href='/integrations']") != []
    end
  end
end
