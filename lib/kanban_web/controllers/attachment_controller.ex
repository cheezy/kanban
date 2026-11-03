defmodule KanbanWeb.AttachmentController do
  @moduledoc """
  Serves an attachment's bytes to a signed-in browser (W2510):

    * `GET /attachments/:id/download` always sends the file as a download.
    * `GET /attachments/:id/preview` shows a raster image (png, jpeg, gif,
      webp) inline and is a 404 for every other type, SVG, HTML and PDF
      included.

  Authorization is derived from the signed-in user on every request. The URL
  id is only a lookup hint for `Kanban.Attachments.fetch_for_download/3`,
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

  The bytes are streamed in chunks through `Kanban.Attachments.Storage` by
  `KanbanWeb.AttachmentStream`, which the API download route shares, and
  never read whole into memory, and every 200 carries the headers from
  `KanbanWeb.AttachmentResponse` and a `content-length` of the recorded
  `byte_size`. No more than that is sent. A body that falls short after the
  headers are out (a storage failure mid-stream, or a blob shorter than its
  row) raises `KanbanWeb.AttachmentStream.IncompleteTransfer`, so the
  server closes the connection and the client sees an incomplete download,
  never a finished response that passes for the whole file.

  A `HEAD` (recorded by `KanbanWeb.Plugs.HeadRequest`, since `Plug.Head`
  turns it into a `GET`) gets the same status and headers as the `GET`, with
  no body. The stored object is still opened, so a missing or unreadable one
  is the same 404, but it is read for at most one chunk, only to close it,
  so a `HEAD` never pulls a whole file from storage. Range and conditional
  request headers are ignored: every 200 is the whole file, and no
  `Accept-Ranges`, `ETag` or `Last-Modified` header is sent.

  `fetch_for_download/3` emits `[:kanban, :attachment, :downloaded]` once
  access is authorized, with `via: :download` from the download route,
  `:preview` from the preview route and `:head` for a `HEAD` on either, so a
  preview refused for its type or a missing object still counts; this
  controller adds no telemetry of its own.

  Storage failures are logged with the attachment id and a reason atom only:
  never the storage key, the file name or the contents.
  """

  use KanbanWeb, :controller

  alias Kanban.Attachments
  alias KanbanWeb.AttachmentResponse
  alias KanbanWeb.AttachmentStream
  alias KanbanWeb.IdParams
  alias KanbanWeb.Plugs.HeadRequest

  def download(conn, %{"id" => id}), do: serve(conn, id, :attachment)

  def preview(conn, %{"id" => id}), do: serve(conn, id, :inline)

  # Everything that can still turn the response into a 404 runs before any
  # header is sent: the type check, opening the stored object and, for a
  # HEAD, closing it again (KanbanWeb.AttachmentStream.open/2).
  defp serve(conn, raw_id, disposition) do
    head? = HeadRequest.head?(conn)

    with {:ok, attachment} <- fetch(conn, raw_id, event_via(disposition, head?)),
         :ok <- servable_as(attachment, disposition),
         {:ok, body} <- AttachmentStream.open(attachment, head?) do
      AttachmentStream.send_attachment(conn, attachment, disposition, body)
    else
      _refusal -> not_found(conn)
    end
  end

  # The id is parsed here because fetch_for_download/3 takes an integer: a
  # malformed or out-of-range id never reaches the database. The downloaded
  # event says whether a person downloaded the file, a thumbnail or the
  # lightbox showed it, or a HEAD asked for the headers only.
  defp fetch(conn, raw_id, via) do
    with {:ok, id} <- IdParams.parse(raw_id),
         do: Attachments.fetch_for_download(conn.assigns.current_scope, id, via)
  end

  defp event_via(_disposition, true), do: :head
  defp event_via(:attachment, false), do: :download
  defp event_via(:inline, false), do: :preview

  # A download serves any type; a preview only a raster image, judged by the
  # type the server stored.
  defp servable_as(_attachment, :attachment), do: :ok

  defp servable_as(attachment, :inline) do
    if AttachmentResponse.inline_image?(attachment.content_type), do: :ok, else: :error
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: KanbanWeb.ErrorHTML)
    |> render(:"404")
  end
end
