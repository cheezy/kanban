defmodule KanbanWeb.TaskLive.Components.IntegrationPointsSection do
  @moduledoc """
  Renders the integration_points map (telemetry events, PubSub broadcasts,
  Phoenix channels, external APIs). Caller is responsible for the outer
  visibility/presence guard.
  """
  use KanbanWeb, :html

  attr :integration_points, :map, required: true

  def integration_points_section(assigns) do
    ~H"""
    <div class="bg-indigo-50 border border-indigo-200 rounded-lg p-4">
      <h4 class="text-sm font-semibold text-indigo-900 mb-2">
        {gettext("Integration Points")}
      </h4>
      <div class="space-y-3">
        <%= if Map.has_key?(@integration_points, "telemetry_events") && !Enum.empty?(@integration_points["telemetry_events"]) do %>
          <div>
            <p class="text-xs font-semibold text-indigo-900 opacity-70 mb-1">
              {gettext("Telemetry Events")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for event <- @integration_points["telemetry_events"] do %>
                <li class="text-indigo-900 font-mono text-xs">{event}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%= if Map.has_key?(@integration_points, "pubsub_broadcasts") && !Enum.empty?(@integration_points["pubsub_broadcasts"]) do %>
          <div>
            <p class="text-xs font-semibold text-indigo-900 opacity-70 mb-1">
              {gettext("PubSub Broadcasts")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for broadcast <- @integration_points["pubsub_broadcasts"] do %>
                <li class="text-indigo-900 font-mono text-xs">{broadcast}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%= if Map.has_key?(@integration_points, "phoenix_channels") && !Enum.empty?(@integration_points["phoenix_channels"]) do %>
          <div>
            <p class="text-xs font-semibold text-indigo-900 opacity-70 mb-1">
              {gettext("Phoenix Channels")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for channel <- @integration_points["phoenix_channels"] do %>
                <li class="text-indigo-900 font-mono text-xs">{channel}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%= if Map.has_key?(@integration_points, "external_apis") && !Enum.empty?(@integration_points["external_apis"]) do %>
          <div>
            <p class="text-xs font-semibold text-indigo-900 opacity-70 mb-1">
              {gettext("External APIs")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for api <- @integration_points["external_apis"] do %>
                <li class="text-indigo-900 font-mono text-xs">{api}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
