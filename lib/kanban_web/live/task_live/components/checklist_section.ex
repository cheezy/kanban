defmodule KanbanWeb.TaskLive.Components.ChecklistSection do
  @moduledoc """
  Renders the testing-strategy checklist (unit / integration / manual tests).
  Caller is responsible for the outer visibility/presence guard.
  """
  use KanbanWeb, :html

  attr :testing_strategy, :map, required: true

  def checklist_section(assigns) do
    ~H"""
    <div class="bg-[var(--st-ready-soft)] border border-[var(--st-ready)] rounded-lg p-4">
      <h4 class="text-sm font-semibold text-[var(--st-ready)] mb-2">{gettext("Testing Strategy")}</h4>
      <div class="space-y-3">
        <%= if Map.has_key?(@testing_strategy, "unit_tests") && has_test_items?(@testing_strategy["unit_tests"]) do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70 mb-1">
              {gettext("Unit Tests")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for test <- ensure_test_list(@testing_strategy["unit_tests"]) do %>
                <li class="text-[var(--st-ready)]">{test}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%= if Map.has_key?(@testing_strategy, "integration_tests") && has_test_items?(@testing_strategy["integration_tests"]) do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70 mb-1">
              {gettext("Integration Tests")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for test <- ensure_test_list(@testing_strategy["integration_tests"]) do %>
                <li class="text-[var(--st-ready)]">{test}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%= if Map.has_key?(@testing_strategy, "manual_tests") && has_test_items?(@testing_strategy["manual_tests"]) do %>
          <div>
            <p class="text-xs font-semibold text-[var(--st-ready)] opacity-70 mb-1">
              {gettext("Manual Tests")}
            </p>
            <ul class="list-disc list-inside space-y-1">
              <%= for test <- ensure_test_list(@testing_strategy["manual_tests"]) do %>
                <li class="text-[var(--st-ready)]">{test}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp has_test_items?(value) when is_list(value), do: value != []
  defp has_test_items?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_test_items?(_), do: false

  defp ensure_test_list(value) when is_list(value), do: value
  defp ensure_test_list(value) when is_binary(value), do: [value]
  defp ensure_test_list(_), do: []
end
