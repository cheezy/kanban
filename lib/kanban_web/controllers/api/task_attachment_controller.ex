defmodule KanbanWeb.API.TaskAttachmentController do
  @moduledoc """
  `GET /api/tasks/:id/attachments/:attachment_id`: streams an attachment's
  bytes to an API token, the path every attachment's `download_url` names.

  The checks and lookup are `KanbanWeb.API.AttachmentActions.fetch_attachment/4`,
  run after
  `KanbanWeb.API.BoardReadAccess` has re-checked a board token's user's live
  board access. Errors render through `KanbanWeb.API.TaskErrors`, so the
  bodies match the rest of the task API.

  The stored object is opened before any header is sent
  (`KanbanWeb.AttachmentStream.open/2`), so a blob missing from storage is
  still a `404` ("Attachment not found") and a storage failure a `503`. Then
  the bytes are streamed in chunks with the headers from
  `KanbanWeb.AttachmentResponse` (`Content-Disposition: attachment` with a
  sanitized file name, the stored allow-listed type or
  `application/octet-stream`, `nosniff`, a sandboxing CSP and
  `private, no-store`) and a `content-length` of the recorded size. A body
  that falls short after the headers are out aborts the connection
  (`KanbanWeb.AttachmentStream.IncompleteTransfer`). A `HEAD` gets the same
  status and headers and no body.

  A `GET` that reaches the stream emits `[:kanban, :api, :attachment_downloaded]`
  with the task and attachment ids; a refused request and a `HEAD` do not.
  """

  use KanbanWeb, :controller

  alias KanbanWeb.API.AttachmentActions
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.AttachmentStream

  plug KanbanWeb.API.BoardReadAccess when action == :download

  def download(conn, %{"id" => task_ref, "attachment_id" => attachment_ref}) do
    case fetch_and_open(conn, task_ref, attachment_ref) do
      {:ok, task, attachment, body} ->
        record_download(conn, task, attachment, body)
        AttachmentStream.send_attachment(conn, attachment, :attachment, body)

      {:error, reason} ->
        TaskErrors.render_error(conn, reason)
    end
  end

  defp fetch_and_open(conn, task_ref, attachment_ref) do
    with {:ok, task, attachment} <-
           AttachmentActions.fetch_attachment(conn, task_ref, attachment_ref, :rest),
         {:ok, body} <- open_body(attachment, conn) do
      {:ok, task, attachment, body}
    end
  end

  defp open_body(attachment, conn) do
    case AttachmentStream.open(attachment, KanbanWeb.Plugs.HeadRequest.head?(conn)) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:error, :attachment_not_found}
      {:error, :storage_unavailable} -> {:error, :attachment_storage_unavailable}
    end
  end

  defp record_download(_conn, _task, _attachment, :head), do: :ok

  defp record_download(conn, task, attachment, _chunks),
    do: AttachmentActions.record_download(conn, task, attachment)
end
