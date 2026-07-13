defmodule KanbanWeb.Plugs.RemoteClientIpTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Plugs.RemoteClientIp

  describe "call/2" do
    test "sets remote_ip from a valid Fly-Client-IP header", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call([])

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "parses an IPv6 Fly-Client-IP", %{conn: conn} do
      conn =
        conn
        |> put_req_header("fly-client-ip", "2001:db8::1")
        |> RemoteClientIp.call([])

      assert conn.remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "leaves remote_ip untouched when the header is absent", %{conn: conn} do
      conn = Map.put(conn, :remote_ip, {10, 0, 0, 5})
      assert RemoteClientIp.call(conn, []).remote_ip == {10, 0, 0, 5}
    end

    test "leaves remote_ip untouched when the header is not a valid IP", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 5})
        |> put_req_header("fly-client-ip", "not-an-ip")
        |> RemoteClientIp.call([])

      assert conn.remote_ip == {10, 0, 0, 5}
    end

    test "stashes the resolved IP in the session when a session is available", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call([])

      assert get_session(conn, :client_ip) == "203.0.113.7"
    end

    test "does not crash when no session is present (API pipeline)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call([])

      assert conn.remote_ip == {203, 0, 113, 7}
    end
  end
end
