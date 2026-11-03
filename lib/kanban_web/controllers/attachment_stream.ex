defmodule KanbanWeb.AttachmentStream do
  @moduledoc """
  Streams an attachment's stored bytes into a response, shared by the browser
  routes (`KanbanWeb.AttachmentController`) and the API download route
  (`KanbanWeb.API.TaskAttachmentController`).

  Serving is split in two so the status is decided before any header is sent:

    * `open/2` opens the stored object. `Kanban.Attachments.Storage.stream/1`
      reports a missing or unreadable object before it yields a byte, so a
      caller can still answer with an error status. For a `HEAD` the stream
      is pulled for at most one chunk, only so it is closed (a local file
      handle, an S3 request), and never read whole.
    * `send_attachment/4` sends the headers from `KanbanWeb.AttachmentResponse`,
      a `content-length` of the recorded `byte_size` and the bytes, in chunks,
      never read whole into memory. No more than `byte_size` is sent.

  Once the headers are out the status cannot change. A body that falls short
  (a storage failure mid-stream, an I/O error on the first read after a
  successful open, or a blob shorter than its row) raises
  `KanbanWeb.AttachmentStream.IncompleteTransfer`, so the server closes the
  connection and the client sees fewer bytes than the declared
  `content-length`, never a finished response that passes for the whole file.
  A client that goes away ends the stream quietly. A blob longer than its row
  is cut at the declared length and logged.

  Storage failures are logged with the attachment id and a reason atom only:
  never the storage key, the file name or the contents.
  """

  import Plug.Conn

  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias KanbanWeb.AttachmentResponse

  require Logger

  defmodule IncompleteTransfer do
    @moduledoc """
    Raised after the headers of a 200 are sent when the body fell short of
    the declared `content-length`, so the server closes the connection
    instead of finishing a response that would pass for the whole file.
    Carries the attachment id only, never the storage key or the file name.
    """
    defexception [:attachment_id]

    @impl true
    def message(%{attachment_id: id}),
      do: "attachment #{id} ended before its recorded size; the response was aborted"
  end

  @typedoc "An opened body: the chunks to send, or `:head` for a body-less `HEAD`."
  @type body :: Enumerable.t() | :head

  @doc """
  Opens the stored object of `attachment`. Returns `{:ok, chunks}`, or
  `{:ok, :head}` when `head?` is true (the stream is opened and closed
  again), or `{:error, :not_found}` for a missing object or an unusable key,
  or `{:error, :storage_unavailable}` when storage fails. No header is sent.
  """
  @spec open(TaskAttachment.t(), boolean()) ::
          {:ok, body()} | {:error, :not_found | :storage_unavailable}
  def open(%TaskAttachment{} = attachment, head?) do
    case Storage.stream(attachment.storage_key) do
      {:ok, chunks} ->
        close_for_head(chunks, attachment, head?)

      {:error, reason} ->
        log_failure(attachment.id, reason)
        {:error, open_error(reason)}
    end
  end

  @doc """
  Sends a 200 with the headers for `disposition`, a `content-length` of the
  recorded `byte_size` and the opened `body`. Raises
  `KanbanWeb.AttachmentStream.IncompleteTransfer` when the body falls short.
  """
  @spec send_attachment(Plug.Conn.t(), TaskAttachment.t(), :attachment | :inline, body()) ::
          Plug.Conn.t()
  def send_attachment(conn, %TaskAttachment{} = attachment, disposition, body) do
    conn
    |> put_headers(AttachmentResponse.response_headers(attachment, disposition))
    |> put_resp_header("content-length", Integer.to_string(attachment.byte_size))
    |> send_chunked(200)
    |> stream_body(attachment, body)
  end

  defp open_error(reason) when reason in [:not_found, :invalid_key], do: :not_found
  defp open_error(_reason), do: :storage_unavailable

  # A failure while closing a HEAD's stream is still an error status, since
  # no header is out yet.
  defp close_for_head(chunks, _attachment, false), do: {:ok, chunks}

  defp close_for_head(chunks, attachment, true) do
    _first = Enum.take(chunks, 1)
    {:ok, :head}
  rescue
    exception -> refuse_head(attachment, stream_reason(exception))
  catch
    :exit, _reason -> refuse_head(attachment, :stream_failed)
  end

  defp refuse_head(attachment, reason) do
    log_failure(attachment.id, reason)
    {:error, :storage_unavailable}
  end

  # Each header replaces any value the pipeline set: the page CSP from
  # KanbanWeb.Plugs.CspNonce and Plug's default cache-control. content-type
  # is put directly so no charset is appended to a binary type.
  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

  defp stream_body(conn, _attachment, :head), do: conn

  defp stream_body(conn, attachment, chunks),
    do: conn |> stream_chunks(attachment, chunks) |> finish(attachment.id)

  # Enumerated here, in the process that called Storage.stream/1, as the S3
  # stream requires. At most the recorded byte_size is sent, the length the
  # headers declared. Returns {:done | :closed | :overlong, conn} or
  # {:short, reason}.
  defp stream_chunks(conn, attachment, chunks) do
    expected = attachment.byte_size

    case Enum.reduce_while(chunks, {:sending, conn, 0}, &send_within(&1, &2, expected)) do
      {:sending, conn, ^expected} -> {:done, conn}
      {:sending, _conn, _sent} -> {:short, :incomplete}
      ended -> ended
    end
  rescue
    exception -> {:short, stream_reason(exception)}
  catch
    :exit, _reason -> {:short, :stream_failed}
  end

  defp send_within(_data, {:sending, conn, expected}, expected), do: {:halt, {:overlong, conn}}

  defp send_within(data, {:sending, conn, sent}, expected) do
    {part, cut?} = within(IO.iodata_to_binary(data), expected - sent)

    conn |> chunk(part) |> sent_chunk(conn, cut?, sent + byte_size(part))
  end

  defp sent_chunk({:ok, conn}, _before, true, _sent), do: {:halt, {:overlong, conn}}
  defp sent_chunk({:ok, conn}, _before, false, sent), do: {:cont, {:sending, conn, sent}}
  defp sent_chunk({:error, _closed}, conn, _cut?, _sent), do: {:halt, {:closed, conn}}

  # The part of data that fits in the room left, and whether any was cut.
  defp within(data, room) when byte_size(data) > room, do: {binary_part(data, 0, room), true}
  defp within(data, _room), do: {data, false}

  # A client that went away ends quietly. A blob longer than its row was cut
  # at the declared length, so the client got a whole-looking file of the
  # recorded size: logged, not aborted. A body that fell short cannot become
  # an error status any more, and a finished response would pass for the
  # whole file, so it is logged and the connection is aborted.
  defp finish({:done, conn}, _attachment_id), do: conn
  defp finish({:closed, conn}, _attachment_id), do: conn

  defp finish({:overlong, conn}, attachment_id) do
    log_failure(attachment_id, :size_mismatch)
    conn
  end

  defp finish({:short, reason}, attachment_id) do
    log_failure(attachment_id, reason)
    raise IncompleteTransfer, attachment_id: attachment_id
  end

  # File.Error's message holds the path, which is the storage key, so only
  # its reason atom is kept.
  defp stream_reason(%File.Error{reason: reason}) when is_atom(reason), do: reason
  defp stream_reason(_exception), do: :stream_failed

  defp log_failure(attachment_id, reason) do
    Logger.warning(
      "attachment stream failed: attachment_id=#{attachment_id} reason=#{inspect(reason_code(reason))}"
    )
  end

  defp reason_code(reason) when is_atom(reason), do: reason
  defp reason_code(_reason), do: :unknown
end
