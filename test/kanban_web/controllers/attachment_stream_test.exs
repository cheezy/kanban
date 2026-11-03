defmodule KanbanWeb.AttachmentStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kanban.Attachments.TaskAttachment
  alias KanbanWeb.AttachmentStream

  # A connection whose client has gone away: the headers go out, and every
  # chunk after that reports the socket closed.
  defmodule ClosedAdapter do
    def send_chunked(payload, _status, _headers), do: {:ok, nil, payload}
    def chunk(_payload, _body), do: {:error, :closed}
  end

  describe "send_attachment/4 when the client disconnects mid-stream" do
    test "stops pulling from storage, raises nothing and logs nothing" do
      attachment = %TaskAttachment{
        id: 1,
        filename: "notes.txt",
        content_type: "text/plain",
        byte_size: 6
      }

      parent = self()

      chunks =
        Stream.map(["ab", "cd", "ef"], fn part ->
          send(parent, {:pulled, part})
          part
        end)

      conn = %Plug.Conn{adapter: {ClosedAdapter, :payload}, owner: self()}

      log =
        capture_log(fn ->
          assert %Plug.Conn{state: :chunked, status: 200} =
                   AttachmentStream.send_attachment(conn, attachment, :attachment, chunks)
        end)

      assert_received {:pulled, "ab"}
      refute_received {:pulled, "cd"}
      refute_received {:pulled, "ef"}
      refute log =~ "attachment stream failed"
    end
  end
end
