defmodule KanbanWeb.SubscriberHTML do
  @moduledoc """
  Templates for the release announcement list's confirm and unsubscribe
  pages. Like the notification unsubscribe page they render in the standalone
  auth frame rather than `Layouts.app`, so a signed-in visitor never sees
  their own navigation around a page that may belong to someone else's link.
  """

  use KanbanWeb, :html

  import KanbanWeb.AuthFrame

  embed_templates "subscriber_html/*"

  @doc "The link back to the changelog, under each finished state."
  def changelog_link(assigns) do
    ~H"""
    <a
      href={~p"/changelog"}
      style="margin-top: 24px; font-size: 13.5px; color: var(--ink); text-decoration: underline;"
    >
      {gettext("Back to the changelog")}
    </a>
    """
  end
end
