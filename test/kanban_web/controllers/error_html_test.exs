defmodule KanbanWeb.ErrorHTMLTest do
  use KanbanWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(KanbanWeb.ErrorHTML, "404", "html", [])
    assert html =~ "404"
    assert html =~ "Page Not Found"
  end

  test "renders 500.html" do
    html = render_to_string(KanbanWeb.ErrorHTML, "500", "html", [])
    assert html =~ "500"
    assert html =~ "Internal Server Error"
  end

  test "error pages carry an inline theme bootstrap that resolves system pref and sets data-theme" do
    for status <- ["404", "500"] do
      html = render_to_string(KanbanWeb.ErrorHTML, status, "html", [])
      # Reads the stored theme and honors the system preference...
      assert html =~ ~s|localStorage.getItem("phx:theme")|
      assert html =~ "prefers-color-scheme: dark"
      # ...then sets data-theme EXPLICITLY (resolve-to-explicit), and never
      # removes it. Removing data-theme for "system" (the app-layout approach)
      # would leave the Stride var(--*) accents light against a dark daisyUI
      # surface — the dark-on-dark "Go Home" button bug this page must avoid.
      # Pinning the divergence stops a future "align with root.html.heex"
      # refactor from silently reintroducing it.
      assert html =~ ~s|setAttribute("data-theme"|
      refute html =~ "removeAttribute"
      # The var(--*) elements (Go-Home link, status icon) carry .stride-screen,
      # so their tokens flip under html[data-theme="dark"].
      assert html =~ "stride-screen"
    end
  end
end
