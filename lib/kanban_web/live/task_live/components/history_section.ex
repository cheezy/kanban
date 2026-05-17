defmodule KanbanWeb.TaskLive.Components.HistorySection do
  @moduledoc """
  Renders the task history / audit trail. Always rendered (handles its own
  empty state).
  """
  use KanbanWeb, :html

  attr :histories, :list, required: true

  def history_section(assigns) do
    ~H"""
    <div>
      <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
        {gettext("History")}
      </h4>
      <%= if Enum.empty?(@histories) do %>
        <p class="text-base-content opacity-60 text-sm">{gettext("No history available")}</p>
      <% else %>
        <div class="space-y-3 max-h-48 overflow-y-auto">
          <%= for history <- @histories do %>
            <div class="flex items-start gap-2 text-sm">
              <div class="mt-0.5">
                <%= case history.type do %>
                  <% :creation -> %>
                    <.icon name="hero-plus-circle" class="w-4 h-4 text-green-600" />
                  <% :move -> %>
                    <.icon name="hero-arrow-right-circle" class="w-4 h-4 text-[var(--st-ready)]" />
                  <% :priority_change -> %>
                    <.icon name="hero-exclamation-circle" class="w-4 h-4 text-orange-600" />
                  <% :assignment -> %>
                    <.icon name="hero-user-circle" class="w-4 h-4 text-purple-600" />
                <% end %>
              </div>
              <div class="flex-1">
                <p class="text-base-content">
                  <%= case history.type do %>
                    <% :creation -> %>
                      <span class="font-semibold">{gettext("Created")}</span>
                    <% :move -> %>
                      <span class="font-semibold">{gettext("Moved")}</span>
                      {gettext("from")}
                      <span class="font-semibold">{history.from_column}</span> {gettext("to")}
                      <span class="font-semibold">{history.to_column}</span>
                    <% :priority_change -> %>
                      <span class="font-semibold">{gettext("Priority changed")}</span>
                      {gettext("from")}
                      <span class="font-semibold">{history.from_priority}</span> {gettext("to")}
                      <span class="font-semibold">{history.to_priority}</span>
                    <% :assignment -> %>
                      <%= cond do %>
                        <% history.from_user_id == nil && history.to_user_id != nil -> %>
                          <span class="font-semibold">{gettext("Assigned to")}</span>
                          <span class="font-semibold text-purple-600">
                            {history.to_user.name}
                          </span>
                        <% history.from_user_id != nil && history.to_user_id == nil -> %>
                          <span class="font-semibold">{gettext("Unassigned from")}</span>
                          <span class="font-semibold text-purple-600">
                            {history.from_user.name}
                          </span>
                        <% true -> %>
                          <span class="font-semibold">{gettext("Reassigned")}</span>
                          {gettext("from")}
                          <span class="font-semibold text-purple-600">
                            {history.from_user.name}
                          </span>
                          {gettext("to")}
                          <span class="font-semibold text-purple-600">
                            {history.to_user.name}
                          </span>
                      <% end %>
                  <% end %>
                </p>
                <p class="text-xs text-base-content opacity-60">
                  {Calendar.strftime(history.inserted_at, "%B %d, %Y at %I:%M %p")}
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
