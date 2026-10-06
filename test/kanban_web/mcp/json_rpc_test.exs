defmodule KanbanWeb.MCP.JsonRpcTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MCP.JsonRpc

  describe "classify/1" do
    test "a request with a string or integer id" do
      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}) ==
               {:request, 1, "ping", %{}}

      assert JsonRpc.classify(%{
               "jsonrpc" => "2.0",
               "id" => "a",
               "method" => "x",
               "params" => %{"k" => 1}
             }) ==
               {:request, "a", "x", %{"k" => 1}}
    end

    test "a null params is treated as empty" do
      assert JsonRpc.classify(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "ping",
               "params" => nil
             }) ==
               {:request, 1, "ping", %{}}
    end

    test "a notification has no id" do
      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) ==
               {:notification, "notifications/initialized"}
    end

    test "a client response" do
      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}) == :response
      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{}}) == :response
    end

    test "null, float and object ids are invalid and never echoed" do
      for id <- [nil, 1.5, %{"a" => 1}, [1]] do
        assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}) ==
                 {:invalid, nil}
      end
    end

    test "a missing or wrong jsonrpc version, a non-string method or array params are invalid" do
      assert JsonRpc.classify(%{"id" => 1, "method" => "ping"}) == {:invalid, 1}

      assert JsonRpc.classify(%{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"}) ==
               {:invalid, 1}

      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => 5}) == {:invalid, 1}

      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => "x", "params" => [1]}) ==
               {:invalid, 1}

      assert JsonRpc.classify("ping") == {:invalid, nil}
      assert JsonRpc.classify(%{"id" => 1.5}) == {:invalid, nil}

      assert JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => nil, "result" => %{}}) ==
               {:invalid, nil}
    end
  end

  describe "builders" do
    test "result/2 and error/3,4" do
      assert JsonRpc.result(1, %{}) == %{jsonrpc: "2.0", id: 1, result: %{}}

      assert JsonRpc.error(nil, -32_700, "Parse error") ==
               %{jsonrpc: "2.0", id: nil, error: %{code: -32_700, message: "Parse error"}}

      assert JsonRpc.error(2, -32_602, "bad", %{errors: ["x"]}) ==
               %{
                 jsonrpc: "2.0",
                 id: 2,
                 error: %{code: -32_602, message: "bad", data: %{errors: ["x"]}}
               }
    end

    test "the standard error codes" do
      assert {JsonRpc.parse_error(), JsonRpc.invalid_request(), JsonRpc.method_not_found(),
              JsonRpc.invalid_params(), JsonRpc.server_error()} ==
               {-32_700, -32_600, -32_601, -32_602, -32_000}
    end
  end
end
