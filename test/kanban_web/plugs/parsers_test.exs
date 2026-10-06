defmodule KanbanWeb.Plugs.ParsersTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.Plugs.Parsers

  @opts Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

  test "an /api parse failure is re-raised as a WrapperError with the json format pinned" do
    conn = conn(:get, "/api/tasks?a=%FF")

    error = assert_raise Plug.Conn.WrapperError, fn -> Parsers.call(conn, @opts) end

    assert %Plug.Conn.InvalidQueryError{} = error.reason
    assert error.kind == :error
    assert Phoenix.Controller.get_format(error.conn) == "json"
    assert Plug.Exception.status(error.reason) == 400
  end

  test "an /api malformed JSON body keeps its status and gets the json format" do
    conn =
      :post
      |> conn("/api/tasks", "{not json")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    error = assert_raise Plug.Conn.WrapperError, fn -> Parsers.call(conn, @opts) end

    assert %Plug.Parsers.ParseError{} = error.reason
    assert Plug.Exception.status(error.reason) == 400
    assert Phoenix.Controller.get_format(error.conn) == "json"
  end

  test "a non-/api parse failure is raised as-is, without a format" do
    conn = conn(:get, "/about?a=%FF")

    assert_raise Plug.Conn.InvalidQueryError, fn -> Parsers.call(conn, @opts) end
  end

  test "a request that parses cleanly gets its params and no pinned format" do
    for path <- ["/api/tasks?a=%41", "/about?a=%41"] do
      conn = :get |> conn(path) |> Parsers.call(@opts)

      assert conn.params == %{"a" => "A"}
      refute Map.has_key?(conn.private, :phoenix_format)
    end
  end

  describe "POST /api/mcp (W2231)" do
    defp mcp_conn(method, path, body, content_type \\ "application/json") do
      method
      |> conn(path, body)
      |> Plug.Conn.put_req_header("content-type", content_type)
    end

    test "a malformed JSON body is flagged, not raised, with an empty body and the query params" do
      conn = :post |> mcp_conn("/api/mcp?x=1", "{not json") |> Parsers.call(@opts)

      assert conn.private[:kanban_mcp_parse_error] == true
      assert conn.body_params == %{}
      assert conn.params == %{"x" => "1"}
      refute Map.has_key?(conn.private, :phoenix_format)
    end

    test "a well-formed body parses normally and is not flagged" do
      conn =
        :post
        |> mcp_conn("/api/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
        |> Parsers.call(@opts)

      refute conn.private[:kanban_mcp_parse_error]
      assert conn.body_params == %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
    end

    test "a batch array arrives under _json" do
      conn =
        :post
        |> mcp_conn("/api/mcp", ~s([{"jsonrpc":"2.0","method":"ping","id":1}]))
        |> Parsers.call(@opts)

      assert %{"_json" => [%{"method" => "ping"}]} = conn.body_params
    end

    test "a malformed body on another /api route or verb still raises" do
      for {method, path} <- [{:post, "/api/tasks"}, {:put, "/api/mcp"}, {:post, "/api/mcp/extra"}] do
        error =
          assert_raise Plug.Conn.WrapperError, fn ->
            method |> mcp_conn(path, "{not json") |> Parsers.call(@opts)
          end

        assert %Plug.Parsers.ParseError{} = error.reason
      end
    end

    test "a malformed query string on /api/mcp still raises as a 400" do
      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          :post |> mcp_conn("/api/mcp?a=%FF", "{}") |> Parsers.call(@opts)
        end

      assert %Plug.Conn.InvalidQueryError{} = error.reason
    end

    test "an oversized body on /api/mcp still raises 413" do
      opts = Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason, length: 10)

      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          :post |> mcp_conn("/api/mcp", String.duplicate("x", 100)) |> Parsers.call(opts)
        end

      assert Plug.Exception.status(error.reason) == 413
    end
  end
end
