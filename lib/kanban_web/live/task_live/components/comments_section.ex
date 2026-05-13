defmodule KanbanWeb.TaskLive.Components.CommentsSection do
  @moduledoc """
  Renders the task comments list. Always rendered (handles its own empty state).
  """
  use KanbanWeb, :html

  attr :comments, :list, required: true

  def comments_section(assigns) do
    ~H"""
    <div>
      <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
        {gettext("Comments")}
      </h4>
      <%= if Enum.empty?(@comments) do %>
        <p class="text-base-content opacity-60 text-sm">{gettext("No comments yet")}</p>
      <% else %>
        <div class="space-y-3 max-h-48 overflow-y-auto">
          <%= for comment <- @comments do %>
            <div class="flex items-start gap-2 text-sm">
              <div class="mt-0.5">
                <.icon name="hero-chat-bubble-left" class="w-4 h-4 text-base-content opacity-40" />
              </div>
              <div class="flex-1">
                <p class="text-base-content whitespace-pre-wrap">{comment.content}</p>
                <p class="text-xs text-gray-500 mt-1">
                  {Calendar.strftime(comment.inserted_at, "%B %d, %Y at %I:%M %p")}
                </p>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
