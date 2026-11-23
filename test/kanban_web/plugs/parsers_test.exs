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

  test "a /scim malformed JSON body keeps its status and gets the scim format (W2247)" do
    conn =
      :post
      |> conn("/scim/v2/Users", "{not json")
      |> Plug.Conn.put_req_header("content-type", "application/scim+json")

    error = assert_raise Plug.Conn.WrapperError, fn -> Parsers.call(conn, @opts) end

    assert %Plug.Parsers.ParseError{} = error.reason
    assert Plug.Exception.status(error.reason) == 400
    assert Phoenix.Controller.get_format(error.conn) == "scim"
  end

  test "a /scim+json body that parses cleanly is read as JSON (W2247)" do
    conn =
      :post
      |> conn("/scim/v2/Users", ~s({"userName":"a@b.c"}))
      |> Plug.Conn.put_req_header("content-type", "application/scim+json")
      |> Parsers.call(@opts)

    assert conn.body_params == %{"userName" => "a@b.c"}
    refute Map.has_key?(conn.private, :phoenix_format)
  end

  test "a signing-keys parse failure is re-raised with the json format pinned (W2697)" do
    for path <- [
          "/.well-known/stride-audit-signing-keys?format=pem&kid=%FF",
          "/.well-known/stride-audit-signing-keys/?kid=%FF"
        ] do
      conn = conn(:get, path)

      error = assert_raise Plug.Conn.WrapperError, fn -> Parsers.call(conn, @opts) end

      assert %Plug.Conn.InvalidQueryError{} = error.reason
      assert Phoenix.Controller.get_format(error.conn) == "json"
      assert Plug.Exception.status(error.reason) == 400
    end
  end

  test "a device token endpoint parse failure gets the json pin (W2746)" do
    for path <- ["/oauth/token", "/oauth/revoke"] do
      conn =
        :post
        |> conn(path, "{not json")
        |> Plug.Conn.put_req_header("content-type", "application/json")

      error = assert_raise Plug.Conn.WrapperError, fn -> Parsers.call(conn, @opts) end

      assert %Plug.Parsers.ParseError{} = error.reason
      assert Phoenix.Controller.get_format(error.conn) == "json"
    end
  end

  # D462: the person API and the device sign-in token API are pinned to json
  # before parsing, so a path no route matches renders its 404 as JSON.
  test "an /api/me or /oauth request that parses cleanly is pinned to json with its headers" do
    for {path, headers} <- [
          {"/api/me/no-such-route", [{"cache-control", "private, no-store"}]},
          {"/%61pi/me", [{"cache-control", "private, no-store"}]},
          {"/oauth/nope", [{"cache-control", "no-store"}, {"pragma", "no-cache"}]},
          {"/oauth/token", [{"cache-control", "no-store"}, {"pragma", "no-cache"}]},
          {"/%6Fauth/nope", [{"cache-control", "no-store"}, {"pragma", "no-cache"}]}
        ] do
      conn = :get |> conn(path <> "?a=%41") |> Parsers.call(@opts)

      assert conn.params == %{"a" => "A"}, path
      assert Phoenix.Controller.get_format(conn) == "json", path

      for {name, value} <- headers do
        assert Plug.Conn.get_resp_header(conn, name) == [value], "#{path} #{name}"
      end
    end
  end

  test "an unrouted /oauth path parse failure gets the json pin and no-store (D462)" do
    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        :get |> conn("/oauth/nope?a=%FF") |> Parsers.call(@opts)
      end

    assert %Plug.Conn.InvalidQueryError{} = error.reason
    assert Phoenix.Controller.get_format(error.conn) == "json"
    assert Plug.Conn.get_resp_header(error.conn, "cache-control") == ["no-store"]
  end

  test "a percent-encoded /api prefix gets the json pin on a parse failure (D462)" do
    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        :get |> conn("/%61pi/tasks?a=%FF") |> Parsers.call(@opts)
      end

    assert Phoenix.Controller.get_format(error.conn) == "json"
  end

  test "a percent-encoded /api/mcp path is flagged like /api/mcp (D462)" do
    conn =
      :post
      |> conn("/%61pi/mcp", "{not json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Parsers.call(@opts)

    assert conn.private[:kanban_mcp_parse_error] == true
  end

  test "the authorize page gets no pin (W2746)" do
    conn = conn(:get, "/oauth/authorize?a=%FF")

    assert_raise Plug.Conn.InvalidQueryError, fn -> Parsers.call(conn, @opts) end

    clean = :get |> conn("/oauth/authorize?a=%41") |> Parsers.call(@opts)
    refute Map.has_key?(clean.private, :phoenix_format)
    assert Plug.Conn.get_resp_header(clean, "cache-control") != ["no-store"]
  end

  test "another /.well-known path gets no pin (W2697)" do
    conn = conn(:get, "/.well-known/security.txt?a=%FF")

    assert_raise Plug.Conn.InvalidQueryError, fn -> Parsers.call(conn, @opts) end
  end

  test "only the exact signing-keys path gets the json pin (W2724)" do
    for path <- [
          "/.well-known/stride-audit-signing-keys/extra?kid=%FF",
          "/.well-known/stride-audit-signing-keys.json?kid=%FF",
          "/.well-known/Stride-Audit-Signing-Keys?kid=%FF",
          "/.well-known/stride-audit-signing-keys-v2?kid=%FF"
        ] do
      conn = conn(:get, path)

      assert_raise Plug.Conn.InvalidQueryError, fn -> Parsers.call(conn, @opts) end
    end
  end

  test "a malformed percent escape on the signing-keys path parses as literal text (W2724)" do
    for path <- [
          "/.well-known/stride-audit-signing-keys?kid=%ZZ",
          "/.well-known/stride-audit-signing-keys?format=pem&kid=%ZZ",
          "/.well-known/stride-audit-signing-keys/?kid=%ZZ"
        ] do
      conn = :get |> conn(path) |> Parsers.call(@opts)

      assert conn.query_params["kid"] == "%ZZ"
      refute Map.has_key?(conn.private, :phoenix_format)
    end
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
