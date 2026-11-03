defmodule Kanban.Repo.Migrations.CheckBlobDeletionAttemptsNonNegative do
  use Ecto.Migration

  # attempts counts failed deletes of a tombstone's blob, so it is never
  # negative. Nothing in the app writes a negative value, but a manual write
  # of one made the cleanup worker's backoff guard crash every run on that row
  # (G488 exploratory campaign, 2026-11-02). Any negative value already there
  # is reset to 0 first, so the constraint can be added.
  def up do
    execute "UPDATE attachment_blob_deletions SET attempts = 0 WHERE attempts < 0"

    create constraint(
             :attachment_blob_deletions,
             :attachment_blob_deletions_attempts_non_negative,
             check: "attempts >= 0"
           )
  end

  def down do
    drop constraint(:attachment_blob_deletions, :attachment_blob_deletions_attempts_non_negative)
  end
end
