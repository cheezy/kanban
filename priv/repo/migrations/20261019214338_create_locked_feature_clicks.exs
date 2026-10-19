defmodule Kanban.Repo.Migrations.CreateLockedFeatureClicks do
  @moduledoc """
  Records when each user's click on a locked feature's prompt was last
  counted, so `Kanban.Plans.LockedFeatureClicks` counts a user at most once
  per feature a week.

  The limit used to live in `Kanban.RateLimit`'s in-memory buckets, which
  reset on every restart and are kept separately on each machine, so weekly
  demand was overcounted after each deploy. One row per user and feature,
  held in the database, survives both.

  The table holds a user id, a feature name and a timestamp, nothing else,
  and a user's rows go when the user is deleted.
  """

  use Ecto.Migration

  def change do
    create table(:locked_feature_clicks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feature, :string, null: false
      add :counted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:locked_feature_clicks, [:user_id, :feature])
  end
end
