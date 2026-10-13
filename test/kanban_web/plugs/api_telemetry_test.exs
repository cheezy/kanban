defmodule KanbanWeb.Plugs.ApiTelemetryTest do
  @moduledoc """
  Tests for how `KanbanWeb.Plugs.ApiTelemetry` picks the `:endpoint` tag.
  The plug registers a before-send hook that emits `[:kanban, :api, :request]`
  (and `[:kanban, :api, :error]` for a status of 400 or above). `:endpoint` is
  a metric tag, so it must be the matched route template or the fixed
  `"unmatched"` sentinel, never the path the caller sent (D370).

  These tests call the plug directly on `Plug.Test` conns. A conn that has
  been through the router carries `:phoenix_router` in `conn.private`, so the
  matched-route cases put it there; `api_telemetry_router_test.exs` covers
  the same rule through the real router.
  """
  use ExUnit.Case, async: true

  import Kanban.TelemetryHelpers

  alias KanbanWeb.Plugs.ApiTelemetry

  @request [:kanban, :api, :request]
  @error [:kanban, :api, :error]

  setup do
    attach_telemetry([@request, @error])
    :ok
  end

  defp run(method, path, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    method
    |> Plug.Test.conn(path)
    |> maybe_put_router(Keyword.get(opts, :router, KanbanWeb.Router))
    |> ApiTelemetry.call([])
    |> Plug.Conn.send_resp(status, "ok")
  end

  defp maybe_put_router(conn, nil), do: conn
  defp maybe_put_router(conn, router), do: Plug.Conn.put_private(conn, :phoenix_router, router)

  defp assert_endpoint(expected) do
    assert_receive {:telemetry_event, @request, %{count: 1}, %{endpoint: ^expected}}
  end

  describe "a matched route" do
    test "emits the route template for a matched route" do
      run(:get, "/api/tasks/next")
      assert_endpoint("/api/tasks/next")

      run(:patch, "/api/tasks/W1/complete")
      assert_endpoint("/api/tasks/:id/complete")

      run(:get, "/api/tasks/W42")
      assert_endpoint("/api/tasks/:id")
    end

    test "keeps the existing endpoint values for real routes" do
      for {method, path, expected} <- [
            {:get, "/api/tasks", "/api/tasks"},
            {:post, "/api/tasks/claim", "/api/tasks/claim"},
            {:post, "/api/tasks/batch", "/api/tasks/batch"},
            {:get, "/api/agent/onboarding", "/api/agent/onboarding"},
            {:get, "/api/openapi.json", "/api/openapi.json"},
            {:post, "/api/mcp", "/api/mcp"}
          ] do
        run(method, path)
        assert_endpoint(expected)
      end
    end

    test "does not interpolate the identifier or action into the tag" do
      run(:get, "/api/tasks/W1/tree")
      assert_endpoint("/api/tasks/:id/tree")
      refute_received {:telemetry_event, @request, _, %{endpoint: "/api/tasks/W1/tree"}}
    end

    test "distinct caller-chosen path variants produce one endpoint value" do
      paths = [
        "/api/openapi.json",
        "/api/openapi.json/",
        "/api//openapi.json",
        "/api///openapi.json//",
        "/api/openapi.json////"
      ]

      for path <- paths, do: run(:get, path)

      endpoints =
        for _path <- paths do
          assert_receive {:telemetry_event, @request, _, %{endpoint: endpoint}}
          endpoint
        end

      assert Enum.uniq(endpoints) == ["/api/openapi.json"]
    end

    test "percent-encoded literal segments resolve to the route the router serves" do
      # The router decodes segments before matching, so these are the same
      # routes as their plain spellings.
      run(:get, "/api/openapi%2Ejson")
      assert_endpoint("/api/openapi.json")

      run(:get, "/%61pi/agent/onboarding")
      assert_endpoint("/api/agent/onboarding")

      # Without decoding this would match the show route as id "n%65xt".
      run(:get, "/api/tasks/n%65xt")
      assert_endpoint("/api/tasks/next")

      run(:patch, "/api/tasks/W1/%63omplete")
      assert_endpoint("/api/tasks/:id/complete")
    end

    test "very long or non-UTF-8 path segments never reach the tag" do
      long_id = String.duplicate("x", 10_000)

      run(:patch, "/api/tasks/#{long_id}/complete")
      assert_endpoint("/api/tasks/:id/complete")

      run(:get, "/api/tasks/%FF%FE")
      assert_endpoint("/api/tasks/:id")

      run(:get, "/api/#{long_id}")
      assert_endpoint("unmatched")

      raw_long = "/api/#{long_id}"
      refute_received {:telemetry_event, _, _, %{endpoint: ^raw_long}}
    end

    test "a malformed percent escape in a literal segment emits unmatched without raising" do
      run(:get, "/api/tasks/W1/%ZZ")
      assert_endpoint("unmatched")
    end
  end

  describe "api.error" do
    test "api.error carries the bounded endpoint and never the raw path" do
      run(:get, "/api//mcp/", status: 405)

      assert_receive {:telemetry_event, @request, _, %{endpoint: "/api/mcp", status: 405}}

      assert_receive {:telemetry_event, @error, %{count: 1},
                      %{endpoint: "/api/mcp", status: 405, method: "GET"}}

      run(:post, "/api///mcp//", status: 401)

      assert_receive {:telemetry_event, @error, %{count: 1},
                      %{endpoint: "/api/mcp", status: 401, method: "POST"}}

      run(:get, "/api/no-such-route-123", status: 404)

      assert_receive {:telemetry_event, @error, %{count: 1},
                      %{endpoint: "unmatched", status: 404, method: "GET"}}

      refute_received {:telemetry_event, _, _, %{endpoint: "/api/no-such-route-123"}}
    end

    test "a status below 400 emits no api.error" do
      run(:get, "/api/tasks/next")
      assert_endpoint("/api/tasks/next")
      refute_received {:telemetry_event, @error, _, _}
    end
  end

  describe "no route" do
    test "emits unmatched when no route can be resolved" do
      # Paths the old fallback tagged with themselves or a made-up collapse.
      run(:get, "/health")
      assert_endpoint("unmatched")

      run(:get, "/api/agent/42/settings")
      assert_endpoint("unmatched")

      run(:get, "/api/random-123")
      assert_endpoint("unmatched")

      # A method the path has no route for.
      run(:delete, "/api/tasks/next")
      assert_endpoint("unmatched")
    end

    test "emits unmatched without raising when the conn has no router" do
      run(:get, "/api/tasks/next", router: nil)
      assert_endpoint("unmatched")

      run(:get, "/some/raw/path", router: nil, status: 404)

      assert_receive {:telemetry_event, @error, _,
                      %{endpoint: "unmatched", status: 404, method: "GET"}}
    end
  end
end
