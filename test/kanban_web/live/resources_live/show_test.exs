defmodule KanbanWeb.ResourcesLive.ShowTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KanbanWeb.ResourcesLive.Show

  describe "GET /resources/:id" do
    test "renders how-to page for valid id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Creating Your First Board"
      assert html =~ "Learn how to create and configure"
      assert html =~ "Back to Resources"
    end

    test "renders 404 state for invalid id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/nonexistent-guide")

      assert html =~ "Guide not found"
      assert html =~ "doesn&#39;t exist or may have been moved"
      assert html =~ "Browse all guides"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, ~p"/resources/creating-your-first-board")
      assert conn.status == 200
    end
  end

  describe "mount/3 with valid how-to" do
    test "assigns how_to data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/creating-your-first-board")

      html = render(view)
      assert html =~ "Creating Your First Board"
      assert html =~ "Access Your Boards Dashboard"
    end

    test "assigns page_title from how_to title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/setting-up-hooks")

      # The page title should reflect the how-to
      assert page_title(view) =~ "Setting Up Hook Execution"
    end

    test "assigns navigation for previous/next guides", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/understanding-columns")

      # This guide should have navigation
      assert html =~ "Previous" or html =~ "Next"
    end
  end

  describe "mount/3 with invalid how-to" do
    test "assigns nil how_to", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/invalid-id")

      assert html =~ "Guide not found"
      refute html =~ "You're all set"
    end

    test "sets page_title to Not Found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/invalid-id")

      assert page_title(view) =~ "Not Found"
    end
  end

  describe "hero section" do
    test "displays title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/api-authentication")

      assert html =~ "Configuring API Authentication"
    end

    test "displays description", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/api-authentication")

      assert html =~ "Set up API tokens for secure access"
    end

    test "displays content type badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/setting-up-hooks")

      # "tutorial" type
      assert html =~ "Tutorial"
      assert html =~ "hero-academic-cap"
    end

    test "displays reading time", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "3 min read"
    end

    test "displays tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Getting Started"
      assert html =~ "Beginner"
      assert html =~ "Boards"
    end
  end

  describe "steps content" do
    test "displays all steps with numbers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # Should have 4 steps (verify by checking step titles which are numbered)
      # The numbers are in div elements with the rounded-full class
      assert html =~ "rounded-full"
      assert html =~ "Access Your Boards Dashboard"
      assert html =~ "Click New Board"
      assert html =~ "Enter Board Details"
      assert html =~ "Start Using Your Board"
    end

    test "displays step titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Access Your Boards Dashboard"
      assert html =~ "Click New Board"
      assert html =~ "Enter Board Details"
      assert html =~ "Start Using Your Board"
    end

    test "displays step content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "My Boards"
      assert html =~ "navigation bar"
    end

    test "displays completion message after steps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # Note: apostrophe is HTML-encoded
      assert html =~ "You&#39;re all set!" or html =~ "You're all set!"
      assert html =~ "completed all the steps"
    end
  end

  describe "navigation" do
    test "shows back to resources link in hero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Back to Resources"
      assert html =~ ~s(href="/resources")
    end

    test "shows back to all resources button at bottom", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Back to all resources"
    end

    test "shows next guide when available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # First guide in getting-started should have next
      assert html =~ "Next"
    end

    test "shows previous guide when available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/adding-your-first-task")

      # Should have previous (not first guide)
      assert html =~ "Previous"
    end

    test "previous/next links navigate correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/creating-your-first-board")

      # Should be able to navigate
      html = render(view)
      assert html =~ ~r/href="\/resources\/[a-z-]+"/
    end
  end

  describe "render_markdown/1" do
    test "converts bold text" do
      result = Show.render_markdown("This is **bold** text")
      assert result =~ "<strong>bold</strong>"
    end

    test "converts inline code" do
      result = Show.render_markdown("Use `mix test` command")
      assert result =~ "<code"
      assert result =~ "mix test"
    end

    test "handles nil input" do
      assert Show.render_markdown(nil) == ""
    end

    test "converts list items" do
      result = Show.render_markdown("Items:\n- First\n- Second")
      assert result =~ "<ul"
      assert result =~ "<li>First</li>"
      assert result =~ "<li>Second</li>"
    end

    test "converts double newlines to paragraphs" do
      result = Show.render_markdown("First paragraph.\n\nSecond paragraph.")
      assert result =~ "<p>First paragraph.</p>"
      assert result =~ "<p>Second paragraph.</p>"
    end
  end

  describe "type_icon/1" do
    test "returns correct icon for guide type" do
      assert Show.type_icon("guide") == "hero-book-open"
    end

    test "returns correct icon for tutorial type" do
      assert Show.type_icon("tutorial") == "hero-academic-cap"
    end

    test "returns default icon for unknown type" do
      assert Show.type_icon("unknown") == "hero-document"
    end
  end

  describe "format_tag/1" do
    test "formats hyphenated tag" do
      assert Show.format_tag("getting-started") == "Getting Started"
    end

    test "formats single word tag" do
      assert Show.format_tag("developer") == "Developer"
    end
  end
end
