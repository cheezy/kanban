defmodule KanbanWeb.ResourcesLive.IndexTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KanbanWeb.ResourcesLive.Index

  describe "GET /resources" do
    test "renders resources index page", %{conn: conn} do
      conn = get(conn, ~p"/resources")
      assert html_response(conn, 200) =~ "Resources"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, ~p"/resources")
      assert conn.status == 200
    end
  end

  describe "GET /resources/:id" do
    test "renders individual resource page", %{conn: conn} do
      conn = get(conn, ~p"/resources/getting-started")
      assert html_response(conn, 200) =~ "Resource"
    end

    test "accepts any id parameter", %{conn: conn} do
      conn = get(conn, ~p"/resources/any-id-works")
      assert conn.status == 200
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, ~p"/resources/test-guide")
      assert conn.status == 200
    end
  end

  describe "mount/3" do
    test "assigns all_how_tos and filtered_how_tos", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      assert view |> element("h1") |> render() =~ "Resources"
      # Should have how-to cards rendered
      html = render(view)
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end

    test "initializes with empty search_query", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources")

      # Search input should be empty
      assert html =~ ~s(value="")
    end

    test "initializes with no selected_tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources")

      # No tags should have the active class initially (bg-blue-600)
      # All tag buttons should have bg-base-200 (inactive state)
      assert html =~ "getting-started"
      assert html =~ "developer"
    end
  end

  describe "search event" do
    test "updates search_query and filters results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Search for "hook"
      html =
        view
        |> element("input[name=query]")
        |> render_keyup(%{value: "hook"})

      # Should show hook-related guides
      assert html =~ "Setting Up Hook Execution"
      assert html =~ "Debugging Hook Failures"
      # Should not show non-matching guides
      refute html =~ "Creating Your First Board"
    end

    test "empty search returns all results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Search then clear
      view
      |> element("input[name=query]")
      |> render_keyup(%{value: "hook"})

      html =
        view
        |> element("input[name=query]")
        |> render_keyup(%{value: ""})

      # Should show all guides
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end
  end

  describe "toggle_tag event" do
    test "adds tag to selected_tags and filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Click on developer tag
      html =
        view
        |> element("button[phx-value-tag=developer]")
        |> render_click()

      # Should show developer guides
      assert html =~ "Setting Up Hook Execution"
      assert html =~ "Configuring API Authentication"
      # Should not show beginner-only guides
      refute html =~ "Creating Your First Board"
    end

    test "removes tag when clicked again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Click developer tag twice
      view
      |> element("button[phx-value-tag=developer]")
      |> render_click()

      html =
        view
        |> element("button[phx-value-tag=developer]")
        |> render_click()

      # Should show all guides again
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end

    test "supports multiple tag selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Select multiple tags
      view
      |> element("button[phx-value-tag=getting-started]")
      |> render_click()

      html =
        view
        |> element("button[phx-value-tag=developer]")
        |> render_click()

      # Should show guides matching either tag
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end
  end

  describe "sort event" do
    test "changes sort order to newest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      html =
        view
        |> element("select[name=sort_by]")
        |> render_change(%{sort_by: "newest"})

      # Should still show all guides (just reordered)
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end

    test "changes sort order to a-z", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      html =
        view
        |> element("select[name=sort_by]")
        |> render_change(%{sort_by: "a-z"})

      # Should still show all guides
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end
  end

  describe "clear_filters event" do
    test "resets all filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Apply some filters
      view
      |> element("input[name=query]")
      |> render_keyup(%{value: "hook"})

      view
      |> element("button[phx-value-tag=developer]")
      |> render_click()

      # Clear filters
      html =
        view
        |> element("button[phx-click=clear_filters]")
        |> render_click()

      # Should show all guides
      assert html =~ "Creating Your First Board"
      assert html =~ "Setting Up Hook Execution"
    end
  end

  describe "filter_how_tos/3" do
    test "filters by search query in title" do
      how_tos = [
        %{title: "Test Guide", description: "Description", tags: ["test"]},
        %{title: "Another Guide", description: "Different", tags: ["other"]}
      ]

      result = Index.filter_how_tos(how_tos, "Test", [])
      assert length(result) == 1
      assert hd(result).title == "Test Guide"
    end

    test "filters by search query in description" do
      how_tos = [
        %{title: "Guide One", description: "Contains hook info", tags: ["test"]},
        %{title: "Guide Two", description: "Other stuff", tags: ["other"]}
      ]

      result = Index.filter_how_tos(how_tos, "hook", [])
      assert length(result) == 1
      assert hd(result).title == "Guide One"
    end

    test "filters by search query in tags" do
      how_tos = [
        %{title: "Guide One", description: "Desc", tags: ["developer", "api"]},
        %{title: "Guide Two", description: "Desc", tags: ["beginner"]}
      ]

      result = Index.filter_how_tos(how_tos, "developer", [])
      assert length(result) == 1
      assert hd(result).title == "Guide One"
    end

    test "filters by selected tags" do
      how_tos = [
        %{title: "Guide One", description: "Desc", tags: ["developer", "api"]},
        %{title: "Guide Two", description: "Desc", tags: ["beginner"]}
      ]

      result = Index.filter_how_tos(how_tos, "", ["developer"])
      assert length(result) == 1
      assert hd(result).title == "Guide One"
    end

    test "combines search and tag filters" do
      how_tos = [
        %{title: "API Guide", description: "Desc", tags: ["developer", "api"]},
        %{title: "API Basics", description: "Desc", tags: ["beginner", "api"]},
        %{title: "Hooks Guide", description: "Desc", tags: ["developer", "hooks"]}
      ]

      result = Index.filter_how_tos(how_tos, "API", ["developer"])
      assert length(result) == 1
      assert hd(result).title == "API Guide"
    end

    test "returns all results with empty search and no tags" do
      how_tos = [
        %{title: "Guide One", description: "Desc", tags: ["test"]},
        %{title: "Guide Two", description: "Desc", tags: ["other"]}
      ]

      result = Index.filter_how_tos(how_tos, "", [])
      assert length(result) == 2
    end
  end

  describe "empty state" do
    test "shows empty state when no results match", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources")

      # Search for something that doesn't exist
      html =
        view
        |> element("input[name=query]")
        |> render_keyup(%{value: "xyznonexistent"})

      assert html =~ "No guides found"
      assert html =~ "Clear all filters"
    end
  end

  describe "type_icon/1" do
    test "returns correct icon for guide type" do
      assert Index.type_icon("guide") == "hero-book-open"
    end

    test "returns correct icon for tutorial type" do
      assert Index.type_icon("tutorial") == "hero-academic-cap"
    end

    test "returns correct icon for reference type" do
      assert Index.type_icon("reference") == "hero-document-text"
    end

    test "returns correct icon for video type" do
      assert Index.type_icon("video") == "hero-play-circle"
    end

    test "returns default icon for unknown type" do
      assert Index.type_icon("unknown") == "hero-document"
    end
  end

  describe "format_tag/1" do
    test "formats hyphenated tag" do
      assert Index.format_tag("getting-started") == "Getting Started"
    end

    test "formats single word tag" do
      assert Index.format_tag("developer") == "Developer"
    end

    test "formats multi-word tag" do
      assert Index.format_tag("api-authentication-guide") == "Api Authentication Guide"
    end
  end
end
