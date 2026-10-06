defmodule KanbanWeb.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MCP.Server

  # Only tools/call needs a real conn; every method under test here never
  # touches it.
  @conn %Plug.Conn{}

  defp request(method, params \\ %{}, id \\ 7),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp handle(method, params \\ %{}, id \\ 7),
    do: method |> request(params, id) |> Server.handle_message(@conn)

  defp payload(method), do: method |> request() |> Server.handle_payload(@conn)

  describe "handle_message/2" do
    test "initialize negotiates the protocol version" do
      for version <- Server.supported_versions() do
        %{result: result} =
          handle("initialize", %{"protocolVersion" => version})

        assert result.protocolVersion == version
      end

      %{result: result} = handle("initialize", %{})
      assert result.protocolVersion == hd(Server.supported_versions())
      assert result.serverInfo.name == "stride"
      assert result.capabilities == %{tools: %{listChanged: false}}
    end

    test "ping returns an empty result with the request id" do
      assert handle("ping", %{}, "abc") ==
               %{jsonrpc: "2.0", id: "abc", result: %{}}
    end

    test "tools/list returns the tool definitions" do
      %{result: %{tools: tools}} = handle("tools/list")
      assert length(tools) == 6
    end

    test "an unknown method is -32601" do
      assert %{id: 7, error: %{code: -32_601, message: "Method not found"}} =
               handle("sampling/createMessage")
    end

    test "tools/call without a name or with non-object arguments is -32602" do
      assert %{error: %{code: -32_602}} = handle("tools/call", %{})

      assert %{error: %{code: -32_602}} =
               handle("tools/call", %{"name" => "stride_get_task", "arguments" => [1]})
    end

    test "notifications and client responses need no response" do
      assert Server.handle_message(
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               @conn
             ) == nil

      assert Server.handle_message(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}, @conn) ==
               nil
    end

    test "an invalid message is -32600" do
      assert %{id: nil, error: %{code: -32_600}} = Server.handle_message("ping", @conn)

      assert %{id: 3, error: %{code: -32_600}} =
               Server.handle_message(%{"id" => 3, "method" => "ping"}, @conn)
    end
  end

  describe "handle_payload/2" do
    test "a single request replies 200" do
      assert {:reply, 200, %{result: %{}}} = payload("ping")
    end

    test "a single notification is accepted" do
      assert Server.handle_payload(
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               @conn
             ) ==
               :accepted
    end

    test "batches reply only for requests" do
      assert {:reply, 200, [%{id: 1}]} =
               Server.handle_payload(
                 %{"_json" => [request("ping", %{}, 1), %{"jsonrpc" => "2.0", "method" => "n"}]},
                 @conn
               )
    end

    test "an empty body, an empty batch or a non-list _json is -32600" do
      for body <- [
            %{},
            %{"_json" => []},
            %{"_json" => "x"},
            %Plug.Conn.Unfetched{aspect: :body_params}
          ] do
        assert {:reply, 400, %{error: %{code: -32_600}}} = Server.handle_payload(body, @conn)
      end
    end
  end
end
