defmodule KanbanWeb.KeyboardShortcutsHelpTest do
  @moduledoc """
  Contract tests for `KanbanWeb.KeyboardShortcutsHelp` (W2236).
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.KeyboardShortcutsHelp

  defp render_help(attrs \\ %{}) do
    assigns = Map.merge(%{id: "keyboard-shortcuts-help"}, attrs)

    rendered_to_string(~H"""
    <KeyboardShortcutsHelp.keyboard_shortcuts_help id={@id} />
    """)
  end

  describe "shortcuts/0" do
    test "lists /, ? and Escape in display order with a description each" do
      assert [{"/", search}, {"?", help}, {"Esc", escape}] = KeyboardShortcutsHelp.shortcuts()

      assert search == "Focus the search box"
      assert help == "Show or hide this list of shortcuts"
      assert escape == "Close this list, or clear the selected tasks"
    end

    test "translates the key cap and descriptions in the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        assert [{"/", search}, {"?", _help}, {escape_key, _escape}] =
                 KeyboardShortcutsHelp.shortcuts()

        assert escape_key == "Échap"
        refute search == "Focus the search box"
      end)
    end
  end

  describe "keyboard_shortcuts_help/1" do
    test "renders an accessible modal dialog labelled by its title" do
      html = render_help()

      assert html =~ ~s(id="keyboard-shortcuts-help")
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="keyboard-shortcuts-help-title")
      assert html =~ ~s(id="keyboard-shortcuts-help-title")
      assert html =~ "Keyboard shortcuts"
    end

    test "renders every shortcut row" do
      html = render_help()
      rows = KeyboardShortcutsHelp.shortcuts()

      assert length(Regex.scan(~r/data-shortcut-row/, html)) == length(rows)

      for {key, description} <- rows do
        assert html =~ ~s(<kbd class="kbd">#{key}</kbd>)
        assert html =~ description
      end
    end

    test "has a labelled close control that pushes close_shortcuts_help" do
      html = render_help()

      assert html =~ ~s(id="keyboard-shortcuts-help-close")
      assert html =~ ~s(aria-label="Close keyboard shortcuts")
      assert html =~ ~s(phx-click="close_shortcuts_help")
    end

    test "closes on Escape and on a click outside the panel" do
      html = render_help()

      assert html =~ ~s(phx-window-keydown="close_shortcuts_help")
      assert html =~ ~s(phx-key="escape")
      assert html =~ ~s(phx-click-away="close_shortcuts_help")
    end

    # The opener pushes focus (see show_test.exs). A push_focus in phx-mounted
    # would remember the panel itself, which is gone when focus is popped.
    test "focuses the panel on open and pops focus on close, without pushing the panel" do
      document = render_help() |> LazyHTML.from_fragment()

      [mounted] =
        document
        |> LazyHTML.query("#keyboard-shortcuts-help-panel")
        |> LazyHTML.attribute("phx-mounted")

      [removed] =
        document |> LazyHTML.query("#keyboard-shortcuts-help") |> LazyHTML.attribute("phx-remove")

      assert [["focus_first", _]] = Jason.decode!(mounted)
      assert [["pop_focus", _]] = Jason.decode!(removed)
    end

    test "uses theme tokens rather than hardcoded colours" do
      html = render_help()

      assert html =~ "bg-base-100"
      assert html =~ "bg-base-200/90"
      refute html =~ "bg-white"
      refute html =~ ~r/text-gray-\d/
    end

    test "derives every element id from the id attr" do
      html = render_help(%{id: "help-under-test"})

      assert html =~ ~s(id="help-under-test")
      assert html =~ ~s(id="help-under-test-panel")
      assert html =~ ~s(aria-labelledby="help-under-test-title")
      assert html =~ ~s(id="help-under-test-close")
    end
  end
end
