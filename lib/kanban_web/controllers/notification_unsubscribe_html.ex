defmodule KanbanWeb.NotificationUnsubscribeHTML do
  @moduledoc """
  Templates for the public notification unsubscribe page. It renders in the
  standalone auth frame rather than `Layouts.app`, so a signed-in visitor
  never sees their own navigation around a page that may belong to someone
  else's link.
  """

  use KanbanWeb, :html

  import KanbanWeb.AuthFrame

  embed_templates "notification_unsubscribe_html/*"

  @doc false
  def preferences_path, do: ~p"/users/notifications"
end
