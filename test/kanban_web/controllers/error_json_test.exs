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

  # D353: pre-router /api errors use the API error shape with fixed messages.
  test "renders /api 400, 413 and 415 with the API error shape" do
    conn = build_api_conn()

    assert KanbanWeb.ErrorJSON.render("400.json", %{conn: conn}) == %{
             error: "Bad Request",
             message: "The request is malformed and could not be processed."
           }

    assert KanbanWeb.ErrorJSON.render("413.json", %{conn: conn}) == %{
             error: "Request Entity Too Large",
             message: "The request body is too large."
           }

    assert KanbanWeb.ErrorJSON.render("415.json", %{conn: conn}) == %{
             error: "Unsupported Media Type",
             message: "Send the request body as application/json."
           }
  end

  test "renders an /api 400 without echoing the request or the exception" do
    conn = Phoenix.ConnTest.build_conn(:get, "/api/tasks?d353-probe=%FF")

    rendered =
      KanbanWeb.ErrorJSON.render("400.json", %{
        conn: conn,
        reason: %Plug.Conn.InvalidQueryError{message: "d353-probe"}
      })

    refute inspect(rendered) =~ "d353-probe"
    assert rendered == KanbanWeb.ErrorJSON.render("400.json", %{conn: build_api_conn()})
  end

  test "renders a non-API 400 and a 400 without a conn with the generic body" do
    conn = Phoenix.ConnTest.build_conn(:get, "/about")

    assert KanbanWeb.ErrorJSON.render("400.json", %{conn: conn}) ==
             %{errors: %{detail: "Bad Request"}}

    assert KanbanWeb.ErrorJSON.render("400.json", %{}) == %{errors: %{detail: "Bad Request"}}
  end

  test "renders an /api status without its own clause with the generic body" do
    assert KanbanWeb.ErrorJSON.render("404.json", %{conn: build_api_conn()}) ==
             %{errors: %{detail: "Not Found"}}
  end

  # D462: an /api/me 404 uses the person API's own Not Found body.
  test "renders an /api/me 404 with the person API's error body" do
    for path <- ["/api/me", "/api/me/no-such-route", "/%61pi/me/x"] do
      conn = Phoenix.ConnTest.build_conn(:options, path)

      assert KanbanWeb.ErrorJSON.render("404.json", %{conn: conn}) == %{error: "Not Found"},
             path
    end
  end

  test "renders an /api/me 400 and 406 with the API error shape" do
    conn = Phoenix.ConnTest.build_conn(:put, "/api/me/devices/current")

    assert KanbanWeb.ErrorJSON.render("400.json", %{conn: conn}) ==
             KanbanWeb.ErrorJSON.render("400.json", %{conn: build_api_conn()})

    assert KanbanWeb.ErrorJSON.render("406.json", %{conn: conn}) ==
             KanbanWeb.ErrorJSON.render("406.json", %{conn: build_api_conn()})
  end

  # D462: an /oauth 404 is an RFC 6749 invalid_request with a fixed description.
  test "renders an /oauth 404 as an invalid_request" do
    for path <- ["/oauth/nope", "/oauth/token", "/oauth/token/extra", "/oauth", "/%6Fauth/x"] do
      conn = Phoenix.ConnTest.build_conn(:get, path)

      assert KanbanWeb.ErrorJSON.render("404.json", %{conn: conn}) == %{
               error: "invalid_request",
               error_description: "No endpoint matches this request."
             },
             path
    end
  end

  test "renders /oauth 400, 413, 415 and 406 under any /oauth API path" do
    conn = Phoenix.ConnTest.build_conn(:post, "/oauth/nope")

    assert %{error: "invalid_request", error_description: _} =
             KanbanWeb.ErrorJSON.render("400.json", %{conn: conn})

    assert %{error: "invalid_request"} = KanbanWeb.ErrorJSON.render("413.json", %{conn: conn})
    assert %{error: "invalid_request"} = KanbanWeb.ErrorJSON.render("415.json", %{conn: conn})

    assert KanbanWeb.ErrorJSON.render("406.json", %{conn: conn}) == %{
             error: "Not Acceptable",
             message: "This API only serves application/json."
           }
  end

  test "renders an /oauth 404 without echoing the request" do
    conn =
      :get
      |> Phoenix.ConnTest.build_conn("/oauth/d462-probe?q=d462-probe")
      |> Plug.Conn.put_req_header("accept", "text/html;marker=d462-probe")

    refute inspect(KanbanWeb.ErrorJSON.render("404.json", %{conn: conn})) =~ "d462-probe"
  end

  test "renders a 404 on the authorize page and an agent /api path with the generic body" do
    for path <- ["/oauth/authorize", "/oauth/authorize/extra", "/api/no-such-route"] do
      conn = Phoenix.ConnTest.build_conn(:delete, path)

      assert KanbanWeb.ErrorJSON.render("404.json", %{conn: conn}) ==
               %{errors: %{detail: "Not Found"}},
             path
    end
  end

  test "renders 500" do
    assert KanbanWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  defp build_api_conn, do: Phoenix.ConnTest.build_conn(:get, "/api/openapi.json")
end
