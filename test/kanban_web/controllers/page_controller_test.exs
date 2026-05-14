defmodule KanbanWeb.PageControllerTest do
  use KanbanWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # New marketing hero headline (set in MarketingComponents.marketing_hero/1).
    assert body =~ "Tasks are conversations."
    assert body =~ "Your kanban can speak both ways."
    # MiniBoard renders the canonical fixture idents from the new design.
    assert body =~ "W198"
    assert body =~ "W193"
  end

  test "GET /about", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200)
  end

  test "GET /tango", %{conn: conn} do
    conn = get(conn, ~p"/tango")
    assert html_response(conn, 200)
  end

  test "GET /tango: gettext'd marketing copy is never raw'd onto the page", %{conn: conn} do
    # Asserts the template no longer ships `raw/1` on translator-controlled
    # strings. If a future change re-introduces raw/1 here, this test fails
    # before a malicious translator can land an inline <script>.
    template = File.read!("lib/kanban_web/controllers/page_html/tango.html.heex")
    refute template =~ "|> raw()"
    refute template =~ "raw("

    # Sanity: the page still renders and contains key copy fragments.
    conn = get(conn, ~p"/tango")
    body = html_response(conn, 200)
    assert body =~ "About Tango"
    assert body =~ "Our Mission"
    assert body =~ "Work With Us"
  end

  test "GET /changelog", %{conn: conn} do
    conn = get(conn, ~p"/changelog")
    assert html_response(conn, 200)
  end

  describe "POST /locale/:locale" do
    test "sets locale and redirects to referer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://localhost/boards")
        |> post(~p"/locale/en")

      assert redirected_to(conn) == "/boards"
    end

    test "redirects to root when no referer", %{conn: conn} do
      conn = post(conn, ~p"/locale/en")
      assert redirected_to(conn) == "/"
    end

    test "sets locale in session", %{conn: conn} do
      conn = post(conn, ~p"/locale/en")
      assert get_session(conn, :locale) == "en"
    end
  end
end
