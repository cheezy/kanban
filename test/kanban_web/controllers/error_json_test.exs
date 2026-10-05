defmodule KanbanWeb.ErrorJSONTest do
  use KanbanWeb.ConnCase, async: true

  test "renders 404" do
    assert KanbanWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  # D351: an /api 406 uses the API error shape, not the generic errors.detail one.
  test "renders an /api 406 with the API error shape and a fixed message" do
    conn = Phoenix.ConnTest.build_conn(:get, "/api/openapi.json")

    assert KanbanWeb.ErrorJSON.render("406.json", %{conn: conn}) == %{
             error: "Not Acceptable",
             message: "This API only serves application/json."
           }
  end

  test "renders an /api 406 without echoing anything from the request" do
    conn =
      :get
      |> Phoenix.ConnTest.build_conn("/api/tasks?_format=d351-probe")
      |> Plug.Conn.put_req_header("accept", "text/html;marker=d351-probe")

    rendered = KanbanWeb.ErrorJSON.render("406.json", %{conn: conn, reason: :boom})

    refute inspect(rendered) =~ "d351-probe"
    assert rendered == KanbanWeb.ErrorJSON.render("406.json", %{conn: build_api_conn()})
  end

  test "renders a non-API 406 with the generic body, not the API wording" do
    conn = Phoenix.ConnTest.build_conn(:get, "/about")

    assert KanbanWeb.ErrorJSON.render("406.json", %{conn: conn}) ==
             %{errors: %{detail: "Not Acceptable"}}

    assert KanbanWeb.ErrorJSON.render("406.json", %{}) == %{errors: %{detail: "Not Acceptable"}}
  end

  test "renders 500" do
    assert KanbanWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  defp build_api_conn, do: Phoenix.ConnTest.build_conn(:get, "/api/openapi.json")
end
