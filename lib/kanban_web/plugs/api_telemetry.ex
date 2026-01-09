defmodule KanbanWeb.Plugs.ApiTelemetry do
  @moduledoc """
  Plug to emit telemetry events for API requests.
  Tracks request count, duration, and errors for all API endpoints.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time()

    conn
    |> register_before_send(fn conn ->
      duration = System.monotonic_time() - start_time
      endpoint = extract_endpoint(conn)
      status = conn.status

      # Emit request count and duration
      :telemetry.execute(
        [:kanban, :api, :request],
        %{count: 1, duration: duration},
        %{endpoint: endpoint, method: conn.method, status: status}
      )

      # Emit error count if status >= 400
      if status >= 400 do
        :telemetry.execute(
          [:kanban, :api, :error],
          %{count: 1},
          %{endpoint: endpoint, status: status, method: conn.method}
        )
      end

      conn
    end)
  end

  defp extract_endpoint(conn) do
    case conn.path_info do
      ["api", "tasks" | rest] -> extract_tasks_endpoint(rest)
      ["api", "agent" | rest] -> extract_agent_endpoint(rest)
      _ -> conn.request_path
    end
  end

  defp extract_tasks_endpoint([]), do: "/api/tasks"
  defp extract_tasks_endpoint(["next"]), do: "/api/tasks/next"
  defp extract_tasks_endpoint(["batch"]), do: "/api/tasks/batch"
  defp extract_tasks_endpoint(["claim"]), do: "/api/tasks/claim"
  defp extract_tasks_endpoint([_id]), do: "/api/tasks/:id"
  defp extract_tasks_endpoint([_id, action]), do: "/api/tasks/:id/#{action}"

  defp extract_agent_endpoint(["onboarding"]), do: "/api/agent/onboarding"
  defp extract_agent_endpoint(_), do: "/api/agent"
end
