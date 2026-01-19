defmodule KanbanWeb.ResourcesLive.IndexTest do
  use KanbanWeb.ConnCase

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
end
