defmodule Kanban.MessagesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Messages` context.
  """

  alias Kanban.Messages

  @doc """
  Generate a message authored by the given sender user.
  """
  def message_fixture(sender, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "Announcement #{System.unique_integer([:positive])}",
        body: "This is a broadcast message body."
      })

    {:ok, message} = Messages.create_message(sender, attrs)

    message
  end

  @doc """
  Generate a dismissal of `message` by `user`.
  """
  def message_dismissal_fixture(message, user) do
    {:ok, dismissal} = Messages.dismiss_message(user, message.id)

    dismissal
  end
end
