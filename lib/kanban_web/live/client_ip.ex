defmodule KanbanWeb.ClientIp do
  @moduledoc """
  Extracts the client IP for a LiveView's rate-limiting keys.

  Prefers the `client_ip` value that `KanbanWeb.Plugs.RemoteClientIp` stashes in
  the session (the real client IP behind the Fly proxy), since the websocket
  upgrade's `:peer_data` is the proxy's edge address, not the client. Falls back
  to `:peer_data` for direct connections / local dev.

  The session is delivered to `mount/3` as its second argument, so callers pass
  it in. On the initial (disconnected) static render there is no connect info
  yet; the connected re-mount fills in the peer fallback. `Kanban.RateLimit`
  tolerates a `nil`/unknown IP.
  """

  @spec from_session_or_socket(map(), Phoenix.LiveView.Socket.t()) ::
          :inet.ip_address() | String.t() | nil
  def from_session_or_socket(session, socket) do
    case session do
      %{"client_ip" => ip} when is_binary(ip) -> ip
      _ -> peer_address(socket)
    end
  end

  defp peer_address(socket) do
    if Phoenix.LiveView.connected?(socket) do
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> nil
      end
    end
  end
end
