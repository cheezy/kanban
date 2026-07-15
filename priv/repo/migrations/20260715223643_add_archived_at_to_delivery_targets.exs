defmodule Kanban.Repo.Migrations.AddArchivedAtToDeliveryTargets do
  use Ecto.Migration

  # Nullable: NULL means the target is active, so existing rows stay active
  # without a backfill. :utc_datetime_usec matches the schema's timestamps
  # precision. add/2 inside change/0 auto-reverses to remove/1.
  def change do
    alter table(:delivery_targets) do
      add :archived_at, :utc_datetime_usec
    end
  end
end
