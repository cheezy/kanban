defmodule KanbanWeb.SideNavTest do
  @moduledoc """
  Tests for the language menu and theme switch in the `KanbanWeb.SideNav`
  footer (D417). The nav entries themselves are covered in
  `KanbanWeb.LayoutsTest`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts.Scope
  alias KanbanWeb.NavComponents
  alias KanbanWeb.SideNav

  defp render_side_nav do
    assigns = %{current_scope: Scope.for_user(user_fixture()), active: nil, board: nil}

    rendered_to_string(~H"""
    <SideNav.side_nav current_scope={@current_scope} active={@active} board={@board} />
    """)
    |> LazyHTML.from_fragment()
  end

  defp attrs(doc, selector, name) do
    doc |> LazyHTML.query(selector) |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  describe "language menu" do
    test "renders the language menu with the seven supported locales" do
      Gettext.put_locale(KanbanWeb.Gettext, "en")
      doc = render_side_nav()
      menu = LazyHTML.query(doc, "#app-sidebar details#app-language-switcher")

      assert Enum.count(menu) == 1
      assert attrs(menu, "details", "class") == ["relative js-mobile-menu"]

      codes = Enum.map(NavComponents.supported_locales(), & &1.code)
      assert codes == ~w(en fr es pt de ja zh)

      # One CSRF-protected POST per locale, in the supported order.
      assert attrs(menu, "form", "action") == Enum.map(codes, &"/locale/#{&1}")
      assert attrs(menu, "form", "method") == List.duplicate("post", 7)

      tokens = attrs(menu, "form input[name=_csrf_token]", "value")
      assert length(tokens) == 7
      assert Enum.all?(tokens, &(&1 != ""))

      assert text(menu, "#app-language-menu form button span") ==
               Enum.map_join(NavComponents.supported_locales(), & &1.name)

      # The summary names the control and the current language; English is current.
      assert text(menu, "summary .sr-only") == "Change language"
      assert text(menu, "summary") =~ "English"
      assert attrs(menu, "button[aria-current=true]", "lang") == ["en"]
    end

    test "marks the current locale and translates the control's name" do
      Gettext.put_locale(KanbanWeb.Gettext, "fr")
      doc = render_side_nav()

      assert text(doc, "#app-language-switcher summary .sr-only") == "Changer de langue"
      assert text(doc, "#app-language-switcher summary") =~ "Français"
      assert attrs(doc, "#app-language-menu button[aria-current=true]", "lang") == ["fr"]
    end
  end

  describe "theme switch" do
    test "renders the System, Light and Dark theme buttons with translated labels" do
      Gettext.put_locale(KanbanWeb.Gettext, "en")
      doc = render_side_nav()
      group = LazyHTML.query(doc, "#app-sidebar [role=group]")

      assert attrs(group, "[role=group]", "aria-label") == ["Theme"]
      # The hook marks the stored choice with aria-pressed, which the server
      # cannot render, and LiveView patches leave that attribute alone.
      assert attrs(group, "[role=group]", "phx-hook") == ["ThemeToggle"]
      assert attrs(group, "[role=group]", "id") == ["theme-toggle"]

      buttons = LazyHTML.query(group, "button")
      assert attrs(buttons, "button", "data-phx-theme") == ~w(system light dark)
      assert attrs(buttons, "button", "aria-label") == ~w(System Light Dark)
      assert attrs(buttons, "button", "title") == ~w(System Light Dark)
      assert attrs(buttons, "button", "type") == ~w(button button button)

      # Each dispatches the event the layouts' bootstrap listens for, and keeps
      # the phone drawer open.
      for click <- attrs(buttons, "button", "phx-click") do
        assert click =~ "phx:set-theme"
      end

      assert length(attrs(buttons, "button", "data-sidebar-stay-open")) == 3

      for mounted <- attrs(buttons, "button", "phx-mounted") do
        assert mounted =~ ~s(["ignore_attrs",{"attrs":["aria-pressed"]}])
      end

      assert attrs(buttons, "button", "aria-pressed") == []

      # The colour is a class, not an inline style, so the hover colour applies.
      assert attrs(buttons, "button", "style") == []

      for class <- attrs(buttons, "button", "class") do
        assert class =~ "text-[var(--ink-2)] hover:text-[var(--ink)]"
      end

      # With no stored theme the bootstrap sets data-theme-choice="system", which
      # matches neither variant, so the indicator rests on the first (System) slot.
      [indicator] = attrs(group, "div[aria-hidden=true]", "class")
      assert indicator =~ "left-0"
      assert indicator =~ "[[data-theme-choice=light]_&]:left-1/3"
      assert indicator =~ "[[data-theme-choice=dark]_&]:left-2/3"

      Gettext.put_locale(KanbanWeb.Gettext, "de")
      german = render_side_nav()
      assert attrs(german, "[role=group]", "aria-label") == ["Design"]
      assert attrs(german, "[role=group] button", "aria-label") == ~w(System Hell Dunkel)
    end

    test "every locale translates the theme labels" do
      for locale <- ~w(fr es pt de ja zh) do
        labels =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            doc = render_side_nav()

            attrs(doc, "[role=group]", "aria-label") ++
              attrs(doc, "[role=group] button", "aria-label")
          end)

        assert length(labels) == 4
        refute "Light" in labels, "#{locale} leaves Light untranslated"
        refute "Dark" in labels, "#{locale} leaves Dark untranslated"
        refute "Theme" in labels, "#{locale} leaves Theme untranslated"
      end
    end
  end

  test "the sidebar scrolls instead of clipping its footer on short screens" do
    [style] = attrs(render_side_nav(), "#app-sidebar", "style")
    assert style =~ "overflow-y: auto"
  end
end
