defmodule KanbanWeb.Plugs.McpDiscoverySelectorTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.Plugs.McpDiscoverySelector

  defp call(body) do
    %{conn(:post, "/api/mcp") | body_params: body}
    |> McpDiscoverySelector.call(McpDiscoverySelector.init([]))
  end

  defp request(method), do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method}

  test "marks a body of discovery messages" do
    for body <- [
          request("initialize"),
          request("tools/list"),
          %{
            "_json" => [
              request("ping"),
              %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
            ]
          }
        ] do
      assert call(body).private[:stride_board_selector] == :when_named, inspect(body)
    end
  end

  test "leaves any other body unmarked" do
    for body <- [
          request("tools/call"),
          %{"_json" => [request("tools/list"), request("tools/call")]},
          %{},
          %Plug.Conn.Unfetched{aspect: :body_params}
        ] do
      refute Map.has_key?(call(body).private, :stride_board_selector), inspect(body)
    end
  end
end
