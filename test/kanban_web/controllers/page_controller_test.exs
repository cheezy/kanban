defmodule KanbanWeb.PageControllerTest do
  use KanbanWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # New marketing hero headline (set in MarketingComponents.marketing_hero/1).
    # The second line is asserted loosely so the specific subject ("Stride" /
    # "Your kanban" / etc.) can change without breaking the test — the load-
    # bearing brand line is the first one.
    assert body =~ "Tasks are conversations."
    assert body =~ "speak both ways."
    # MiniBoard renders the canonical fixture idents from the new design.
    assert body =~ "W198"
    assert body =~ "W193"
  end

  test "GET /about", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200)
  end

  test "GET /privacy", %{conn: conn} do
    conn = get(conn, ~p"/privacy")
    body = html_response(conn, 200)
    assert body =~ "Privacy Policy"
    assert body =~ "Information we collect"
    assert body =~ "Your rights"
    assert body =~ "Contact us"
  end

  test "GET /security", %{conn: conn} do
    conn = get(conn, ~p"/security")
    body = html_response(conn, 200)
    assert body =~ "Authentication and access"
    assert body =~ "Transport and storage"
    assert body =~ "Vulnerability disclosure"
    assert body =~ "security@letstango.ca"
  end

  test "GET /pricing", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    body = html_response(conn, 200)
    # Three tiers
    assert body =~ "Solo"
    assert body =~ "Team"
    assert body =~ "Enterprise"
    # FAQ section
    assert body =~ "Frequently asked questions"
  end

  test "GET /product", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)
    # Hero + at least the first three feature sections render
    assert body =~ "Five-column flow"
    assert body =~ "Structured schema"
    assert body =~ "Plan at the level you think at"
    # All six section screenshots have been wired in (no placeholders remain).
    assert body =~ "/images/boards.png"
    assert body =~ "/images/kanban_board.png"
    assert body =~ "/images/task_detail.png"
    assert body =~ "/images/goal_view.png"
    assert body =~ "/images/review_queue.png"
    assert body =~ "/images/agent_activity.png"
    assert body =~ "/images/workspace_metrics.png"
    refute body =~ "image-placeholder"
  end

  test "GET /workflows", %{conn: conn} do
    conn = get(conn, ~p"/workflows")
    body = html_response(conn, 200)
    # Lifecycle column names
    assert body =~ "Backlog"
    assert body =~ "Ready"
    assert body =~ "Doing"
    assert body =~ "Review"
    assert body =~ "Done"
    # All four hook names render as code
    assert body =~ "before_doing"
    assert body =~ "after_doing"
    assert body =~ "before_review"
    assert body =~ "after_review"
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
