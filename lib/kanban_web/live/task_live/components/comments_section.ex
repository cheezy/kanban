defmodule KanbanWeb.TaskLive.Components.CommentsSection do
  @moduledoc """
  Renders the task comments list. Always rendered (handles its own empty state).
  """
  use KanbanWeb, :html

  attr :comments, :list, required: true

  def comments_section(assigns) do
    ~H"""
    <div>
      <h4 style="margin: 0 0 8px; font-size: 11.5px; font-weight: 600; color: var(--ink-2);">
        {gettext("Comments")}
      </h4>
      <%= if Enum.empty?(@comments) do %>
        <p style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;">
          {gettext("No comments yet")}
        </p>
      <% else %>
        <div style="display: flex; flex-direction: column; gap: 10px; max-height: 12rem; overflow-y: auto;">
          <%= for comment <- @comments do %>
            <div style="display: flex; align-items: flex-start; gap: 8px; font-size: 12.5px;">
              <div style="margin-top: 2px; display: inline-flex; color: var(--ink-4);">
                <.icon name="hero-chat-bubble-left" class="w-3 h-3" />
              </div>
              <div style="flex: 1;">
                <p style="margin: 0; color: var(--ink); white-space: pre-wrap;">
                  {comment.content}
                </p>
                <p style="margin: 4px 0 0; font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
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
