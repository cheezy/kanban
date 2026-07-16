defmodule KanbanWeb.Plugs.RemoteClientIp do
  @moduledoc """
  Resolves the real client IP when running behind the Fly.io proxy and writes
  it to `conn.remote_ip`, so IP-keyed rate limiting (`Kanban.RateLimit`) sees
  the actual client rather than the proxy's edge address.

  Fly sets the `Fly-Client-IP` request header to the connecting client's IP on
  every proxied request and strips any client-supplied value, so — behind the
  Fly edge — it cannot be spoofed. But that safety holds *only* when the Fly
  proxy is actually in front of the app: a request that reaches the app off the
  edge (6PN `.internal` reachability from another org app, an added front proxy
  that does not strip the header, or a future non-Fly deploy) could forge
  `Fly-Client-IP` and, since the resolved IP keys the auth rate limiter
  (`Kanban.RateLimit`) and the audit log (`Kanban.AuditLog`), rotate rate-limit
  buckets past the throttle or poison audit attribution.

  So the header is honored only when trust is explicitly enabled — via the
  `:trust_fly_client_ip` plug option, or the application config
  `config :kanban, #{inspect(__MODULE__)}, trust_fly_client_ip: true`. It
  defaults to **off** (fail-safe), and `config/runtime.exs` turns it on in
  production only when `FLY_APP_NAME` is set, i.e. only on a real Fly deploy.
  When trust is off, or the header is absent/invalid, `conn.remote_ip` is left
  as the real socket peer (D157).

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
  def call(conn, opts) do
    if trust_fly_client_ip?(opts) do
      case client_ip(conn) do
        nil -> conn
        ip -> conn |> put_remote_ip(ip) |> maybe_stash_in_session(ip)
      end
    else
      conn
    end
  end

  # The plug option wins if given; otherwise the application config, which
  # defaults to false so any deployment not explicitly behind the Fly edge
  # ignores the (spoofable) header and keeps the real socket peer.
  defp trust_fly_client_ip?(opts) do
    Keyword.get_lazy(opts, :trust_fly_client_ip, fn ->
      :kanban
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:trust_fly_client_ip, false)
    end)
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
