defmodule KanbanWeb.UserAuth.LiveSessions do
  @moduledoc """
  The LiveView side of a session token: the PubSub topic its pages join, and
  disconnecting them. `KanbanWeb.UserAuth` delegates its public
  `disconnect_sessions/1` and `disconnect_live_sessions/1` here.
  """

  @doc "The `live_socket_id` topic of the pages opened under session `token`."
  def topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Disconnects existing sockets for the given tokens.

  Emits `[:kanban, :user, :sessions_revoked]` with `count` set to the number of
  tokens, which may be 0, and the `user_id` of the first token that has one.
  """
  def disconnect_sessions(tokens) do
    disconnect_live_sessions(tokens)
    emit_sessions_revoked(length(tokens), Enum.find_value(tokens, &Map.get(&1, :user_id)))
  end

  @doc """
  Disconnects the open LiveView sockets of the given session tokens without
  revoking them and without telemetry. Each reconnect re-checks its session, so
  a user disabled in the meantime is signed out and a still-valid session
  reconnects as before.
  """
  def disconnect_live_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      KanbanWeb.Endpoint.broadcast(topic(token), "disconnect", %{})
    end)
  end

  defp emit_sessions_revoked(count, nil) do
    Kanban.Telemetry.emit([:kanban, :user, :sessions_revoked], %{count: count}, %{})
  end

  defp emit_sessions_revoked(count, user_id) do
    Kanban.Telemetry.emit([:kanban, :user, :sessions_revoked], %{count: count}, %{
      user_id: user_id
    })
  end
end
