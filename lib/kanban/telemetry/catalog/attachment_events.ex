defmodule Kanban.Telemetry.Catalog.AttachmentEvents do
  @moduledoc """
  The attachment events in `Kanban.Telemetry.Catalog`.

  `Kanban.Attachments` emits the first four, and
  `Kanban.Attachments.BlobCleanupWorker` emits `blob_cleanup_completed` once
  per run, with counts only. Metadata carries ids, sizes and the
  refusal reason only, never a filename, the file's contents or its hash.
  `uploaded` and `upload_refused` also carry `source`: `:upload` for a
  person's upload. `:import` is reserved for the Jira import's
  `import_attachment/4`, which is not built yet.
  `downloaded` carries `via`: `:download`, `:preview` or `:head`.
  `reason`, `source` and `via` come from fixed atom sets, so all three
  are tags.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :attachment, :uploaded],
      kind: :event,
      domain: :attachment,
      measurements: [:count, :byte_size],
      metadata: [:attachment_id, :task_id, :board_id, :comment_id, :user_id, :source],
      description:
        "A file was attached to a task or comment. source is :upload or :import; comment_id is set for a comment-level file. The filename, contents and hash are never sent.",
      legacy: false,
      metrics: [counter: :count, sum: :byte_size],
      persist: false,
      tags: [:source]
    },
    %{
      name: [:kanban, :attachment, :downloaded],
      kind: :event,
      domain: :attachment,
      measurements: [:count, :byte_size],
      metadata: [:attachment_id, :task_id, :board_id, :user_id, :via],
      description:
        "A board member was authorized to fetch an attachment. via is :download when they download it, :preview when a thumbnail or the lightbox shows it, and :head for a HEAD request, which sends no body. The filename, contents and hash are never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:via]
    },
    %{
      name: [:kanban, :attachment, :deleted],
      kind: :event,
      domain: :attachment,
      measurements: [:count, :byte_size],
      metadata: [:attachment_id, :task_id, :board_id, :user_id],
      description:
        "An attachment was deleted through Kanban.Attachments; its blob is queued for removal. user_id is the person who deleted it. The filename is never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :attachment, :upload_refused],
      kind: :event,
      domain: :attachment,
      measurements: [:count],
      metadata: [:reason, :source, :task_id, :board_id, :user_id],
      description:
        "An upload was refused. reason is :too_large, :type_not_allowed, :type_mismatch, :empty, :too_many_files, :quota_exceeded or :storage_unavailable, or :invalid_file for a file refused for anything else, such as an unusable name; source is :upload or :import. A plan refusal is plan.feature_refused instead.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:reason, :source]
    },
    %{
      name: [:kanban, :attachment, :blob_cleanup_completed],
      kind: :event,
      domain: :attachment,
      measurements: [:deleted, :in_use, :invalid, :failed, :skipped, :deferred, :left],
      metadata: [],
      description:
        "A blob cleanup run finished. Each measurement counts tombstones: deleted (blob removed or already gone), in_use (a live attachment still names the key), invalid (key failed validation), failed (storage refused; retried later), skipped (handled by another run), deferred (left because the run's time budget ran out) and left (still due when the run ended). A left that grows from run to run means blobs are not being removed.",
      legacy: false,
      metrics: [sum: :left, sum: :deleted, sum: :failed, sum: :invalid],
      persist: true
    }
  ]

  @doc """
  Returns the attachment entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
