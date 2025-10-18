defmodule KanbanWeb.PageController do
  use KanbanWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
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
