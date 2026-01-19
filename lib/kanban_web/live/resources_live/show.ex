defmodule KanbanWeb.ResourcesLive.Show do
  @moduledoc """
  LiveView for displaying a single how-to guide.
  Shows step-by-step content with images and navigation.
  """
  use KanbanWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <div class="mx-auto max-w-4xl px-4 sm:px-6 lg:px-8 py-12">
        <div class="mb-8">
          <.link
            href={~p"/resources"}
            class="text-sm text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300 flex items-center gap-1"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
            {gettext("Back to Resources")}
          </.link>
        </div>

        <div class="text-center">
          <h1 class="text-3xl font-bold text-base-content mb-4">
            {gettext("Resource")} {@id}
          </h1>
          <p class="text-base-content/60">
            {gettext("This resource guide is coming soon.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)
    {:ok, assign(socket, id: id, page_title: gettext("Resource"))}
  end
end
