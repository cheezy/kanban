defmodule Kanban.Plans.LockedFeatureClicks do
  @moduledoc """
  Decides whether a click on a locked feature's prompt counts as demand.

  Each user counts at most once per feature in any 7 days, the period the
  `locked_feature_clicked` metric is read over, so a weekly count is close to
  the number of distinct users who asked for a feature.

  The last counted click is stored per user and feature
  (`Kanban.Plans.LockedFeatureClick`), so the limit survives restarts and
  deploys and holds across every machine. One upsert both checks and records
  it: a first click inserts the row, a click 7 days or more after the last
  counted one moves its time forward, and any other click changes nothing.
  Two clicks at the same moment cannot both count, because the row lock
  serialises them.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Plans.LockedFeatureClick
  alias Kanban.Repo

  @period_days 7

  @doc """
  Records a click by `user` on `feature`'s prompt at `now`.

  Returns `:counted` when the click should be counted, or `:already_counted`
  when the same user's click on the same feature was counted less than 7 days
  before `now`. `feature` must be one of `Kanban.Plans.features/0`.
  """
  @spec count_click(User.t(), atom(), DateTime.t()) :: :counted | :already_counted
  def count_click(%User{id: user_id}, feature, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@period_days, :day)

    refresh_if_due =
      from(c in LockedFeatureClick,
        where: c.counted_at <= ^cutoff,
        update: [set: [counted_at: ^now]]
      )

    # On a conflict whose row is not due, Postgres updates and returns nothing;
    # allow_stale turns that into a struct without an id instead of an error.
    %LockedFeatureClick{user_id: user_id, feature: feature, counted_at: now}
    |> Repo.insert!(
      on_conflict: refresh_if_due,
      conflict_target: [:user_id, :feature],
      returning: [:id],
      allow_stale: true
    )
    |> case do
      %LockedFeatureClick{id: nil} -> :already_counted
      %LockedFeatureClick{} -> :counted
    end
  end
end
