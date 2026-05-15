defmodule KanbanWeb.SandboxOnMount do
  @moduledoc """
  Test-only `on_mount` hook that lets a LiveView socket process share
  the test owner's Ecto sandbox connection.

  The endpoint passes the request's `user-agent` header through to the
  socket's `connect_info`. `Phoenix.Ecto.SQL.Sandbox.metadata_for/2`
  embeds the test owner's PID in that string, and
  `Phoenix.Ecto.SQL.Sandbox.allow/2` decodes it and grants the
  spawning process access to the same checked-out connection.

  Outside the test environment, the `:sql_sandbox` config flag is
  unset and this hook is a no-op.
  """

  alias Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if Application.get_env(:kanban, :sql_sandbox) do
      case LiveView.get_connect_info(socket, :user_agent) do
        user_agent when is_binary(user_agent) and user_agent != "" ->
          Phoenix.Ecto.SQL.Sandbox.allow(user_agent, Ecto.Adapters.SQL.Sandbox)

        _ ->
          :noop
      end
    end

    {:cont, socket}
  end
end
