defmodule KanbanWeb.Plugs.AttachmentDownloadAcceptTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.Plugs.AttachmentDownloadAccept

  defp call(accepts, params) do
    conn = conn(:get, "/api/tasks/1/attachments/2")
    conn = Enum.reduce(accepts, conn, &Plug.Conn.put_req_header(&2, "accept", &1))

    %{conn | params: params}
    |> AttachmentDownloadAccept.call(AttachmentDownloadAccept.init([]))
  end

  test "any Accept, or none, selects the json format param" do
    for accept <- [
          ["application/octet-stream"],
          ["image/png"],
          ["text/html"],
          ["*/*"],
          ["application/json"],
          [""],
          []
        ] do
      assert call(accept, %{"id" => "1"}).params == %{"id" => "1", "_format" => "json"},
             inspect(accept)
    end
  end

  test "an explicit _format param is never overridden" do
    assert call(["application/octet-stream"], %{"_format" => "html"}).params["_format"] ==
             "html"
  end

  test "unfetched params are left alone" do
    conn = conn(:get, "/api/tasks/1/attachments/2")
    assert AttachmentDownloadAccept.call(conn, []).params == conn.params
  end
end
