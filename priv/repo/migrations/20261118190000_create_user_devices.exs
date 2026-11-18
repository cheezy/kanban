defmodule Kanban.Repo.Migrations.CreateUserDevices do
  @moduledoc """
  Creates `user_devices`, one row per signed-in phone or tablet
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  A device belongs to a user and is deleted with them. `revoked_by_id` names
  whoever revoked it and is cleared, not cascaded, when that user is deleted,
  so revoking someone else's device never ties its row to the revoker's
  account. `push_token` is unique only where it is set: many devices can have
  none yet.
  """
  use Ecto.Migration

  def change do
    create table(:user_devices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :platform, :string, null: false
      add :device_class, :string, null: false
      add :name, :string, null: false
      add :model, :string
      add :os_version, :string
      add :app_version, :string
      add :locale, :string
      add :time_zone, :string
      add :push_token, :text
      add :push_environment, :string
      add :approval_public_key, :text
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :revoked_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:user_devices, [:user_id])
    create index(:user_devices, [:revoked_by_id])
    create unique_index(:user_devices, [:push_token], where: "push_token IS NOT NULL")

    create constraint(:user_devices, :user_devices_platform,
             check: "platform IN ('ios', 'android')"
           )

    create constraint(:user_devices, :user_devices_device_class,
             check: "device_class IN ('phone', 'tablet')"
           )

    create constraint(:user_devices, :user_devices_push_environment,
             check: "push_environment IS NULL OR push_environment IN ('sandbox', 'production')"
           )
  end
end
