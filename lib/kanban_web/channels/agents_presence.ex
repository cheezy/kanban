defmodule KanbanWeb.AgentsPresence do
  @moduledoc """
  Phoenix.Presence tracker for connected viewers of `/agents`.

  Tracked on the `"agents"` PubSub topic; the LiveView calls
  `track/3` in `mount/3` (gated by `connected?/1`) and reads the
  current viewer count via `count/0` to render the live indicator.

  Each viewer is keyed by its LiveView socket id so multiple tabs from
  the same user count distinctly.
  """
  use Phoenix.Presence,
    otp_app: :kanban,
    pubsub_server: Kanban.PubSub

  @topic "agents"

  @doc "The PubSub topic this presence is keyed on."
  def topic, do: @topic

  @doc """
  Tracks the given LiveView socket as an active viewer.

  Returns the underlying `Phoenix.Presence.track/3` result.
  """
  def track_viewer(socket) do
    track(socket.transport_pid, @topic, socket.id, %{joined_at: System.system_time(:second)})
  end

  @doc "Returns the number of distinct viewers currently connected."
  def count do
    @topic
    |> list()
    |> map_size()
  end
end
