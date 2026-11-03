defmodule Kanban.AttachmentsFixtures do
  @moduledoc """
  Test helpers for attachment rows.

  `attachment_fixture/2` inserts a `task_attachments` row directly, bypassing
  the changeset and writing no blob to storage, so a test can exercise the
  schema, associations and the blob-deletion trigger without a storage
  adapter.
  """

  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Columns.Column
  alias Kanban.Repo

  @doc """
  Inserts an attachment on `task`. The storage key's prefix is the task's
  board, taken from its column; the row itself stores no board.

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

  @doc """
  Like `attachment_fixture/2`, but first stores `bytes` under a fresh key
  through `Kanban.Attachments.Storage`, and gives the row their real size
  and sha256, so the attachment has a blob that matches it.
  """
  def stored_attachment_fixture(task, bytes, attrs \\ %{}) when is_binary(bytes) do
    board_id = Repo.get!(Column, task.column_id).board_id
    key = unique_storage_key(board_id)
    :ok = Storage.put(key, {:binary, bytes})

    attachment_fixture(
      task,
      Map.merge(
        %{storage_key: key, byte_size: byte_size(bytes), sha256: sha256_hex(bytes)},
        Map.new(attrs)
      )
    )
  end

  @doc "The lowercase hex sha256 of `bytes`, as a row stores it."
  def sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc """
  A minimal well-formed 1x1 PNG, which the attachment content checks accept
  as `image/png`.
  """
  def tiny_png do
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = png_chunk("IHDR", <<1::32, 1::32, 8, 0, 0, 0, 0>>)
    signature <> ihdr <> png_chunk("IDAT", <<120, 1, 0, 0, 0, 255, 255>>) <> png_chunk("IEND", "")
  end

  defp png_chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  @doc "A fresh storage key valid under `Kanban.Attachments.Storage` rules."
  def unique_storage_key(board_id) do
    "boards/#{board_id}/" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  defp id_or_nil(nil), do: nil
  defp id_or_nil(%{id: id}), do: id
end
