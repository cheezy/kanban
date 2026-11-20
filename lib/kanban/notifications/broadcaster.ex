defmodule Kanban.Notifications.Broadcaster do
  @moduledoc """
  The per-user PubSub topic that carries notification events.

  `Kanban.Notifications.Delivery` broadcasts `{:notification_created, n}` on
  it for every new in-app row, and `Kanban.Notifications.Inbox` broadcasts
  `{:notifications_read, unread_count}` after a mark. Subscribers (the bell,
  the inbox, the mobile channel) use `subscribe/1`.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User

  @doc """
  Returns the PubSub topic carrying one user's notification events.
  """
  @spec topic(Scope.t() | User.t() | pos_integer()) :: String.t()
  def topic(%Scope{user: %User{id: id}}), do: topic(id)
  def topic(%User{id: id}), do: topic(id)
  def topic(user_id) when is_integer(user_id), do: "user:#{user_id}:notifications"

  @doc """
  Subscribes the calling process to a user's notification topic.
  """
  @spec subscribe(Scope.t() | User.t() | pos_integer()) :: :ok | {:error, term()}
  def subscribe(scope_or_user), do: Phoenix.PubSub.subscribe(Kanban.PubSub, topic(scope_or_user))

  @doc """
  Broadcasts `message` on the user's notification topic.
  """
  @spec broadcast(pos_integer(), term()) :: :ok | {:error, term()}
  def broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Kanban.PubSub, topic(user_id), message)
  end
end
