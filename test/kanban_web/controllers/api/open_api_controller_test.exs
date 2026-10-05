defmodule KanbanWeb.API.OpenApiControllerTest do
  use KanbanWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias KanbanWeb.API.OpenApiController
  alias KanbanWeb.API.OpenApiSpec

  describe "GET /api/openapi.json" do
    setup %{conn: conn} do
      %{conn: put_req_header(conn, "accept", "application/json")}
    end

    test "returns 200 application/json without an Authorization header", %{conn: conn} do
      refute Enum.any?(conn.req_headers, fn {name, _} -> name == "authorization" end)

      conn = get(conn, ~p"/api/openapi.json")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "serves the priv spec byte-for-byte and it decodes as JSON", %{conn: conn} do
      conn = get(conn, ~p"/api/openapi.json")

      assert conn.resp_body == File.read!(OpenApiSpec.path())
      assert %{"openapi" => "3.1." <> _} = Jason.decode!(conn.resp_body)
    end

    test "marks the response cacheable", %{conn: conn} do
      conn = get(conn, ~p"/api/openapi.json")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "succeeds without an Accept header" do
      conn = get(build_conn(), ~p"/api/openapi.json")

      assert conn.status == 200
    end

    test "serves the OpenAPI JSON media type through the json accepts pipeline" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/vnd.oai.openapi+json")
        |> get(~p"/api/openapi.json")

      assert conn.status == 200
    end

    test "ignores an Authorization header rather than validating it", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/api/openapi.json")

      assert conn.status == 200
    end
  end

  describe "respond/2" do
    test "returns a 500 JSON error and logs the reason when the spec cannot be read" do
      log =
        capture_log(fn ->
          conn = OpenApiController.respond(build_conn(), {:error, :enoent})

          assert conn.status == 500

          assert Jason.decode!(conn.resp_body) == %{
                   "error" => "OpenAPI specification unavailable"
                 }
        end)

      assert log =~ "OpenAPI spec unavailable"
      assert log =~ ":enoent"
    end
  end

  describe "OpenApiSpec" do
    test "path/0 points at priv/openapi/stride-api.json in the app dir" do
      assert OpenApiSpec.path() == Application.app_dir(:kanban, "priv/openapi/stride-api.json")
      assert File.exists?(OpenApiSpec.path())
    end

    test "fetch/0 returns the file contents and caches them in :persistent_term" do
      assert {:ok, body} = OpenApiSpec.fetch()
      assert body == File.read!(OpenApiSpec.path())
      assert :persistent_term.get({OpenApiSpec, :body}, nil) == body
      assert {:ok, ^body} = OpenApiSpec.fetch()
    end
  end
end
