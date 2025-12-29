defmodule KanbanWeb.API.AgentController do
  use KanbanWeb, :controller

  def onboarding(conn, _params) do
    render(conn, :onboarding, base_url: get_base_url(conn))
  end

  defp get_base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port = conn.port

    default_port? = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)

    if default_port? do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
