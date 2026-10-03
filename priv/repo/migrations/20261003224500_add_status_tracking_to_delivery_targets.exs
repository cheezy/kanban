defmodule Kanban.Repo.Migrations.AddStatusTrackingToDeliveryTargets do
  use Ecto.Migration

  # The last delivery status the hourly sweeper observed for a target, and
  # when it changed (W2291). A notification watermark only: every read path
  # still derives a target's status at read time.
  def change do
    alter table(:delivery_targets) do
      add :last_notified_status, :string
      add :status_changed_at, :utc_datetime
    end
  end
end
