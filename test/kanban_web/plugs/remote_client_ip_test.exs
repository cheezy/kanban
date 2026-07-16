defmodule KanbanWeb.Plugs.RemoteClientIpTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Plugs.RemoteClientIp

  # The header is only trusted when trust is explicitly enabled (D157). Tests
  # that exercise the honored path pass the plug option directly, which keeps
  # the suite async-safe (no global Application.put_env).
  @trust [trust_fly_client_ip: true]

  describe "call/2 when the Fly-Client-IP header is trusted" do
    test "sets remote_ip from a valid Fly-Client-IP header", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call(@trust)

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "parses an IPv6 Fly-Client-IP", %{conn: conn} do
      conn =
        conn
        |> put_req_header("fly-client-ip", "2001:db8::1")
        |> RemoteClientIp.call(@trust)

      assert conn.remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "leaves remote_ip untouched when the header is absent", %{conn: conn} do
      conn = Map.put(conn, :remote_ip, {10, 0, 0, 5})
      assert RemoteClientIp.call(conn, @trust).remote_ip == {10, 0, 0, 5}
    end

    test "leaves remote_ip untouched when the header is not a valid IP", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 5})
        |> put_req_header("fly-client-ip", "not-an-ip")
        |> RemoteClientIp.call(@trust)

      assert conn.remote_ip == {10, 0, 0, 5}
    end

    test "stashes the resolved IP in the session when a session is available", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call(@trust)

      assert get_session(conn, :client_ip) == "203.0.113.7"
    end

    test "does not crash when no session is present (API pipeline)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call(@trust)

      assert conn.remote_ip == {203, 0, 113, 7}
    end
  end

  describe "call/2 when trust is disabled (default, off-Fly-edge — D157)" do
    test "ignores a spoofable Fly-Client-IP header and keeps the socket peer", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {10, 0, 0, 5})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call([])

      # Untrusted deployment: the header must not override the real peer.
      assert conn.remote_ip == {10, 0, 0, 5}
    end

    test "does not stash a client_ip in the session when trust is off", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("fly-client-ip", "203.0.113.7")
        |> RemoteClientIp.call([])

      assert get_session(conn, :client_ip) == nil
    end
  end
end
