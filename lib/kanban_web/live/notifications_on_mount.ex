defmodule KanbanWeb.NotificationsOnMount do
  @moduledoc """
  Keeps the notification bell's unread count live in every authenticated
  LiveView.

  `KanbanWeb.Layouts.app/1` is a function component rendered from many
  templates (and from controller pages), so it cannot subscribe to PubSub
  itself. This hook runs after `KanbanWeb.UserAuth` in the authenticated,
  sudo and admin `live_session`s instead: it stores the unread count in
  `current_scope.unread_notifications`, subscribes the LiveView process to the
  user's own notification topic once connected, and attaches a `handle_info`
  hook that updates the count as messages arrive.

  The topic always comes from the server-side `current_scope`, never from
  params. The hook halts the two notification messages so LiveViews without
  matching `handle_info` clauses never see them; a LiveView that wants them
  too (the inbox) assigns `notification_inbox?: true` in `mount/3`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Notifications

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %User{}} = scope ->
        count = Notifications.unread_count(scope)
        socket = put_count(socket, count)
        {:cont, maybe_subscribe(socket, scope)}

      _no_user ->
        {:cont, socket}
    end
  end

  @doc false
  def handle_message({:notification_created, _notification}, socket) do
    socket
    |> increment()
    |> reply()
  end

  def handle_message({:notifications_read, count}, socket) when is_integer(count) do
    socket
    |> put_count(count)
    |> reply()
  end

  def handle_message(_message, socket), do: {:cont, socket}

  defp maybe_subscribe(socket, scope) do
    if connected?(socket) do
      Notifications.subscribe(scope)
      attach_hook(socket, :notifications_bell, :handle_info, &__MODULE__.handle_message/2)
    else
      socket
    end
  end

  defp reply(socket) do
    if socket.assigns[:notification_inbox?], do: {:cont, socket}, else: {:halt, socket}
  end

  defp increment(socket) do
    count = socket.assigns.current_scope.unread_notifications || 0
    put_count(socket, count + 1)
  end

  defp put_count(socket, count) do
    scope = %{socket.assigns.current_scope | unread_notifications: count}
    assign(socket, :current_scope, scope)
  end
end
