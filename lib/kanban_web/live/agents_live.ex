defmodule KanbanWeb.AgentsLive do
  @moduledoc """
  Workspace-level Agents view at `/agents`.

  Composes `KanbanWeb.AgentsHeader`, `KanbanWeb.AgentRosterCard`, and
  `KanbanWeb.AgentActivityFeed` into a two-column page that surfaces
  every AI agent active across the user's workspace. Heavy logic lives
  in `Kanban.Agents`; this LiveView only binds the context output to the
  presentational components, handles filter-tab clicks, and reacts to
  real-time `{:agent_event, _}` broadcasts on the `"agents"` PubSub
  topic.

  Re-derivation is debounced (`@refresh_debounce_ms`) so a burst of
  events does not redrive the full Agents queries on every message.
  Presence tracking on the same topic powers the "live · N connected"
  indicator.
  """
  use KanbanWeb, :live_view

  alias Kanban.Agents
  alias KanbanWeb.AgentActivityFeed
  alias KanbanWeb.AgentRosterCard
  alias KanbanWeb.AgentsHeader
  alias KanbanWeb.AgentsPresence

  @default_filter :all
  @recent_activity_limit 200
  @event_window_hours 24
  @refresh_debounce_ms 250
  @presence_topic "agents"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, @presence_topic)
      AgentsPresence.track_viewer(socket)
    end

    {:ok,
     socket
     |> assign(:filter, @default_filter)
     |> assign(:selected_agent, nil)
     |> assign(:refresh_scheduled?, false)
     |> assign(:connected_count, connected_count(socket))
     |> load_agents_data()}
  end

  @impl true
  def handle_event("filter_events", %{"filter" => raw_filter}, socket) do
    filter = parse_filter(raw_filter)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(
       :events,
       apply_filters(socket.assigns.all_events, filter, socket.assigns.selected_agent)
     )}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => name}, socket) do
    selected = toggle_agent(socket.assigns.selected_agent, name)

    {:noreply,
     socket
     |> assign(:selected_agent, selected)
     |> assign(
       :events,
       apply_filters(socket.assigns.all_events, socket.assigns.filter, selected)
     )}
  end

  @impl true
  def handle_event("clear_agent_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent, nil)
     |> assign(:events, apply_filters(socket.assigns.all_events, socket.assigns.filter, nil))}
  end

  @impl true
  def handle_info({:agent_event, _payload}, socket) do
    {:noreply, maybe_schedule_refresh(socket)}
  end

  @impl true
  def handle_info(:refresh_agents_data, socket) do
    {:noreply,
     socket
     |> assign(:refresh_scheduled?, false)
     |> load_agents_data()}
  end

  @impl true
  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :connected_count, AgentsPresence.count())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:agents}>
      <:breadcrumbs>
        <span>{gettext("Workspace")}</span>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("Agents")}</span>
      </:breadcrumbs>

      <div
        class="stride-screen"
        style="display: flex; flex-direction: column; height: 100%; min-height: 0;"
      >
        <AgentsHeader.header
          stats={@stats}
          fleet_health={@fleet_health}
          event_count_24h={@event_count_24h}
        />

        <div
          data-agents-live-indicator
          style={[
            "display: flex; align-items: center; gap: 6px;",
            "padding: 6px 24px;",
            "font-size: 11px;",
            "color: var(--ink-3);",
            "border-bottom: 1px solid var(--line);"
          ]}
        >
          <span
            aria-hidden="true"
            style={[
              "width: 7px; height: 7px; border-radius: 50%;",
              "background: var(--st-done);",
              "animation: sp-pulse 1.2s ease-in-out infinite;"
            ]}
          />
          <span style="font-weight: 500; color: var(--ink-2);">{gettext("live")}</span>
          <span>·</span>
          <span>{live_indicator_label(@connected_count)}</span>
        </div>

        <AgentsHeader.pm_trends
          throughput_and_success={@throughput_and_success}
          throughput_trends={@throughput_trends}
        />

        <div class="flex-1 min-h-0 flex flex-col md:flex-row">
          <aside
            data-agents-roster
            class="w-full md:w-[380px] md:flex-shrink-0 max-h-[40vh] md:max-h-none overflow-y-auto"
            style={[
              "padding: 16px;",
              "border-right: 1px solid var(--line);",
              "background: var(--surface-2);",
              "display: flex; flex-direction: column; gap: 8px;"
            ]}
          >
            <p
              :if={@agents == []}
              data-agents-roster-empty
              style={[
                "margin: 0; padding: 16px; text-align: center;",
                "font-size: 12px; font-style: italic;",
                "color: var(--ink-3);"
              ]}
            >
              {gettext("No agents have activity yet.")}
            </p>
            <AgentRosterCard.card
              :for={agent <- @agents}
              agent={agent}
              on_select="select_agent"
              selected?={agent.name == @selected_agent}
            />
          </aside>

          <div class="flex-1 min-w-0 min-h-0 flex flex-col" style="padding: 16px;">
            <div
              :if={@selected_agent}
              data-agent-filter-indicator
              data-selected-agent={@selected_agent}
              style={[
                "display: inline-flex; align-items: center; gap: 8px;",
                "align-self: flex-start;",
                "margin-bottom: 12px; padding: 4px 4px 4px 12px;",
                "background: var(--stride-violet-soft);",
                "color: var(--stride-violet);",
                "border-radius: 999px;",
                "font-size: 12px; font-weight: 500;"
              ]}
            >
              <span>{gettext("Filtering by %{agent}", agent: @selected_agent)}</span>
              <button
                type="button"
                phx-click="clear_agent_filter"
                data-clear-agent-filter
                class="focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
                style={[
                  "display: inline-flex; align-items: center; gap: 4px;",
                  "padding: 2px 9px;",
                  "border: 1px solid var(--stride-violet); border-radius: 999px;",
                  "background: transparent; color: var(--stride-violet);",
                  "cursor: pointer; font-size: 11px; font-weight: 600; line-height: 1.4;"
                ]}
              >
                <span aria-hidden="true" style="display: inline-flex;">
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </span>
                <span>{gettext("Clear")}</span>
              </button>
            </div>

            <AgentActivityFeed.feed
              events={@events}
              filter={@filter}
              on_filter_change="filter_events"
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_agents_data(socket) do
    scope = socket.assigns.current_scope
    events = Agents.recent_activity(scope: scope, limit: @recent_activity_limit)

    assign(socket, %{
      agents: Agents.list_agents(scope: scope),
      all_events: events,
      events: apply_filters(events, socket.assigns.filter, socket.assigns.selected_agent),
      stats: Agents.header_stats(scope: scope),
      fleet_health: Agents.fleet_health(scope: scope),
      throughput_and_success: Agents.throughput_and_success(scope: scope),
      throughput_trends: Agents.throughput_trends(scope: scope),
      event_count_24h: count_events_within_24h(events)
    })
  end

  defp maybe_schedule_refresh(%{assigns: %{refresh_scheduled?: true}} = socket), do: socket

  defp maybe_schedule_refresh(socket) do
    Process.send_after(self(), :refresh_agents_data, @refresh_debounce_ms)
    assign(socket, :refresh_scheduled?, true)
  end

  defp connected_count(socket) do
    if connected?(socket), do: AgentsPresence.count(), else: 0
  end

  defp live_indicator_label(count) do
    ngettext("%{count} connected", "%{count} connected", count, count: count)
  end

  defp parse_filter("all"), do: :all
  defp parse_filter("claims"), do: :claims
  defp parse_filter("reviewed"), do: :reviewed
  defp parse_filter("completions"), do: :completions
  defp parse_filter(_), do: :all

  defp filter_events(events, :all), do: events
  defp filter_events(events, :claims), do: Enum.filter(events, &(&1.kind == :claim))
  defp filter_events(events, :reviewed), do: Enum.filter(events, &(&1.kind == :review))
  defp filter_events(events, :completions), do: Enum.filter(events, &(&1.kind == :complete))

  # Composes the kind filter with the optional agent filter. The kind filter
  # always runs first; when an agent is selected, only events whose actor
  # matches that agent survive. A nil selection leaves the kind-filtered list
  # untouched.
  defp apply_filters(events, kind_filter, nil), do: filter_events(events, kind_filter)

  defp apply_filters(events, kind_filter, selected_agent) do
    events
    |> filter_events(kind_filter)
    |> Enum.filter(&(&1.actor == selected_agent))
  end

  # Toggling the currently-selected agent clears the selection; any other
  # agent name replaces it.
  defp toggle_agent(selected_agent, selected_agent), do: nil
  defp toggle_agent(_current, name), do: name

  defp count_events_within_24h(events) do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_window_hours, :hour)

    Enum.count(events, fn
      %{at: %DateTime{} = at} -> DateTime.compare(at, cutoff) != :lt
      _ -> false
    end)
  end
end
