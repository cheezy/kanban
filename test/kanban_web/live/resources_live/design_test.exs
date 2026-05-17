defmodule KanbanWeb.ResourcesLive.DesignTest do
  @moduledoc """
  Regression guard for the Resources design conversion (W643/W644/W645).

  Every Resources page now uses Tailwind utility classes + daisyUI theme
  tokens instead of inline styles + project-specific CSS variables. If a
  future template edit reintroduces hardcoded grey/white classes or
  drops the theme tokens we converted to, these tests fail.

  Notes on scope:

    * The Resources page templates (W643/W644/W645) are converted; the
      `Layouts.app` wrapper they render inside is NOT yet converted and
      still emits `var(--ink)` / `var(--surface)` / `var(--stride-orange)`
      strings in its sidebar and topbar. So we cannot meaningfully assert
      absence of those CSS variables on the full rendered HTML.

    * Instead we assert (a) the theme tokens introduced by the conversion
      are PRESENT, and (b) the dark-mode-forbidden hardcoded colour classes
      from CLAUDE.md (`text-gray-*`, `bg-white`, `border-gray-*`) are
      absent. A regression that reintroduces those classes into a Resources
      template will fail these tests; a regression that inlines a `style=`
      with CSS variables won't — that'd need a separate guard once the
      layout chrome is converted too.

    * /resources/:id's body still calls three helpers (how_to_content,
      completion_message, how_to_navigation) that haven't been converted
      yet — those still emit inline styles, which is why we don't assert
      against `style=` substrings here either.
  """

  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @theme_token_markers ["text-base-content", "bg-base-100", "border-base-300"]
  @forbidden_dark_mode_classes [
    "text-gray-900",
    "text-gray-600",
    "text-gray-500",
    "bg-white",
    "bg-gray-50",
    "border-gray-200"
  ]

  defp assert_theme_tokens_present(html, page_label) do
    for marker <- @theme_token_markers do
      assert html =~ marker,
             "Expected #{page_label} to render the theme token #{inspect(marker)} " <>
               "after the Tailwind conversion, but it was missing."
    end
  end

  defp refute_forbidden_classes(html, page_label) do
    for klass <- @forbidden_dark_mode_classes do
      refute html =~ klass,
             "Expected #{page_label} to be free of #{inspect(klass)} per the " <>
               "dark-mode color map in CLAUDE.md, but it was present."
    end
  end

  describe "Resources index (/resources)" do
    test "renders with theme tokens and no forbidden grey/white classes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/resources")

      assert_theme_tokens_present(html, "/resources")
      refute_forbidden_classes(html, "/resources")
    end

    test "renders the converted page chrome (search, tag filter, sort)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/resources")

      assert html =~ "How-Tos"
      assert html =~ ~s(name="query")
      assert html =~ ~s(name="sort_by")
    end
  end

  describe "Resources show (/resources/:id)" do
    test "renders with theme tokens and no forbidden grey/white classes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert_theme_tokens_present(html, "/resources/:id")
      refute_forbidden_classes(html, "/resources/:id")
    end

    test "not-found state also uses theme tokens", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/resources/nonexistent-guide")

      assert html =~ "text-base-content"
      refute html =~ "text-gray-900"
      refute html =~ "bg-white"
    end
  end
end
