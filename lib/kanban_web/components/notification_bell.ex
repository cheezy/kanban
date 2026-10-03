defmodule KanbanWeb.NotificationBell do
  @moduledoc """
  The notification bell in the WinTop bar: a link to `/notifications` with an
  unread badge.

  The count comes from `current_scope.unread_notifications`, which
  `KanbanWeb.NotificationsOnMount` keeps live in LiveViews. Controller pages
  never load it, so the count is `nil` there and the bell renders without a
  badge. Nothing renders without a signed-in user.
  """
  use KanbanWeb, :html

  attr :current_scope, :map, default: nil

  def bell(%{current_scope: %{user: %{}} = scope} = assigns) do
    count = Map.get(scope, :unread_notifications)

    assigns =
      assigns
      |> assign(:label, bell_label(count))
      |> assign(:badge, badge_text(count))

    ~H"""
    <.link
      navigate={~p"/notifications"}
      id="notification-bell"
      data-notification-bell
      aria-label={@label}
      title={@label}
      class="relative inline-flex items-center justify-center w-11 h-11 md:w-8 md:h-8 rounded-md hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style="color: var(--ink-2); text-decoration: none;"
    >
      <.icon name="hero-bell" class="w-5 h-5" />
      <span
        :if={@badge}
        id="notification-bell-badge"
        data-notification-badge
        aria-hidden="true"
        style={[
          "position: absolute; top: 4px; right: 2px;",
          "min-width: 16px; padding: 0 4px; border-radius: 999px;",
          "font-family: var(--font-mono); font-size: 10px; font-weight: 600;",
          "line-height: 14px; text-align: center;",
          "background: var(--stride-orange-soft); color: var(--stride-orange-ink);",
          "border: 1px solid var(--stride-orange);"
        ]}
      >
        {@badge}
      </span>
    </.link>
    """
  end

  def bell(assigns) do
    ~H""
  end

  @doc """
  Returns the badge text for an unread count: `nil` (no badge) unless the
  count is a positive integer, and `"99+"` above 99.
  """
  @spec badge_text(term()) :: String.t() | nil
  def badge_text(count) when is_integer(count) and count > 99, do: "99+"
  def badge_text(count) when is_integer(count) and count > 0, do: Integer.to_string(count)
  def badge_text(_count), do: nil

  defp bell_label(count) when is_integer(count) and count > 0 do
    ngettext("%{count} unread notification", "%{count} unread notifications", count)
  end

  defp bell_label(_count), do: gettext("Notifications")
end
