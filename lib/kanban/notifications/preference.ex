defmodule Kanban.Notifications.Preference do
  @moduledoc """
  A user's delivery preference for one notification event type.

  Rows exist only for preferences a user has changed. Missing rows fall back
  to the in-code defaults in `Kanban.Notifications.default_preference/1`, so
  no backfill is needed for existing users.

  This module owns the canonical event type list (`event_types/0`), which
  `Kanban.Notifications.Notification` shares so the two enums never drift.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @event_types [
    :review_requested,
    :task_assigned,
    :claim_expired,
    :goal_completed,
    :weekly_digest,
    :comment_added,
    :mentioned,
    :task_reviewed,
    :task_unclaimed,
    :board_access_changed,
    :after_goal_failed,
    :target_status_changed
  ]

  @type t :: %__MODULE__{}

  schema "notification_preferences" do
    belongs_to :user, Kanban.Accounts.User

    field :event_type, Ecto.Enum, values: @event_types
    field :in_app, :boolean, default: true
    field :email, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns every notification event type, in display order.
  """
  def event_types, do: @event_types

  @doc """
  Casts only the delivery flags. `user_id` and `event_type` are set on the
  struct by the context so callers cannot redirect a preference to another
  user or forge an event type.
  """
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:in_app, :email])
    |> validate_required([:user_id, :event_type, :in_app, :email])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :event_type])
  end
end
