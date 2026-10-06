defmodule KanbanWeb.Plugs.McpEventStreamAcceptTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.Plugs.McpEventStreamAccept

  defp call(accepts, params \\ %{}) do
    conn = conn(:get, "/api/mcp")
    conn = Enum.reduce(accepts, conn, &Plug.Conn.put_req_header(&2, "accept", &1))

    %{conn | params: params}
    |> McpEventStreamAccept.call(McpEventStreamAccept.init([]))
  end

  test "an Accept naming text/event-stream selects the json format param" do
    for accept <- [
          "text/event-stream",
          "application/json, text/event-stream",
          "TEXT/Event-Stream;q=0.5"
        ] do
      assert call([accept]).params["_format"] == "json", accept
    end
  end

  test "any other Accept is left for the normal negotiation" do
    for accept <- ["text/html", "application/json", "*/*", "text/plain, text/event-streamx"] do
      refute Map.has_key?(call([accept]).params, "_format"), accept
    end

    refute Map.has_key?(call([]).params, "_format")
  end

  test "an explicit _format param is never overridden" do
    assert call(["text/event-stream"], %{"_format" => "xml"}).params["_format"] == "xml"
  end
end
