defmodule KanbanWeb.AttachmentController do
  @moduledoc """
  Serves an attachment's bytes to a signed-in browser (W2510):

    * `GET /attachments/:id/download` always sends the file as a download.
    * `GET /attachments/:id/preview` shows a raster image (png, jpeg, gif,
      webp) inline and is a 404 for every other type, SVG, HTML and PDF
      included.

  Authorization is derived from the signed-in user on every request. The URL
  id is only a lookup hint for `Kanban.Attachments.fetch_for_download/2`,
  which finds the board through the attachment's task, checks membership and
  the `:attachments` plan (emitting the one `feature_refused` event) and the
  read right. The storage key comes from the stored row, never from the
  request.

  Every refusal — no access, another board, an unknown or malformed id, a
  locked plan, a type that cannot be previewed, or a stored object that is
  missing or unreadable — is the same 404 page, so a response never reveals
  whether an attachment exists. The status is decided before any header is
  sent: `Kanban.Attachments.Storage.stream/1` reports a missing or unreadable
  object before it yields a byte.

  The bytes are streamed in chunks through `Kanban.Attachments.Storage` and
  never read whole into memory, and every 200 carries the headers from
  `KanbanWeb.AttachmentResponse` and a `content-length` of the recorded
  `byte_size`. No more than that is sent. A body that falls short after the
  headers are out (a storage failure mid-stream, or a blob shorter than its
  row) raises `KanbanWeb.AttachmentController.IncompleteTransfer`, so the
  server closes the connection and the client sees an incomplete download,
  never a finished response that passes for the whole file. `fetch_for_download/2` emits
  `[:kanban, :attachment, :downloaded]` once access is authorized, so a
  preview refused for its type or a missing object still counts; this
  controller adds no telemetry of its own.

  Storage failures are logged with the attachment id and a reason atom only:
  never the storage key, the file name or the contents.
  """

  use KanbanWeb, :controller

  alias Kanban.Attachments
  alias Kanban.Attachments.Storage
  alias KanbanWeb.AttachmentResponse
  alias KanbanWeb.IdParams

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

  def download(conn, %{"id" => id}), do: serve(conn, id, :attachment)

  def preview(conn, %{"id" => id}), do: serve(conn, id, :inline)

  defp serve(conn, raw_id, disposition) do
    with {:ok, attachment} <- fetch(conn, raw_id),
         :ok <- servable_as(attachment, disposition),
         {:ok, chunks} <- open_stream(attachment) do
      send_attachment(conn, attachment, disposition, chunks)
    else
      _refusal -> not_found(conn)
    end
  end

  defp send_attachment(conn, attachment, disposition, chunks) do
    conn
    |> put_headers(AttachmentResponse.response_headers(attachment, disposition))
    |> put_resp_header("content-length", Integer.to_string(attachment.byte_size))
    |> send_chunked(200)
    |> stream_chunks(attachment, chunks)
    |> finish(attachment.id)
  end

  # The id is parsed here because fetch_for_download/2 takes an integer: a
  # malformed or out-of-range id never reaches the database.
  defp fetch(conn, raw_id) do
    with {:ok, id} <- IdParams.parse(raw_id),
         do: Attachments.fetch_for_download(conn.assigns.current_scope, id)
  end

  # A download serves any type; a preview only a raster image, judged by the
  # type the server stored.
  defp servable_as(_attachment, :attachment), do: :ok

  defp servable_as(attachment, :inline) do
    if AttachmentResponse.inline_image?(attachment.content_type), do: :ok, else: :error
  end

  defp open_stream(attachment) do
    case Storage.stream(attachment.storage_key) do
      {:ok, chunks} ->
        {:ok, chunks}

      {:error, reason} ->
        log_failure(attachment.id, reason)
        :error
    end
  end

  # Each header replaces any value the pipeline set: the page CSP from
  # KanbanWeb.Plugs.CspNonce and Plug's default cache-control. content-type
  # is put directly so no charset is appended to a binary type.
  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

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
  # recorded size: logged, not aborted. A body that fell short — a storage
  # failure after the headers, or a blob shorter than its row — cannot become
  # a 404 any more, and a finished response would pass for the whole file,
  # so it is logged and the connection is aborted: the client sees fewer
  # bytes than the declared content-length and knows the file is incomplete.
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

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: KanbanWeb.ErrorHTML)
    |> render(:"404")
  end
end
