defmodule KanbanWeb.Plugs.HeadRequestTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.Plugs.HeadRequest

  test "remembers a HEAD through Plug.Head's rewrite to GET" do
    conn = :head |> conn("/attachments/1/download") |> HeadRequest.call([]) |> Plug.Head.call([])

    assert conn.method == "GET"
    assert HeadRequest.head?(conn)
  end

  test "a GET, and a conn the plug never saw, are not HEAD" do
    refute :get |> conn("/") |> HeadRequest.call([]) |> HeadRequest.head?()
    refute :head |> conn("/") |> HeadRequest.head?()
  end

  # The order in KanbanWeb.Endpoint (before Plug.Head) is covered end to end
  # by the HEAD tests in attachment_controller_test.exs, which dispatch
  # through the endpoint.
end
