defmodule KanbanWeb.PageController do
  use KanbanWeb, :controller

  def home(conn, _params) do
    conn
    |> put_root_layout(html: {KanbanWeb.Layouts, :marketing})
    |> render(:home)
  end

  def about(conn, _params) do
    render(conn, :about)
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def security(conn, _params) do
    render(conn, :security)
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
