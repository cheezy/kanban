defmodule KanbanWeb.NotificationsLocked do
  @moduledoc """
  What `/notifications` and `/users/notifications` show a user without paid
  access while paid plans are enforced (`current_scope.notifications_locked`).

  It is the `KanbanWeb.LockedFeature` panel for `:notifications`, followed by
  links to the Review queue and My Work, which list the tasks waiting for the
  user without notifications. The links sit outside the panel because the
  panel renders its slot as an inert preview.
  """
  use KanbanWeb, :html

  alias KanbanWeb.LockedFeature

  attr :id, :string, required: true

  def panel(assigns) do
    ~H"""
    <div id={@id} data-notifications-locked>
      <LockedFeature.locked_feature feature={:notifications} variant={:panel} id={"#{@id}-panel"} />
      <p style="margin: 12px 0 0; font-size: 13px; line-height: 1.5; color: var(--ink-2); text-wrap: pretty;">
        {gettext("Tasks waiting for you are always listed in the Review queue and My Work.")}
      </p>
      <div style="display: flex; flex-wrap: wrap; gap: 8px 16px; margin-top: 8px; font-size: 13px;">
        <.link
          navigate={~p"/review"}
          data-locked-review-link
          class="inline-flex items-center gap-1 min-h-11 sm:min-h-0"
          style="color: var(--ink); font-weight: 500; text-decoration: underline; text-underline-offset: 2px;"
        >
          <.icon name="hero-inbox-arrow-down" class="w-4 h-4" />
          {gettext("Review queue")}
        </.link>
        <.link
          navigate={~p"/my-work"}
          data-locked-my-work-link
          class="inline-flex items-center gap-1 min-h-11 sm:min-h-0"
          style="color: var(--ink); font-weight: 500; text-decoration: underline; text-underline-offset: 2px;"
        >
          <.icon name="hero-clipboard-document-check" class="w-4 h-4" />
          {gettext("My Work")}
        </.link>
      </div>
    </div>
    """
  end
end
