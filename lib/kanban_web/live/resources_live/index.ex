defmodule KanbanWeb.ResourcesLive.Index do
  @moduledoc """
  LiveView for the Resources landing page.
  Displays a searchable, filterable grid of how-to guides.
  """
  use KanbanWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-12">
        <div class="text-center mb-12">
          <h1 class="text-4xl font-bold text-base-content mb-4">
            {gettext("Resources")}
          </h1>
          <p class="text-lg text-base-content/70 max-w-2xl mx-auto">
            {gettext("Learn how to get the most out of Stride with our guides and tutorials.")}
          </p>
        </div>

        <div class="text-center text-base-content/60">
          <p>{gettext("Coming soon: How-to guides, tutorials, and documentation.")}</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)
    {:ok, assign(socket, page_title: gettext("Resources"))}
  end
end
