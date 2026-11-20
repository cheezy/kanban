defmodule KanbanWeb.UserAuth.ReturnToTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.UserAuth.ReturnTo

  setup %{conn: conn} do
    %{conn: init_test_session(conn, %{})}
  end

  # A request for /foo whose path, query string included, is `bytes` long.
  defp request(conn, bytes, method \\ "GET") do
    query = String.duplicate("q", bytes - byte_size("/foo?"))
    %{conn | method: method, path_info: ["foo"], request_path: "/foo", query_string: query}
  end

  describe "storable?/1 and maybe_store/1" do
    test "a path of max_bytes is stored, one byte more is not", %{conn: conn} do
      max = ReturnTo.max_bytes()
      fits = request(conn, max)
      too_long = request(conn, max + 1)

      assert ReturnTo.storable?(fits)
      refute ReturnTo.storable?(too_long)

      assert fits |> ReturnTo.maybe_store() |> get_session(:user_return_to) ==
               "/foo?" <> fits.query_string

      assert too_long |> ReturnTo.maybe_store() |> get_session(:user_return_to) == nil
    end

    test "a request other than a GET stores nothing", %{conn: conn} do
      assert conn |> request(20, "POST") |> ReturnTo.maybe_store() |> get_session(:user_return_to) ==
               nil
    end
  end

  describe "a signed-out visit to a very long URL" do
    test "still goes to log in, without a return-to, and never overflows the cookie" do
      conn = get(build_conn(), "/boards?" <> String.duplicate("filter=x&", 600))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == nil

      for cookie <- get_resp_header(conn, "set-cookie"),
          do: assert(byte_size(cookie) <= 4096)
    end

    test "a short one is still brought back after signing in" do
      conn = get(build_conn(), "/boards?filter=x")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/boards?filter=x"
    end
  end
end
