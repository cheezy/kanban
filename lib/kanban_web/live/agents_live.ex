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
     |> assign(:events, filter_events(socket.assigns.all_events, filter))}
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
        <AgentsHeader.header stats={@stats} event_count_24h={@event_count_24h} />

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

        <div style="display: flex; flex: 1; min-height: 0;">
          <aside
            data-agents-roster
            style={[
              "width: 380px; flex-shrink: 0;",
              "padding: 16px;",
              "overflow-y: auto;",
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
            <AgentRosterCard.card :for={agent <- @agents} agent={agent} />
          </aside>

          <div style={[
            "flex: 1; min-width: 0;",
            "padding: 16px;",
            "display: flex; flex-direction: column;",
            "min-height: 0;"
          ]}>
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

    agents = Agents.list_agents(scope: scope)
    events = Agents.recent_activity(scope: scope, limit: @recent_activity_limit)
    stats = Agents.header_stats(scope: scope)

    socket
    |> assign(:agents, agents)
    |> assign(:all_events, events)
    |> assign(:events, filter_events(events, socket.assigns.filter))
    |> assign(:stats, stats)
    |> assign(:event_count_24h, count_events_within_24h(events))
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
  defp parse_filter("hooks"), do: :hooks
  defp parse_filter("completions"), do: :completions
  defp parse_filter(_), do: :all

  defp filter_events(events, :all), do: events
  defp filter_events(events, :claims), do: Enum.filter(events, &(&1.kind == :claim))
  defp filter_events(events, :hooks), do: Enum.filter(events, &(&1.kind == :hook))
  defp filter_events(events, :completions), do: Enum.filter(events, &(&1.kind == :complete))

  defp count_events_within_24h(events) do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_window_hours, :hour)

    Enum.count(events, fn
      %{at: %DateTime{} = at} -> DateTime.compare(at, cutoff) != :lt
      _ -> false
    end)
  end
end
