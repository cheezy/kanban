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
end
