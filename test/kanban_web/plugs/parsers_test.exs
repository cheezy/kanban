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
end
