defmodule KanbanWeb.Plugs.PutAnalytics do
  @moduledoc """
  Opts a controller page in to Umami analytics (W2897).

  It assigns `analytics: true`, which every root layout passes to
  `KanbanWeb.Analytics.tracker/1`. The tag still renders only when Umami is
  configured. The router pipes the public page routes through the
  `:put_analytics` pipeline; signed-in, account and token pages never do, so
  analytics stays opt-in. LiveViews opt in through
  `KanbanWeb.AnalyticsOnMount`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: assign(conn, :analytics, true)
end
