defmodule KanbanWeb.NotificationLive.Index do
  @moduledoc """
  The notification inbox at `/notifications`: the signed-in user's in-app
  notifications, newest first, with All / Unread filters, mark-read,
  mark-all-read and a load-more button.

  Rows are kept in a stream, so the page holds only a cursor (the oldest
  loaded row) for paging. New notifications arrive over the user's PubSub
  topic, which `KanbanWeb.NotificationsOnMount` subscribes; this view assigns
  `notification_inbox?: true` so that hook passes the messages on after
  updating the bell. Every read and write goes through
  `Kanban.Notifications`, which scopes it to the signed-in user.
  """
  use KanbanWeb, :live_view

  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias KanbanWeb.NotificationLabels
  alias KanbanWeb.TimeAgo

  @page_size 25
  # list_notifications/2 caps a page at 100 rows and every fetch asks for one
  # extra row to learn whether more exist.
  @max_reload 99
  # Same app-relative rule as Notification's changeset: re-checked here so a
  # row can never send the browser off-site.
  @safe_path ~r{\A/(?![/\\])[^\s\x00-\x1f\x7f]*\z}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Notifications"))
      |> assign(:notification_inbox?, true)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = filter_from_params(params)

    socket =
      socket
      |> assign(:filter, filter)
      |> reload(@page_size)

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more", _params, %{assigns: %{cursor: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    %{cursor: cursor, loaded: loaded} = socket.assigns
    {rows, more?} = fetch(socket, @page_size, before: cursor)

    socket =
      socket
      |> stream(:notifications, rows)
      |> assign(loaded: loaded + length(rows), cursor: List.last(rows) || cursor)
      |> assign(:has_more, more?)

    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    case Notifications.mark_read(socket.assigns.current_scope, id) do
      {:ok, notification} -> {:noreply, stream_insert(socket, :notifications, notification)}
      {:error, :not_found} -> {:noreply, not_found(socket)}
    end
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    case Notifications.mark_read(socket.assigns.current_scope, id) do
      {:ok, notification} -> {:noreply, navigate_or_stay(socket, notification)}
      {:error, :not_found} -> {:noreply, not_found(socket)}
    end
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    {:ok, _count} = Notifications.mark_all_read(socket.assigns.current_scope)
    {:noreply, reload(socket, @page_size)}
  end

  @impl true
  def handle_info({:notification_created, %Notification{} = notification}, socket) do
    socket =
      socket
      |> stream_insert(:notifications, notification, at: 0)
      |> update(:loaded, &(&1 + 1))
      |> update(:cursor, &(&1 || notification))

    {:noreply, socket}
  end

  # Another tab (or this one) marked rows read: refresh the rows on screen.
  # The hook has already updated the bell.
  @impl true
  def handle_info({:notifications_read, _count}, socket) do
    limit = socket.assigns.loaded |> max(@page_size) |> min(@max_reload)
    {:noreply, reload(socket, limit)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp filter_from_params(%{"filter" => "unread"}), do: :unread
  defp filter_from_params(_params), do: :all

  defp reload(socket, limit) do
    {rows, more?} = fetch(socket, limit, [])

    socket
    |> stream(:notifications, rows, reset: true)
    |> assign(loaded: length(rows), cursor: List.last(rows))
    |> assign(:has_more, more?)
  end

  defp fetch(socket, limit, extra_opts) do
    %{current_scope: scope, filter: filter} = socket.assigns
    opts = [unread_only: filter == :unread, limit: limit + 1] ++ extra_opts
    rows = Notifications.list_notifications(scope, opts)

    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp navigate_or_stay(socket, %Notification{url_path: path} = notification) do
    if safe_path?(path) do
      push_navigate(socket, to: path)
    else
      stream_insert(socket, :notifications, notification)
    end
  end

  defp safe_path?(path) when is_binary(path), do: Regex.match?(@safe_path, path)
  defp safe_path?(_path), do: false

  defp not_found(socket) do
    put_flash(socket, :error, gettext("Notification not found."))
  end

  defp filter_link_style(active?) do
    [
      "display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 5px;",
      "font-size: 12px; font-weight: 500; text-decoration: none;",
      if(active?,
        do:
          "background: var(--surface); color: var(--ink); box-shadow: inset 0 0 0 1px var(--line);",
        else: "background: transparent; color: var(--ink-2);"
      )
    ]
  end
end
