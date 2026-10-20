defmodule KanbanWeb.MCP.ServerDiscoveryTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MCP.JsonRpc
  alias KanbanWeb.MCP.Server

  defp request(method, id \\ 1), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}
  defp notification(method), do: %{"jsonrpc" => "2.0", "method" => method}

  describe "discovery_payload?/1" do
    test "is true for initialize, ping, tools/list, notifications and responses" do
      for body <- [
            request("initialize"),
            request("ping", "abc"),
            request("tools/list"),
            notification("notifications/initialized"),
            notification("notifications/cancelled"),
            %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}},
            %{"_json" => [request("initialize"), notification("notifications/initialized")]}
          ] do
        assert Server.discovery_payload?(body), inspect(body)
      end
    end

    test "is true for a batch of exactly 50 discovery messages and false for 51" do
      assert Server.discovery_payload?(%{"_json" => for(i <- 1..50, do: request("ping", i))})
      refute Server.discovery_payload?(%{"_json" => for(i <- 1..51, do: request("ping", i))})
    end

    test "is false when any message calls a tool, is unknown or is invalid" do
      for body <- [
            request("tools/call"),
            request("resources/list"),
            %{"_json" => [request("tools/list"), request("tools/call", 2)]},
            %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => "x"},
            %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
            %{"_json" => [request("ping"), 42]}
          ] do
        refute Server.discovery_payload?(body), inspect(body)
      end
    end

    test "is false for an empty body, an empty batch and a non-batch _json" do
      for body <- [%{}, %{"_json" => []}, %{"_json" => "ping"}, nil, "ping"] do
        refute Server.discovery_payload?(body), inspect(body)
      end
    end
  end

  describe "a request without a board" do
    setup do
      %{conn: %Plug.Conn{assigns: %{}}}
    end

    test "answers tools/list without a plan check", %{conn: conn} do
      assert %{result: %{tools: [_ | _]}} =
               "tools/list" |> request() |> Server.handle_message(conn)
    end

    test "refuses tools/call with -32600 and runs no tool", %{conn: conn} do
      message = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "stride_list_tasks", "arguments" => %{}}
      }

      invalid_request = JsonRpc.invalid_request()

      assert %{id: 3, error: %{code: ^invalid_request, message: text}} =
               Server.handle_message(message, conn)

      assert text =~ "X-Stride-Board"
    end
  end
end
