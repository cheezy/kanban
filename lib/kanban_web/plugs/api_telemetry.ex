defmodule KanbanWeb.Plugs.ApiTelemetry do
  @moduledoc """
  Plug to emit telemetry events for API requests.
  Tracks request count, duration, and errors for all API endpoints.

  The `endpoint` metadata is a metric tag, so its set of values must stay
  small and fixed. It is the template of the route the router matched, such
  as `"/api/tasks/:id/complete"`, or the fixed string `"unmatched"` when there
  is no router on the conn or the route cannot be resolved. It is never built
  from the path the caller sent, so slash variants such as `/api///mcp//`,
  percent-encoded spellings such as `/api/openapi%2Ejson` and any identifier
  in the path collapse to one value. A request that matches no route never
  reaches this plug: the router rejects it first.
  """
  import Plug.Conn

  @unmatched "unmatched"

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time()

    conn
    |> register_before_send(fn conn ->
      duration = System.monotonic_time() - start_time
      endpoint = endpoint_tag(conn)
      status = conn.status

      # Emit request count and duration
      Kanban.Telemetry.emit(
        [:kanban, :api, :request],
        %{count: 1, duration: duration},
        %{endpoint: endpoint, method: conn.method, status: status}
      )

      # Emit error count if status >= 400
      if status >= 400 do
        Kanban.Telemetry.emit(
          [:kanban, :api, :error],
          %{count: 1},
          %{endpoint: endpoint, status: status, method: conn.method}
        )
      end

      conn
    end)
  end

  # The router percent-decodes each path segment before it matches a route
  # (Phoenix.Router call/2), so the lookup decodes them the same way. Without
  # that, /api/openapi%2Ejson is served by the openapi route but looked up as
  # no route, and /api/tasks/n%65xt would be tagged with the show route.
  defp endpoint_tag(%Plug.Conn{private: %{phoenix_router: router}} = conn)
       when is_atom(router) and not is_nil(router) do
    segments = Enum.map(conn.path_info, &URI.decode/1)

    router
    |> Phoenix.Router.route_info(conn.method, segments, conn.host)
    |> route_template()
  end

  defp endpoint_tag(_conn), do: @unmatched

  defp route_template(%{route: route}) when is_binary(route), do: route
  defp route_template(_no_route), do: @unmatched
end
