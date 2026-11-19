defmodule Kanban.Repo.Migrations.AddPushToNotificationPreferences do
  @moduledoc """
  Adds the per-event `push` switch to `notification_preferences`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9, §8).

  A missing row still falls back to `Kanban.Notifications.default_preference/1`,
  which turns push on for the four decision events. A row saved before this
  column existed was saved for its in-app or email switch, never for push, so
  those four event types get `push = true` here and keep the default the
  person never changed; every other row keeps the column default, `false`.
  """
  use Ecto.Migration

  @decision_events ~w(review_requested task_unclaimed claim_expired after_goal_failed)

  def up do
    alter table(:notification_preferences) do
      add :push, :boolean, null: false, default: false
    end

    flush()

    in_list = Enum.map_join(@decision_events, ", ", &"'#{&1}'")
    execute "UPDATE notification_preferences SET push = true WHERE event_type IN (#{in_list})"
  end

  def down do
    alter table(:notification_preferences) do
      remove :push
    end
  end
end
