defmodule Kanban.Repo.Migrations.CreateUserPushSettings do
  @moduledoc """
  Creates `user_push_settings`, one row per person holding the push mode,
  quiet hours and the one time zone quiet hours follow
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9, §8).

  The row is created on the person's first settings change or when their
  first device registers, taking that device's zone. A person with devices
  registered before this migration gets their row here, with the zone of
  their earliest device that has one. `time_zone` stays null
  until a device or a settings change gives one. The per-event switches live
  in `notification_preferences.push`; `mode` only records the last preset
  chosen. Rows are deleted with their user.
  """
  use Ecto.Migration

  def change do
    create table(:user_push_settings, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true, null: false
      add :mode, :string, null: false, default: "decisions"
      add :quiet_hours_enabled, :boolean, null: false, default: false
      add :quiet_start, :time, null: false, default: "22:00:00"
      add :quiet_end, :time, null: false, default: "07:00:00"
      add :time_zone, :string
      add :last_summary_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:user_push_settings, :user_push_settings_mode,
             check: "mode IN ('decisions', 'every')"
           )

    create constraint(:user_push_settings, :user_push_settings_quiet_range,
             check: "quiet_start <> quiet_end"
           )

    execute(
      """
      INSERT INTO user_push_settings (user_id, time_zone, inserted_at, updated_at)
      SELECT DISTINCT ON (user_id) user_id, time_zone, now(), now()
      FROM user_devices
      ORDER BY user_id, (time_zone IS NULL), inserted_at, id
      """,
      "SELECT 1"
    )
  end
end
