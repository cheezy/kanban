defmodule KanbanWeb.TaskLive.Form.PlanningSections do
  @moduledoc """
  The task form's two largest JSONB-map sections — `testing_strategy` and
  `integration_points` — extracted from `form_component.html.heex` (which was
  well over the module-size guidance in `AGENTS.md`).

  Both edit a map column as several named string lists, with add/remove buttons
  per list targeting the parent LiveComponent.
  """
  use KanbanWeb, :html

  attr :f, Phoenix.HTML.Form, required: true
  attr :field_visibility, :map, required: true
  attr :myself, :any, required: true

  def planning_sections(assigns) do
    ~H"""
    <%= if field_visible?(@field_visibility, "testing_strategy") do %>
      <%!-- Testing Strategy Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Testing Strategy")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:testing_strategy].errors, &translate_error/1)}>
          {msg}
        </.error>
        <% testing_strategy = Ecto.Changeset.get_field(@f.source, :testing_strategy) || %{} %>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("Unit Tests")}</span>
          </label>
          <input type="hidden" name="task[testing_strategy][unit_tests][]" value="" />
          <%= for {test, index} <- Enum.with_index(ensure_list(Map.get(testing_strategy, "unit_tests", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[testing_strategy][unit_tests][]"
                value={test}
                placeholder={gettext("Unit test description")}
                style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-unit-test"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-unit-test"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add Unit Test")}
          </button>
        </div>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("Integration Tests")}</span>
          </label>
          <input type="hidden" name="task[testing_strategy][integration_tests][]" value="" />
          <%= for {test, index} <- Enum.with_index(ensure_list(Map.get(testing_strategy, "integration_tests", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[testing_strategy][integration_tests][]"
                value={test}
                placeholder={gettext("Integration test description")}
                style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-integration-test"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-integration-test"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add Integration Test")}
          </button>
        </div>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("Manual Tests")}</span>
          </label>
          <input type="hidden" name="task[testing_strategy][manual_tests][]" value="" />
          <%= for {test, index} <- Enum.with_index(ensure_list(Map.get(testing_strategy, "manual_tests", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[testing_strategy][manual_tests][]"
                value={test}
                placeholder={gettext("Manual test description")}
                style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-manual-test"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-manual-test"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add Manual Test")}
          </button>
        </div>
      </div>
    <% end %>

    <%= if field_visible?(@field_visibility, "integration_points") do %>
      <%!-- Integration Points Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Integration Points")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:integration_points].errors, &translate_error/1)}>
          {msg}
        </.error>
        <% integration_points = Ecto.Changeset.get_field(@f.source, :integration_points) || %{} %>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("Telemetry Events")}</span>
          </label>
          <input type="hidden" name="task[integration_points][telemetry_events][]" value="" />
          <%= for {event, index} <- Enum.with_index(ensure_list(Map.get(integration_points, "telemetry_events", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[integration_points][telemetry_events][]"
                value={event}
                placeholder={gettext("[:kanban, :domain, :action]")}
                style="flex: 1; padding: 6px 10px; font-size: 11.5px; font-family: var(--font-mono); color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-telemetry-event"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-telemetry-event"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add Telemetry Event")}
          </button>
        </div>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("PubSub Broadcasts")}</span>
          </label>
          <input type="hidden" name="task[integration_points][pubsub_broadcasts][]" value="" />
          <%= for {broadcast, index} <- Enum.with_index(ensure_list(Map.get(integration_points, "pubsub_broadcasts", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[integration_points][pubsub_broadcasts][]"
                value={broadcast}
                placeholder={gettext("topic:event")}
                style="flex: 1; padding: 6px 10px; font-size: 11.5px; font-family: var(--font-mono); color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-pubsub-broadcast"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-pubsub-broadcast"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add PubSub Broadcast")}
          </button>
        </div>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("Phoenix Channels")}</span>
          </label>
          <input type="hidden" name="task[integration_points][phoenix_channels][]" value="" />
          <%= for {channel, index} <- Enum.with_index(ensure_list(Map.get(integration_points, "phoenix_channels", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[integration_points][phoenix_channels][]"
                value={channel}
                placeholder={gettext("channel:event")}
                style="flex: 1; padding: 6px 10px; font-size: 11.5px; font-family: var(--font-mono); color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-phoenix-channel"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-phoenix-channel"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add Phoenix Channel")}
          </button>
        </div>

        <div class="mb-4">
          <label style="display: block; font-size: 11.5px; font-weight: 600; color: var(--ink-2); margin: 0 0 6px;">
            <span>{gettext("External APIs")}</span>
          </label>
          <input type="hidden" name="task[integration_points][external_apis][]" value="" />
          <%= for {api, index} <- Enum.with_index(ensure_list(Map.get(integration_points, "external_apis", []))) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[integration_points][external_apis][]"
                value={api}
                placeholder={gettext("API endpoint or service")}
                style="flex: 1; padding: 6px 10px; font-size: 11.5px; font-family: var(--font-mono); color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
              />
              <button
                type="button"
                phx-click="remove-external-api"
                phx-value-index={index}
                phx-target={@myself}
                style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
              >
                {gettext("Remove")}
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-external-api"
            phx-target={@myself}
            style="padding: 5px 10px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
          >
            + {gettext("Add External API")}
          </button>
        </div>
      </div>
    <% end %>

    <%!-- Dependencies Section --%>
    <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
      <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
        {gettext("Dependencies")}
      </h3>
      <.error :for={msg <- Enum.map(@f[:dependencies].errors, &translate_error/1)}>{msg}</.error>
      <input type="hidden" name="task[dependencies][]" value="" />
      <%= for {dep, index} <- Enum.with_index(Ecto.Changeset.get_field(@f.source, :dependencies) || []) do %>
        <div class="flex gap-2 mb-2">
          <input
            type="text"
            name="task[dependencies][]"
            value={dep}
            placeholder={gettext("Task identifier (e.g., W01A)")}
            style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
          />
          <button
            type="button"
            phx-click="remove-dependency"
            phx-value-index={index}
            phx-target={@myself}
            style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
          >
            {gettext("Remove")}
          </button>
        </div>
      <% end %>
      <button
        type="button"
        phx-click="add-dependency"
        phx-target={@myself}
        style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
      >
        + {gettext("Add Dependency")}
      </button>
    </div>

    <%= if Ecto.Changeset.get_field(@f.source, :created_by_agent) || Ecto.Changeset.get_field(@f.source, :completed_by_agent) do %>
      <%!-- Agent Tracking Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Agent Tracking")}
        </h3>
        <.input field={@f[:created_by_agent]} type="text" label={gettext("Created By Agent")} />
        <.input field={@f[:completed_by_agent]} type="text" label={gettext("Completed By Agent")} />
        <.input
          field={@f[:completion_summary]}
          type="textarea"
          label={gettext("Completion Summary")}
          rows="2"
        />
      </div>
    <% end %>
    """
  end

  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end

  # Tolerates the legacy shape where a map key held a bare string instead of a
  # list (mirrors the same guard the form component applies elsewhere).
  defp ensure_list(nil), do: []
  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(value) when is_binary(value), do: [value]
  defp ensure_list(_value), do: []
end
