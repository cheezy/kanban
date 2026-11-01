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
  sent: `Kanban.Attachments.Storage.stream/1` reports a missing object before
  it yields a byte.

  The bytes are streamed in chunks through `Kanban.Attachments.Storage` and
  never read whole into memory, and every 200 carries the headers from
  `KanbanWeb.AttachmentResponse`. `fetch_for_download/2` emits
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
    |> send_chunked(200)
    |> stream_chunks(attachment.id, chunks)
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
  # stream requires. A client that goes away ends the loop quietly. A storage
  # failure after the headers are sent cannot become a 404 any more, so it is
  # logged and the response ends where it stopped instead of crashing.
  defp stream_chunks(conn, attachment_id, chunks) do
    Enum.reduce_while(chunks, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  rescue
    exception ->
      log_failure(attachment_id, stream_reason(exception))
      conn
  catch
    :exit, _reason ->
      log_failure(attachment_id, :stream_failed)
      conn
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
