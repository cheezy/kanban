defmodule KanbanWeb.Plugs.RemoteClientIp do
  @moduledoc """
  Resolves the real client IP when running behind the Fly.io proxy and writes
  it to `conn.remote_ip`, so IP-keyed rate limiting (`Kanban.RateLimit`) sees
  the actual client rather than the proxy's edge address.

  Fly sets the `Fly-Client-IP` request header to the connecting client's IP on
  every proxied request and strips any client-supplied value, so — unlike a
  raw `X-Forwarded-For` — it cannot be spoofed through the proxy and needs no
  trusted-hop configuration. When the header is absent (local dev, direct
  connections, non-Fly deploys) `conn.remote_ip` is left untouched.

  When a session is available (the `:browser` pipeline), the resolved IP is
  also stashed in the session as `client_ip` so LiveView mounts can read it via
  `connect_info` — the LiveView websocket upgrade's `:peer_data` is the proxy,
  not the client. See `KanbanWeb.ClientIp`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case client_ip(conn) do
      nil -> conn
      ip -> conn |> put_remote_ip(ip) |> maybe_stash_in_session(ip)
    end
  end

  defp client_ip(conn) do
    with [value | _] <- get_req_header(conn, "fly-client-ip"),
         charlist = value |> String.trim() |> String.to_charlist(),
         {:ok, address} <- :inet.parse_address(charlist) do
      address
    else
      _ -> nil
    end
  end

  defp put_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  # Only when the session plug has already run (browser pipeline). The API
  # pipeline has no session, so we skip it there.
  defp maybe_stash_in_session(conn, ip) do
    if session_fetched?(conn) do
      put_session(conn, :client_ip, ip |> :inet.ntoa() |> to_string())
    else
      conn
    end
  end

  defp session_fetched?(conn) do
    match?(%{}, conn.private[:plug_session])
  end
end
