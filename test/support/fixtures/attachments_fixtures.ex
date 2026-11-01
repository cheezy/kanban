defmodule Kanban.AttachmentsFixtures do
  @moduledoc """
  Test helpers for attachment rows.

  `attachment_fixture/2` inserts a `task_attachments` row directly, bypassing
  the changeset and writing no blob to storage, so a test can exercise the
  schema, associations and the blob-deletion trigger without a storage
  adapter.
  """

  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Columns.Column
  alias Kanban.Repo

  @doc """
  Inserts an attachment on `task`. `board_id` is taken from the task's column.

  Options in `attrs`:

    * `:comment` — a `Kanban.Tasks.TaskComment` the attachment belongs to.
    * `:uploaded_by` — the uploading `Kanban.Accounts.User`.
    * Any `TaskAttachment` field (`:filename`, `:content_type`,
      `:byte_size`, `:sha256`, `:storage_key`) to override its default.
  """
  def attachment_fixture(task, attrs \\ %{}) do
    attrs = Map.new(attrs)
    board_id = Repo.get!(Column, task.column_id).board_id
    unique = System.unique_integer([:positive])

    defaults = %{
      task_id: task.id,
      board_id: board_id,
      comment_id: attrs |> Map.get(:comment) |> id_or_nil(),
      uploaded_by_id: attrs |> Map.get(:uploaded_by) |> id_or_nil(),
      filename: "file-#{unique}.txt",
      content_type: "text/plain",
      byte_size: 12,
      sha256: :sha256 |> :crypto.hash("file-#{unique}") |> Base.encode16(case: :lower),
      storage_key: unique_storage_key(board_id)
    }

    fields = Map.merge(defaults, Map.drop(attrs, [:comment, :uploaded_by]))

    TaskAttachment |> struct(fields) |> Repo.insert!()
  end

  @doc "A fresh storage key valid under `Kanban.Attachments.Storage` rules."
  def unique_storage_key(board_id) do
    "boards/#{board_id}/" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  defp id_or_nil(nil), do: nil
  defp id_or_nil(%{id: id}), do: id
end
