defmodule Kanban.Repo.Migrations.CreateClaimExpiryReports do
  @moduledoc """
  One row per expired claim the claim expiry sweeper has reported (W2340).

  The sweeper (`Kanban.Notifications.ClaimExpiryWorker`) sees each expired
  claim on every run inside its lookback window. A claim is identified by its
  task and its `claim_expires_at`, so the unique index lets the sweeper emit
  `[:kanban, :task, :claim_expired]` once per claim, however many times it
  runs, on however many nodes. A new claim on the same task has a new
  `claim_expires_at` and is reported again. The sweeper prunes rows once they
  are older than its lookback window plus a day, and deleting a task deletes
  its rows.
  """

  use Ecto.Migration

  def change do
    create table(:claim_expiry_reports) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :claim_expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:claim_expiry_reports, [:task_id, :claim_expires_at])
    create index(:claim_expiry_reports, [:claim_expires_at])
  end
end
