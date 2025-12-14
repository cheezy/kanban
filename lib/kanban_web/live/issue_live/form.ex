defmodule KanbanWeb.IssueLive.Form do
  @moduledoc """
  LiveView for the GitHub issue submission form.
  This is rendered as a component within the About page.
  """
  use KanbanWeb, :live_view

  alias Kanban.GitHub

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={KanbanWeb.IssueLive.FormComponent} id="issue-form" />
    """
  end

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)
    {:ok, assign(socket, :configured, GitHub.configured?())}
  end
end
