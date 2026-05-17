defmodule KanbanWeb.ResourcesLive.DesignTest do
  @moduledoc """
  Regression guard for the Resources pages against the Stride design system
  in `design_handoff_stride/`.

  The pages render against the design tokens defined in `tokens.css`
  (`--ink`, `--surface`, `--line`, `--stride-orange`, etc.) — not daisyUI
  semantic classes like `bg-primary` or `text-base-content`. These tests
  assert the tokens are present and that the dark-mode-forbidden hardcoded
  greyscale Tailwind classes from CLAUDE.md are absent.
  """

  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @theme_token_markers ["var(--ink)", "var(--surface)", "var(--line)"]
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

      assert html =~ "var(--ink)"
      refute html =~ "text-gray-900"
      refute html =~ "bg-white"
    end
  end
end
