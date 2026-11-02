defmodule Kanban.Attachments.BlobDeletion do
  @moduledoc """
  A tombstone: one stored blob that is due to be removed from storage.

  Rows reach `attachment_blob_deletions` two ways:

    * The `AFTER DELETE` trigger on `task_attachments` inserts one for every
      deleted attachment row, whatever deleted it (a direct delete, a cascade
      from its task, comment or board, or a bulk `Repo.delete_all`). Its
      `delete_after` is the moment of the delete.
    * The attachments context parks one before it stores an upload's blob,
      with a later `delete_after`, and removes it once the row is inserted.
      If the process dies in between, the blob is still reclaimed once the
      grace period has passed.

  The cleanup worker deletes each blob whose `delete_after` has passed and
  then the tombstone, keeping a short reason code (never a message or a URL)
  in `last_error`. `attempts` counts the worker's tries at the key, recorded
  before each delete; an upload commits its row only while its own pending
  tombstone's `attempts` is still 0.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "attachment_blob_deletions" do
    field :storage_key, :string
    field :delete_after, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :last_error, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc """
  A changeset for a tombstone the context parks itself. Casts `storage_key`
  and `delete_after`; when `delete_after` is not given the database default,
  the current time, applies.
  """
  def changeset(blob_deletion, attrs) do
    blob_deletion
    |> cast(attrs, [:storage_key, :delete_after])
    |> validate_required([:storage_key])
    |> validate_length(:storage_key, max: 512)
  end
end
