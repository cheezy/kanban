defmodule KanbanWeb.API.PreRouterErrorsTest do
  @moduledoc """
  D353: errors whose status has no ErrorHTML template must return their real
  status, not a 500 from `KanbanWeb.ErrorHTML` failing to render
  `"<status>.html"`.

  Two routes in:

    * `Plug.Parsers` raises in the endpoint, before the router, for a
      malformed query string or body (400) or an oversized body (413). On an
      `/api` path the body must be JSON whatever the `Accept` header says;
      `KanbanWeb.Plugs.Parsers` pins the format for that. On a browser path it
      must be the HTML fallback page.
    * A `:browser` route asked for an `Accept` it does not serve raises a 406
      that renders as HTML.

  Phoenix re-raises after rendering these, so every case goes through
  `assert_error_sent/2`, which also exercises the production render path.
  """
  use KanbanWeb.ConnCase, async: true

  @api_bad_request %{
    "error" => "Bad Request",
    "message" => "The request is malformed and could not be processed."
  }

  @json_content_type {"content-type", "application/json; charset=utf-8"}
  @html_content_type {"content-type", "text/html; charset=utf-8"}

  defp with_accept(conn, nil), do: conn
  defp with_accept(conn, accept), do: put_req_header(conn, "accept", accept)

  defp assert_api_error(status, expected_body, fun, label) do
    {^status, headers, body} = assert_error_sent(status, fun)

    assert @json_content_type in headers,
           "#{label} did not return application/json: #{inspect(headers)}"

    assert Jason.decode!(body) == expected_body, "#{label} returned #{body}"
    body
  end

  defp assert_html_error(status, heading, fun, label) do
    {^status, headers, body} = assert_error_sent(status, fun)

    assert @html_content_type in headers, "#{label} did not return HTML: #{inspect(headers)}"
    assert body =~ "<!DOCTYPE html>", label
    assert body =~ ~s|<h1 class="text-6xl font-bold text-base-content mb-4">#{status}</h1>|, label
    assert body =~ heading, label
    body
  end

  describe "a malformed query string on an /api path" do
    for accept <- ["*/*", "text/html", "application/json", nil] do
      test "returns 400 JSON with Accept: #{inspect(accept)}" do
        assert_api_error(
          400,
          @api_bad_request,
          fn ->
            build_conn() |> with_accept(unquote(accept)) |> get("/api/openapi.json?a=%FF")
          end,
          "GET /api/openapi.json?a=%FF with Accept #{inspect(unquote(accept))}"
        )
      end
    end

    test "returns 400 JSON on an authenticated route, before the token is checked" do
      assert_api_error(
        400,
        @api_bad_request,
        fn -> build_conn() |> with_accept("text/html") |> get("/api/tasks?a=%FF") end,
        "GET /api/tasks?a=%FF"
      )
    end

    test "returns 400 JSON on an unrouted /api path" do
      assert_api_error(
        400,
        @api_bad_request,
        fn ->
          build_conn() |> with_accept("text/html") |> get("/api/d353-no-such-route?a=%FF")
        end,
        "GET /api/d353-no-such-route?a=%FF"
      )
    end

    test "the body leaks no internals and does not echo the request" do
      body =
        assert_api_error(
          400,
          @api_bad_request,
          fn ->
            build_conn()
            |> with_accept("text/html;marker=d353-echo-probe")
            |> get("/api/openapi.json?d353-echo-probe=%FF")
          end,
          "GET /api/openapi.json with a marked query"
        )

      for needle <- ["d353-echo-probe", "%FF", "InvalidQueryError", "Plug", "lib/", ".ex"] do
        refute body =~ needle, "400 body leaked #{inspect(needle)}: #{body}"
      end
    end
  end

  describe "a malformed or oversized body on an /api path" do
    test "malformed JSON returns 400 JSON even with Accept: text/html" do
      assert_api_error(
        400,
        @api_bad_request,
        fn ->
          build_conn()
          |> with_accept("text/html")
          |> put_req_header("content-type", "application/json")
          |> post("/api/tasks", "{not json")
        end,
        "POST /api/tasks with a malformed JSON body"
      )
    end

    test "a body over the parser limit returns 413 JSON" do
      body = ~s({"title":") <> String.duplicate("a", 8_100_000) <> ~s("})

      assert_api_error(
        413,
        %{"error" => "Request Entity Too Large", "message" => "The request body is too large."},
        fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/tasks", body)
        end,
        "POST /api/tasks with an oversized body"
      )
    end
  end

  describe "browser paths render the HTML fallback page" do
    test "a malformed query string returns a 400 HTML page" do
      for accept <- [nil, "*/*", "text/html"] do
        assert_html_error(
          400,
          "Bad Request",
          fn -> build_conn() |> with_accept(accept) |> get("/about?a=%FF") end,
          "GET /about?a=%FF with Accept #{inspect(accept)}"
        )
      end
    end

    test "a malformed query string on an unrouted path returns a 400 HTML page" do
      assert_html_error(
        400,
        "Bad Request",
        fn -> build_conn() |> get("/d353-no-such-page?a=%FF") end,
        "GET /d353-no-such-page?a=%FF"
      )
    end

    test "an unsupported Accept returns a 406 HTML page" do
      body =
        assert_html_error(
          406,
          "Not Acceptable",
          fn -> build_conn() |> with_accept("image/png") |> get(~p"/about") end,
          "GET /about with Accept: image/png"
        )

      for needle <- ["image/png", "NotAcceptableError", "Phoenix.", "lib/"] do
        refute body =~ needle, "406 page leaked #{inspect(needle)}"
      end
    end
  end

  describe "behaviour outside the failing paths is unchanged" do
    test "a well-formed /api request with Accept: text/html still gets the D351 406 JSON" do
      {406, headers, body} =
        assert_error_sent(406, fn ->
          build_conn() |> with_accept("text/html") |> get("/api/openapi.json?a=%41")
        end)

      assert @json_content_type in headers

      assert Jason.decode!(body) == %{
               "error" => "Not Acceptable",
               "message" => "This API only serves application/json."
             }
    end

    test "a well-formed /api request with Accept: */* still succeeds" do
      conn = build_conn() |> with_accept("*/*") |> get("/api/openapi.json?a=%41")
      assert conn.status == 200
    end

    test "an unrouted /api path without a parse error still renders the HTML 404" do
      conn = build_conn() |> with_accept("text/html") |> get("/api/d353-no-such-route")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    end

    test "a browser route with Accept: application/json keeps the generic 406 JSON body" do
      {406, headers, body} =
        assert_error_sent(406, fn ->
          build_conn() |> with_accept("application/json") |> get(~p"/about")
        end)

      assert @json_content_type in headers
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Not Acceptable"}}
    end
  end
end
