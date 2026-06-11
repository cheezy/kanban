defmodule KanbanWeb.PageController do
  use KanbanWeb, :controller

  # Public marketing surfaces — render under the marketing layout (which
  # provides the marketing nav + footer chrome) instead of the default
  # app layout (which provides the in-app nav).
  plug :put_root_layout,
       [html: {KanbanWeb.Layouts, :marketing}]
       when action in [
              :acceptable_use,
              :home,
              :pricing,
              :privacy,
              :product,
              :security,
              :terms,
              :workflows
            ]

  # Pages reachable from the in-app sidebar (About) or from About itself
  # (Tango, Changelog) render under the app shell so the sidebar stays
  # visible for authenticated users.
  plug :put_root_layout,
       [html: {KanbanWeb.Layouts, :app_chrome}]
       when action in [:about, :tango, :changelog]

  def home(conn, _params) do
    has_boards =
      case conn.assigns[:current_scope] do
        %{user: user} when not is_nil(user) -> Kanban.Boards.user_has_boards?(user)
        _ -> false
      end

    render(conn, :home, has_boards: has_boards)
  end

  def about(conn, _params) do
    render(conn, :about)
  end

  def pricing(conn, _params) do
    render(conn, :pricing)
  end

  def acceptable_use(conn, _params) do
    render(conn, :acceptable_use)
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def product(conn, _params) do
    render(conn, :product)
  end

  def security(conn, _params) do
    render(conn, :security)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end

  def workflows(conn, _params) do
    render(conn, :workflows)
  end

  def tango(conn, _params) do
    render(conn, :tango)
  end

  def changelog(conn, _params) do
    render(conn, :changelog)
  end

  def set_locale(conn, %{"locale" => locale}) do
    conn
    |> KanbanWeb.Plugs.Locale.set_locale(locale)
    |> redirect(to: get_redirect_path(conn))
  end

  defp get_redirect_path(conn) do
    # Get the referer or default to home page
    case get_req_header(conn, "referer") do
      [referer] ->
        uri = URI.parse(referer)
        uri.path || "/"

      _ ->
        "/"
    end
  end
end
