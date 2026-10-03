defmodule Kanban.NotificationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Notifications` context.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications

  @doc """
  Generate a notification for `user`. `attrs` may include `:event_type`
  (default `:board_access_changed`, which needs no board) plus any
  `Kanban.Notifications.notify/3` attribute. Pass `:board_id` for event
  types that require a board.
  """
  def notification_fixture(user, attrs \\ %{}) do
    {event_type, attrs} =
      attrs
      |> Enum.into(%{
        event_type: :board_access_changed,
        title: "Notification #{System.unique_integer([:positive])}",
        url_path: "/boards"
      })
      |> Map.pop(:event_type)

    {:ok, [notification]} = Notifications.notify(event_type, [user], attrs)

    notification
  end

  @doc """
  Generate a saved preference for `user` and `event_type`.
  """
  def preference_fixture(user, event_type, attrs \\ %{in_app: true, email: false}) do
    {:ok, preference} =
      user
      |> Scope.for_user()
      |> Notifications.update_preference(event_type, attrs)

    preference
  end
end
