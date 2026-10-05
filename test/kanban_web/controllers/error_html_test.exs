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

  # D353: statuses without a template render through the render/2 fallback
  # instead of raising ArgumentError ("no \"400\" html template defined").
  for {status, heading} <- [
        {"400", "Bad Request"},
        {"406", "Not Acceptable"},
        {"413", "Request Too Large"},
        {"415", "Unsupported Media Type"}
      ] do
    test "renders #{status}.html through the fallback" do
      html = render_to_string(KanbanWeb.ErrorHTML, unquote(status), "html", [])

      assert html =~ "<!DOCTYPE html>"

      assert html =~
               ~s|<h1 class="text-6xl font-bold text-base-content mb-4">#{unquote(status)}</h1>|

      assert html =~ "<title>#{unquote(heading)} · Stride</title>"
      assert html =~ unquote(heading)
      assert html =~ "Go Home"
    end
  end

  test "renders a status with no specific wording through the generic fallback" do
    html = render_to_string(KanbanWeb.ErrorHTML, "418", "html", [])

    assert html =~ ~s|<h1 class="text-6xl font-bold text-base-content mb-4">418</h1>|
    assert html =~ "Something Went Wrong"
  end

  test "the fallback shows nothing from the exception or the request" do
    html =
      KanbanWeb.ErrorHTML.render("400.html", %{
        status: 400,
        kind: :error,
        reason: %Plug.Conn.InvalidQueryError{message: "d353-leak-probe in lib/x.ex"},
        stack: []
      })
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    refute html =~ "d353-leak-probe"
    refute html =~ "InvalidQueryError"
    assert html =~ "Bad Request"
  end

  test "the fallback text is translated" do
    Gettext.put_locale(KanbanWeb.Gettext, "fr")

    try do
      html = render_to_string(KanbanWeb.ErrorHTML, "400", "html", [])
      refute html =~ "Bad Request"
      refute html =~ "Go Home"
    after
      Gettext.put_locale(KanbanWeb.Gettext, "en")
    end
  end

  test "error pages carry an inline theme bootstrap that resolves system pref and sets data-theme" do
    for status <- ["404", "500", "400", "406"] do
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
