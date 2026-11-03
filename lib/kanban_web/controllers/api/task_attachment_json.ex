defmodule KanbanWeb.API.TaskAttachmentJSON do
  @moduledoc """
  The attachment object that `GET /api/tasks/:id` (full view), `POST
  /api/tasks/claim` and the MCP `stride_get_task` and `stride_claim_task`
  tools carry in `data.attachments`, and the MCP `stride_get_attachment` tool
  returns as its `data`.

  Each object has exactly eight keys: `id`, `filename`, `content_type`,
  `byte_size`, `sha256`, `comment_id` (`nil` for a task-level attachment),
  `uploaded_at` (ISO 8601 UTC) and `download_url`. The Stride plugins parse
  them and the OpenAPI `TaskAttachment` schema pins them, so adding a key is a
  contract change.

  Storage details (`storage_key`, bucket or storage URLs) and uploader fields
  are never rendered: the object reaches every reader of the board and every
  agent. `filename` is user-supplied and only ever appears as a JSON string
  value. `download_url` is built from integer ids alone.
  """

  alias Kanban.Attachments.TaskAttachment

  @doc """
  Renders a list of preloaded attachments, keeping their order.
  """
  def attachments(attachments) when is_list(attachments),
    do: Enum.map(attachments, &attachment/1)

  @doc """
  Renders one attachment as the eight-key contract object.
  """
  def attachment(%TaskAttachment{} = attachment) do
    %{
      id: attachment.id,
      filename: attachment.filename,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      sha256: attachment.sha256,
      comment_id: attachment.comment_id,
      uploaded_at: uploaded_at(attachment.inserted_at),
      download_url: download_url(attachment)
    }
  end

  # The row's timestamps are naive datetimes stored in UTC, so the offset is
  # made explicit rather than left for the reader to assume.
  defp uploaded_at(%NaiveDateTime{} = inserted_at),
    do: inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  # Always the numeric task id, never the identifier, and never anything taken
  # from the filename or the request.
  defp download_url(%TaskAttachment{id: id, task_id: task_id})
       when is_integer(id) and is_integer(task_id),
       do: "/api/tasks/#{task_id}/attachments/#{id}"
end
