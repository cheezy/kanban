defmodule KanbanWeb.Plugs.ApiTelemetryRouterTest do
  @moduledoc """
  D370: `KanbanWeb.Plugs.ApiTelemetry` runs inside the `:api` and
  `:api_public` pipelines, so these tests drive the real endpoint and router
  and assert that the `:endpoint` tag on `[:kanban, :api, :request]` and
  `[:kanban, :api, :error]` is the matched route template. Phoenix ignores
  empty path segments when matching, so slash variants of one route used to
  reach the plug with a different raw path each; they must now all emit one
  value, with or without a valid token.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.TelemetryHelpers

  @request [:kanban, :api, :request]
  @error [:kanban, :api, :error]

  setup do
    attach_telemetry([@request, @error])
    :ok
  end

  defp json_conn, do: put_req_header(build_conn(), "accept", "application/json")

  defp receive_endpoints(count) do
    for _ <- 1..count do
      assert_receive {:telemetry_event, @request, %{count: 1}, %{endpoint: endpoint}}
      endpoint
    end
  end

  test "slash variants of a matched route emit one endpoint value" do
    paths = [
      "/api/openapi.json",
      "/api/openapi.json/",
      "/api//openapi.json",
      "/api///openapi.json//",
      "/api/openapi.json////"
    ]

    for path <- paths do
      conn = get(json_conn(), path)
      assert conn.status == 200, "#{path} returned #{conn.status}"
    end

    assert receive_endpoints(length(paths)) |> Enum.uniq() == ["/api/openapi.json"]
  end

  test "slash variants of an unauthenticated MCP request emit one endpoint value" do
    paths = ["/api/mcp", "/api/mcp/", "/api///mcp", "/api/mcp//////"]

    for path <- paths do
      conn = post(json_conn(), path, %{})
      assert conn.status == 401, "#{path} returned #{conn.status}"
    end

    assert receive_endpoints(length(paths)) |> Enum.uniq() == ["/api/mcp"]

    for _ <- paths do
      assert_receive {:telemetry_event, @error, %{count: 1},
                      %{endpoint: "/api/mcp", status: 401, method: "POST"}}
    end
  end

  test "percent-encoded spellings of a matched route emit its template" do
    for path <- ["/api/openapi%2Ejson", "/%61pi/openapi.json", "/api//openapi%2ejson/"] do
      conn = get(json_conn(), path)
      assert conn.status == 200, "#{path} returned #{conn.status}"
    end

    assert receive_endpoints(3) |> Enum.uniq() == ["/api/openapi.json"]

    conn = get(json_conn(), "/api/tasks/n%65xt")
    assert conn.status == 401

    assert_receive {:telemetry_event, @error, _, %{endpoint: "/api/tasks/next", status: 401}}
  end

  test "unauthenticated token-route request emits the route template" do
    conn = get(json_conn(), "/api/tasks")
    assert conn.status == 401

    assert_receive {:telemetry_event, @request, _,
                    %{endpoint: "/api/tasks", method: "GET", status: 401}}

    assert_receive {:telemetry_event, @error, %{count: 1},
                    %{endpoint: "/api/tasks", method: "GET", status: 401}}
  end

  test "an unauthenticated task action emits the template, not the identifier" do
    conn = patch(json_conn(), "/api/tasks/W-caller-chosen-123/complete", %{})
    assert conn.status == 401

    assert_receive {:telemetry_event, @error, _, %{endpoint: "/api/tasks/:id/complete"}}
  end

  test "a path with no route emits no api event" do
    conn = get(json_conn(), "/api/d370-no-such-route")
    assert conn.status == 404

    refute_received {:telemetry_event, @request, _, _}
    refute_received {:telemetry_event, @error, _, _}
  end
end
