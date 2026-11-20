defmodule KanbanWeb.SeoOnMount do
  @moduledoc """
  Marks a LiveView page `noindex` for search engines (W2890).

  `on_mount(:noindex, ...)` assigns `noindex: true`, which every root layout
  passes to `KanbanWeb.SeoComponents.seo_head/1`, so the page renders
  `<meta name="robots" content="noindex, nofollow">`. It is used by the
  three signed-in `live_session`s the app defines in `KanbanWeb.Router`
  (`:admin`, `:require_sudo_mode`, `:require_authenticated_user`) and, module
  by module, by the token and account pages in the `:current_user` session
  (password reset, email confirmation, two-factor, confirmation-pending,
  forgot-password and invitations). Log-in and register stay indexable. The
  `/admin` LiveDashboard and ErrorTracker sessions render their own layouts
  without `seo_head`, so they carry only the header.

  Noindex is a request to crawlers, not access control: a token page must
  still validate its token. The matching `X-Robots-Tag` header comes from
  `KanbanWeb.Plugs.PutNoindex`, because a LiveView socket cannot set
  response headers.
  """
  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns `noindex: true` and continues the mount.
  """
  @spec on_mount(:noindex, map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:noindex, _params, _session, socket) do
    {:cont, assign(socket, :noindex, true)}
  end
end
