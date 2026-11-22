defmodule KanbanWeb.AnalyticsOnMount do
  @moduledoc """
  Opts a LiveView page in to Umami analytics (W2897).

  `on_mount(:track, ...)` assigns `analytics: true`, which every root layout
  passes to `KanbanWeb.Analytics.tracker/1`. The router lists it in the
  `:public` and `:public_app_shell` live_sessions, and only
  `KanbanWeb.UserLive.Registration`, `KanbanWeb.UserLive.Login` and
  `KanbanWeb.UserLive.ConfirmationPending` declare it themselves: the
  `:current_user` session they share also holds the token pages, which must
  never load the tracker. Controllers opt in through
  `KanbanWeb.Plugs.PutAnalytics`.
  """
  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns `analytics: true` and continues the mount.
  """
  @spec on_mount(:track, map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:track, _params, _session, socket) do
    {:cont, assign(socket, :analytics, true)}
  end
end
