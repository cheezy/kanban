defmodule KanbanWeb.API.AgentController do
  use KanbanWeb, :controller

  def onboarding(conn, _params) do
    render(conn, :onboarding, base_url: get_base_url(conn))
  end

  defp get_base_url(conn) do
    # Use the configured URL scheme from endpoint config, not the connection scheme
    # This handles cases where SSL is terminated at a proxy/load balancer
    url_config = Application.get_env(:kanban, KanbanWeb.Endpoint)[:url] || []

    # If url config exists, use it; otherwise fall back to connection details
    scheme =
      if Keyword.has_key?(url_config, :scheme) do
        Keyword.get(url_config, :scheme)
      else
        if conn.scheme == :https, do: "https", else: "http"
      end

    host = Keyword.get(url_config, :host, conn.host)
    port = Keyword.get(url_config, :port, conn.port)

    default_port? = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)

    if default_port? do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
