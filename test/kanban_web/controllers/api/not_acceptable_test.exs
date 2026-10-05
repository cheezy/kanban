defmodule KanbanWeb.API.NotAcceptableTest do
  @moduledoc """
  D351: an `/api` request whose `Accept` header asks for a format the API
  does not serve must get a clean 406 JSON error, not a 500 from
  `KanbanWeb.ErrorHTML` failing to render `"406.html"`.

  Both API pipelines pin the response format to json ahead of
  `plug :accepts, ["json"]`, so `Phoenix.Endpoint.RenderErrors` renders the
  406 through `KanbanWeb.ErrorJSON`. In tests Phoenix re-raises after
  rendering, so every 406 here goes through `assert_error_sent/2`, which also
  exercises the production render path (no debug page).
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens

  @expected_body %{
    "error" => "Not Acceptable",
    "message" => "This API only serves application/json."
  }

  @public_paths ["/api/openapi.json", "/api/agent/onboarding"]

  @unsupported_accepts [
    "text/html",
    "text/html,application/xhtml+xml",
    "application/xml",
    "image/png"
  ]

  @browser_default_accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  defp api_token do
    user = user_fixture()
    board = board_fixture(user)

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{"name" => "D351 not acceptable"})

    plain_token
  end

  defp api_routes do
    for %{path: "/api" <> _ = path, verb: verb} <- KanbanWeb.Router.__routes__() do
      {verb, String.replace(path, ~r/:\w+/, "1")}
    end
  end

  defp with_accept(conn, accept), do: put_req_header(conn, "accept", accept)

  defp assert_not_acceptable(fun, label) do
    {status, headers, body} = assert_error_sent(406, fun)

    assert status == 406, label

    assert {"content-type", "application/json; charset=utf-8"} in headers,
           "#{label} did not return application/json: #{inspect(headers)}"

    decoded = Jason.decode!(body)
    assert decoded == @expected_body, "#{label} returned #{inspect(decoded)}"

    {decoded, body}
  end

  describe "supported Accept values are unaffected" do
    test "application/json is served on the public routes", %{conn: conn} do
      for path <- @public_paths do
        conn = conn |> with_accept("application/json") |> get(path)
        assert conn.status == 200, "#{path} returned #{conn.status}"
      end
    end

    test "application/json reaches authentication on an authenticated route", %{conn: conn} do
      conn = conn |> with_accept("application/json") |> get(~p"/api/tasks")
      assert %{"error" => _} = json_response(conn, 401)

      conn =
        build_conn()
        |> with_accept("application/json")
        |> put_req_header("authorization", "Bearer " <> api_token())
        |> get(~p"/api/tasks")

      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  describe "wildcard and openapi media types still succeed" do
    for accept <- ["*/*", "application/vnd.oai.openapi+json", @browser_default_accept] do
      test "Accept: #{accept} returns 200 on /api/openapi.json", %{conn: conn} do
        conn = conn |> with_accept(unquote(accept)) |> get(~p"/api/openapi.json")
        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      end
    end
  end

  describe "unsupported Accept returns 406 JSON on public and authenticated routes" do
    test "on the public routes for every unsupported Accept value", %{conn: conn} do
      for path <- @public_paths, accept <- @unsupported_accepts do
        assert_not_acceptable(
          fn -> conn |> with_accept(accept) |> get(path) end,
          "GET #{path} with Accept: #{accept}"
        )
      end
    end

    test "on GET /api/tasks with no token, before authentication runs", %{conn: conn} do
      for accept <- ["text/html", "application/xml"] do
        assert_not_acceptable(
          fn -> conn |> with_accept(accept) |> get(~p"/api/tasks") end,
          "GET /api/tasks (no token) with Accept: #{accept}"
        )
      end
    end

    test "valid and invalid tokens get the identical 406", %{conn: conn} do
      token = api_token()

      bodies =
        for auth <- ["Bearer " <> token, "Bearer not-a-real-token"] do
          {_decoded, body} =
            assert_not_acceptable(
              fn ->
                conn
                |> with_accept("text/html")
                |> put_req_header("authorization", auth)
                |> get(~p"/api/tasks")
              end,
              "GET /api/tasks with an Authorization header"
            )

          body
        end

      assert [same, same] = bodies
    end

    test "the body leaks no internals and does not echo the Accept header", %{conn: conn} do
      accept = "text/html;marker=d351-echo-probe"

      {_decoded, body} =
        assert_not_acceptable(
          fn -> conn |> with_accept(accept) |> get(~p"/api/openapi.json") end,
          "GET /api/openapi.json with a marked Accept"
        )

      for needle <- [
            "d351-echo-probe",
            "text/html",
            "NotAcceptableError",
            "Phoenix",
            "lib/",
            ".ex"
          ] do
        refute body =~ needle, "406 body leaked #{inspect(needle)}: #{body}"
      end
    end

    test "a malformed Accept header gets the same 406 JSON, not a crash", %{conn: conn} do
      for accept <- ["not a media type", ";;;", "text/"] do
        assert_not_acceptable(
          fn -> conn |> with_accept(accept) |> get(~p"/api/agent/onboarding") end,
          "GET /api/agent/onboarding with Accept: #{inspect(accept)}"
        )
      end
    end

    test "an unsupported _format parameter returns the same 406 JSON", %{conn: conn} do
      assert_not_acceptable(
        fn -> conn |> with_accept("application/json") |> get("/api/openapi.json?_format=xml") end,
        "GET /api/openapi.json?_format=xml"
      )
    end
  end

  describe "missing Accept header is not rejected" do
    test "public routes return 200" do
      for path <- @public_paths do
        conn = get(build_conn(), path)
        assert conn.status == 200, "#{path} returned #{conn.status}"
      end
    end

    test "an authenticated route without a token returns 401, not 406" do
      conn = get(build_conn(), ~p"/api/tasks")
      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  describe "every /api route returns 406 for Accept: text/html" do
    test "the format pin covers every route in both API pipelines", %{conn: conn} do
      routes = api_routes()

      # 2 public + 18 authenticated today; guard against the list going empty.
      assert length(routes) >= 20

      for {verb, path} <- routes do
        assert_not_acceptable(
          fn -> conn |> with_accept("text/html") |> dispatch(@endpoint, verb, path, nil) end,
          "#{verb |> Atom.to_string() |> String.upcase()} #{path}"
        )
      end
    end
  end

  describe "error rendering outside the API pipelines is unchanged" do
    test "a :browser route with Accept: application/json keeps the generic 406 body", %{
      conn: conn
    } do
      {406, headers, body} =
        assert_error_sent(406, fn ->
          conn |> with_accept("application/json") |> get(~p"/about")
        end)

      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Not Acceptable"}}
    end

    test "an unrouted /api path with Accept: text/html still renders the HTML 404", %{conn: conn} do
      # NoRouteError is rendered but not re-raised, so this is a plain get/2:
      # it fails before any pipeline runs, so the json pin never applies.
      conn = conn |> with_accept("text/html") |> get("/api/d351-no-such-route")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      refute conn.resp_body =~ "Not Acceptable"
    end
  end
end
