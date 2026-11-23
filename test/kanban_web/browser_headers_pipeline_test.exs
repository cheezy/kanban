defmodule KanbanWeb.BrowserHeadersPipelineTest do
  # D467: the browser security headers and CspNonce live in :browser_headers,
  # piped through BEFORE :browser, because when :protect_from_forgery raises
  # the router re-raises with the conn as it entered the failing pipeline and
  # anything set earlier inside :browser is lost. A route that pipes through
  # :browser without :browser_headers first would send its pages, and its
  # CSRF 403, with no CSP, Referrer-Policy or X-Content-Type-Options.
  use ExUnit.Case, async: true

  alias KanbanWeb.Router

  # Router.__routes__/0 does not carry pipe_through; route_info/4 does, for
  # the route a request to that path would match.
  defp pipelines do
    for route <- Router.__routes__() do
      verb = if route.verb == :*, do: "GET", else: route.verb |> to_string() |> String.upcase()
      info = Phoenix.Router.route_info(Router, verb, route.path, "")
      assert is_map(info), "#{verb} #{route.path} does not resolve"
      {"#{verb} #{route.path}", info.pipe_through}
    end
  end

  test "every :browser route pipes through :browser_headers first" do
    browser_routes = for {route, pipes} <- pipelines(), :browser in pipes, do: {route, pipes}

    assert length(browser_routes) > 50

    for {route, pipes} <- browser_routes do
      assert Enum.take(pipes, 2) == [:browser_headers, :browser],
             "#{route} pipes through #{inspect(pipes)}"
    end
  end

  test ":browser_headers is only ever piped in front of :browser" do
    for {route, pipes} <- pipelines(), :browser_headers in pipes do
      assert Enum.take(pipes, 2) == [:browser_headers, :browser],
             "#{route} pipes through #{inspect(pipes)}"
    end
  end
end
