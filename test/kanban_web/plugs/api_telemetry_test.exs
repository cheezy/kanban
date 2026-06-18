defmodule KanbanWeb.Plugs.ApiTelemetryTest do
  @moduledoc """
  Tests for the endpoint-normalization logic in
  `KanbanWeb.Plugs.ApiTelemetry`. The plug registers a before-send hook
  that emits a `[:kanban, :api, :request]` telemetry event whose
  `:endpoint` metadata is the normalized route. We attach a handler and
  assert on that metadata after sending the response.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Plugs.ApiTelemetry

  setup do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:kanban, :api, :request],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:api_request, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp run(path) do
    :get
    |> Plug.Test.conn(path)
    |> ApiTelemetry.call([])
    |> Plug.Conn.send_resp(200, "ok")
  end

  test "normalizes a known tasks endpoint" do
    run("/api/tasks/next")
    assert_receive {:api_request, %{endpoint: "/api/tasks/next"}}
  end

  test "collapses the agent onboarding endpoint" do
    run("/api/agent/onboarding")
    assert_receive {:api_request, %{endpoint: "/api/agent/onboarding"}}
  end

  test "collapses unrecognized agent subpaths to /api/agent" do
    run("/api/agent/42/settings")
    assert_receive {:api_request, %{endpoint: "/api/agent"}}
  end

  test "falls back to the raw request path for non-API routes" do
    run("/health")
    assert_receive {:api_request, %{endpoint: "/health"}}
  end
end
