defmodule Kanban.Repo.Migrations.CreateApprovalChallenges do
  @moduledoc """
  Creates `approval_challenges`, the one-time nonces a device signs to approve
  a review (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.6, §7.5, §8).

  A nonce is bound to the device, the task and the task's
  `review_requested_at` and a fingerprint of the submission under review,
  lives 2 minutes and is used once. Only its SHA-256
  hash is stored, unique across the table. Rows are deleted with their device
  or task, and `Kanban.Reviews.ApprovalChallengePurgeWorker` deletes expired
  rows daily.
  """
  use Ecto.Migration

  def change do
    create table(:approval_challenges) do
      add :device_id, references(:user_devices, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :nonce_hash, :string, null: false
      add :review_requested_at, :utc_datetime
      add :review_fingerprint, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:approval_challenges, [:nonce_hash])
    create index(:approval_challenges, [:device_id])
    create index(:approval_challenges, [:task_id])
    create index(:approval_challenges, [:expires_at])
  end
end
