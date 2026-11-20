defmodule KanbanWeb.PageControllerSeoTest do
  @moduledoc """
  Guards the page_title and meta_description of every public page (W2889).

  The PageController pages are found by walking the router, so a new public
  action that renders without its own title and description fails here rather
  than shipping with the shared default.
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.ResourcesLive.HowToData
  alias KanbanWeb.ResourcesLive.Seo
  alias KanbanWeb.SeoComponents

  @locales ~w(de en es fr ja pt zh)

  @page_paths KanbanWeb.Router
              |> Phoenix.Router.routes()
              |> Enum.filter(&(&1.plug == KanbanWeb.PageController and &1.verb == :get))
              |> Enum.map(& &1.path)
              |> Enum.sort()

  defp head_attr(document, selector, attribute) do
    document |> LazyHTML.query("head " <> selector) |> LazyHTML.attribute(attribute)
  end

  # The bare page_title (og:title carries no suffix), the browser <title> and
  # the meta description of the page at `path`.
  defp seo(conn, path) do
    document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
    [title] = head_attr(document, ~s(meta[property="og:title"]), "content")
    [description] = head_attr(document, ~s(meta[name="description"]), "content")

    browser_title =
      document
      |> LazyHTML.query("head title")
      |> LazyHTML.text()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    %{title: title, browser_title: browser_title, description: description}
  end

  defp in_locale(conn, locale), do: Plug.Test.init_test_session(conn, %{"locale" => locale})

  defp default_description(locale),
    do: Gettext.with_locale(KanbanWeb.Gettext, locale, &SeoComponents.default_description/0)

  test "the router walk finds every public page, so the guard cannot pass empty" do
    assert length(@page_paths) >= 12
    assert "/pricing" in @page_paths
    assert "/HitMe" in @page_paths
    refute Enum.any?(@page_paths, &String.contains?(&1, ":"))
  end

  test "every public PageController action sets a non-empty page_title and meta_description",
       %{conn: conn} do
    for path <- @page_paths do
      %{title: title, browser_title: browser_title, description: description} = seo(conn, path)

      assert title not in ["", "Stride"], "#{path} has no page_title"
      assert browser_title == title <> " · Task Management", "#{path} <title> is #{browser_title}"

      assert description != default_description("en"),
             "#{path} falls back to the default description"
    end
  end

  test "no two public pages share a title or a description", %{conn: conn} do
    for locale <- @locales do
      pages =
        Enum.map(@page_paths ++ ["/resources"], &{&1, conn |> in_locale(locale) |> seo(&1)})

      for key <- [:title, :description] do
        duplicates =
          pages
          |> Enum.group_by(fn {_path, values} -> Map.fetch!(values, key) end, &elem(&1, 0))
          |> Enum.filter(fn {_value, paths} -> length(paths) > 1 end)

        assert duplicates == [], "#{locale} pages share a #{key}: #{inspect(duplicates)}"
      end
    end
  end

  test "every description is between 70 and 160 characters in English", %{conn: conn} do
    for path <- @page_paths ++ ["/resources"] do
      length = conn |> seo(path) |> Map.fetch!(:description) |> String.length()
      assert length in 70..160, "#{path} description is #{length} characters"
    end
  end

  test "every description is translated and at most 160 characters in every locale", %{
    conn: conn
  } do
    for locale <- @locales, path <- @page_paths ++ ["/resources"] do
      %{description: description} = conn |> in_locale(locale) |> seo(path)

      assert String.length(description) <= 160,
             "#{locale} #{path} description is #{String.length(description)} characters"

      assert description != default_description(locale),
             "#{locale} #{path} falls back to the default description"
    end
  end

  test "the pricing page title and description render in French when the locale is fr", %{
    conn: conn
  } do
    english = seo(conn, "/pricing")
    french = conn |> in_locale("fr") |> seo("/pricing")

    assert french.title == "Tarifs"

    assert french.description ==
             "Comparez les offres Stride pour les particuliers, les petites équipes et " <>
               "les grandes organisations, et ce que chacune inclut en membres, tableaux et support."

    refute french.description == english.description
  end

  test "a signed-in visitor sees the same titles as a signed-out one", %{conn: conn} do
    signed_out = Enum.map(["/", "/pricing", "/about"], &seo(conn, &1))
    %{conn: signed_in_conn} = register_and_log_in_user(%{conn: build_conn()})
    signed_in = Enum.map(["/", "/pricing", "/about"], &seo(signed_in_conn, &1))

    assert Enum.map(signed_in, &Map.take(&1, [:title, :description])) ==
             Enum.map(signed_out, &Map.take(&1, [:title, :description]))
  end

  test "/HitMe keeps its existing title", %{conn: conn} do
    assert seo(conn, "/HitMe").title == "Half-day AI proof-of-concept sessions"
  end

  test "the resources index sets its own description", %{conn: conn} do
    assert seo(conn, "/resources").description == Seo.resources_description()
  end

  test "a resources how-to page uses its own title and summary as the description", %{
    conn: conn
  } do
    {:ok, how_to} = HowToData.get_how_to("creating-your-first-board")
    page = seo(conn, "/resources/creating-your-first-board")

    assert page.title == how_to.title
    assert page.description == how_to.description

    longest = Enum.max_by(HowToData.all_how_tos(), &String.length(&1.description))
    assert String.length(longest.description) > 160
    shortened = seo(conn, "/resources/" <> longest.id).description

    assert String.length(shortened) <= 160
    assert String.ends_with?(shortened, "…")
    assert String.starts_with?(longest.description, String.trim_trailing(shortened, "…"))

    # A how-to with no summary falls back to the resources index description.
    assert Seo.how_to_meta_description(%{how_to | description: ""}) ==
             Seo.resources_description()
  end

  test "a missing how-to id still renders a Not Found title with the default description", %{
    conn: conn
  } do
    page = seo(conn, "/resources/no-such-guide")

    assert page.title == "Not Found"
    assert page.description == default_description("en")
  end
end
