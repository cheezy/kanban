defmodule KanbanWeb.CompareControllerTest do
  @moduledoc """
  The comparison pages at /compare/:competitor (W2901).
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.CompareHTML
  alias KanbanWeb.Comparisons
  alias KanbanWeb.Comparisons.Claim
  alias KanbanWeb.Comparisons.Comparison
  alias KanbanWeb.Integrations
  alias KanbanWeb.LocalTime

  @locales ~w(de en es fr ja pt zh)

  defp query(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
  end

  defp texts(html, selector) do
    html |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp attrs(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp page_html(conn, slug), do: conn |> get(~p"/compare/#{slug}") |> html_response(200)

  defp in_locale(conn, locale), do: Plug.Test.init_test_session(conn, %{"locale" => locale})

  defp sources(%Comparison{better_choice: claims}), do: Enum.flat_map(claims, & &1.sources)

  describe "GET /compare/:competitor" do
    test "/compare/:slug renders each comparison with its last-reviewed date and sources",
         %{conn: conn} do
      for comparison <- Comparisons.all() do
        html = page_html(conn, comparison.slug)

        assert count(html, ".stride-marketing main[data-compare-page='#{comparison.slug}']") == 1
        assert texts(html, "h1[data-compare-heading]") == ["Stride vs #{comparison.competitor}"]

        assert attrs(html, "time[data-last-reviewed]", "datetime") == [
                 LocalTime.utc_iso8601(comparison.last_reviewed)
               ]

        assert texts(html, "time[data-last-reviewed]") == [
                 LocalTime.format(comparison.last_reviewed, :date)
               ]

        assert attrs(html, "a[data-source-link]", "href") == sources(comparison)
        assert count(html, "[data-stride-fits] li") == length(Comparisons.stride_fits())
        assert html =~ "Where #{comparison.competitor} is the better choice"
      end
    end

    test "every comparison lists at least one source link per claim about the other tool",
         %{conn: conn} do
      for comparison <- Comparisons.all() do
        assert comparison.better_choice != []

        for %Claim{sources: sources} <- comparison.better_choice do
          assert sources != []
          assert Enum.all?(sources, &String.starts_with?(&1, "https://"))
        end

        html = page_html(conn, comparison.slug)
        claims = query(html, "li[data-claim]")

        assert Enum.count(claims) == length(comparison.better_choice)

        for claim <- claims do
          links = LazyHTML.query(claim, "a[data-source-link]")
          refute Enum.empty?(links)

          for link <- links do
            assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer"]
            assert LazyHTML.attribute(link, "target") == ["_blank"]
          end
        end

        assert attrs(html, "a[data-corrections-link]", "rel") == ["noopener noreferrer"]
      end
    end

    test "an unknown slug answers 404", %{conn: conn} do
      for slug <- ["nope", "LINEAR", "jira.md", "stride", "trello", "github"] do
        assert conn |> get("/compare/#{slug}") |> html_response(404)
      end
    end

    test "a comparison page translates its copy and keeps product names", %{conn: conn} do
      html = conn |> in_locale("fr") |> page_html("linear")

      assert html =~ "Où Stride a sa place"
      refute html =~ "Where Stride fits"

      for locale <- @locales, comparison <- Comparisons.all() do
        html = build_conn() |> in_locale(locale) |> page_html(comparison.slug)

        assert [heading] = texts(html, "h1[data-compare-heading]")
        assert heading =~ comparison.competitor
        assert attrs(html, "a[data-source-link]", "href") == sources(comparison)
      end
    end

    test "every comparison has a distinct title and a description of the right length in every locale",
         %{conn: conn} do
      for locale <- @locales do
        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          titles = Enum.map(Comparisons.all(), &Comparisons.page_title/1)
          descriptions = Enum.map(Comparisons.all(), &Comparisons.meta_description/1)
          other_titles = Enum.map(Integrations.all(), &Integrations.page_title/1)

          assert Enum.uniq(titles) == titles
          assert Enum.uniq(descriptions) == descriptions
          assert MapSet.disjoint?(MapSet.new(titles), MapSet.new(other_titles))

          for description <- descriptions do
            assert String.length(description) <= 160, "#{locale}: #{description}"
            if locale == "en", do: assert(String.length(description) >= 70)
          end
        end)
      end

      html = page_html(conn, "jira")

      assert html =~ ~r/<title[^>]*>\s*Stride vs Jira for AI agent work/
      assert html =~ ~s(<meta name="description" content="How Stride and Jira compare)
    end
  end

  describe "the footer" do
    test "the footer links each comparison page", %{conn: conn} do
      for path <- ["/" | Comparisons.sitemap_paths()] do
        html = conn |> get(path) |> html_response(200)

        for slug <- Comparisons.slugs() do
          assert attrs(html, "footer a[data-compare-link='#{slug}']", "href") == [
                   "/compare/#{slug}"
                 ],
                 "#{path} does not link /compare/#{slug} from its footer"
        end
      end
    end
  end

  describe "KanbanWeb.Comparisons" do
    test "fetch/1 finds every slug and nothing else" do
      for slug <- Comparisons.slugs() do
        assert {:ok, %Comparison{slug: ^slug}} = Comparisons.fetch(slug)
      end

      assert Comparisons.fetch("trello") == :error
      assert Comparisons.slugs() == Enum.map(Comparisons.footer_links(), &elem(&1, 0))
      assert Comparisons.sitemap_paths() == Enum.map(Comparisons.slugs(), &("/compare/" <> &1))
    end

    test "CompareHTML.display_url/1 drops the scheme and issues_url/0 points at GitHub" do
      assert CompareHTML.display_url("https://linear.app/docs/github") == "linear.app/docs/github"
      assert CompareHTML.issues_url() == "https://github.com/cheezy/kanban/issues"
    end
  end
end
