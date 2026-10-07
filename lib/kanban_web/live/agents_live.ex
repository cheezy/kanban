defmodule KanbanWeb.AgentsLive do
  @moduledoc """
  Workspace-level Agents view at `/agents`.

  Composes `KanbanWeb.AgentsHeader`, `KanbanWeb.AgentRosterCard`, and
  `KanbanWeb.AgentActivityFeed` into a two-column page that surfaces
  every AI agent active across the user's workspace. Heavy logic lives
  in `Kanban.Agents`; this LiveView only binds the context output to the
  presentational components, handles filter-tab clicks, and reacts to
  real-time `{:agent_event, _}` broadcasts on the board-scoped
  `"agents:\#{board_id}"` PubSub topics.

  The viewer subscribes to `"agents:\#{id}"` for every board they can access, so
  a task change only redrives this load for boards in the viewer's scope — a
  task change on an inaccessible board never triggers a reload (D125). Presence
  tracking stays on the shared `"agents"` topic and powers the "live · N
  connected" indicator.

  Re-derivation is debounced (`@refresh_debounce_ms`) so a burst of
  events does not redrive the full Agents queries on every message. A DB
  timeout or missing bridge on the load path degrades gracefully (logs, keeps
  last-good/placeholder data) rather than crashing the LiveView (D125).

  To stay under the module-size guideline the LiveView keeps only its
  callbacks and the page shell; the rest lives in focused modules under
  `KanbanWeb.AgentsLive.*`: `DataLoader` (the board-scoped load and every
  derived assign), `Filters` (payload parsing and the kind/agent event filter),
  `Interventions` (Reassign/Reprioritize/Undo logic), and the
  `Components.Roster`, `Components.LiveIndicator` and
  `Components.InterventionDialogs` function components.
  """
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks
  alias KanbanWeb.AgentActivityFeed
  alias KanbanWeb.AgentDetailPanel
  alias KanbanWeb.AgentsHeader
  alias KanbanWeb.AgentsLive.Components.InterventionDialogs
  alias KanbanWeb.AgentsLive.Components.LiveIndicator
  alias KanbanWeb.AgentsLive.Components.Roster
  alias KanbanWeb.AgentsLive.DataLoader
  alias KanbanWeb.AgentsLive.Filters
  alias KanbanWeb.AgentsLive.Interventions
  alias KanbanWeb.AgentsPresence
  alias KanbanWeb.DeliveryHealthBand
  alias KanbanWeb.TargetRiskExplainer

  @default_filter :all
  @refresh_debounce_ms 250
  @presence_topic "agents"

  # The detail-panel category keys that can be collapsed/expanded. Used both to
  # seed the all-expanded default and to validate an incoming toggle payload so
  # the event can only flip a known section's view state (never an arbitrary
  # key). Keep in sync with the `section=` values passed in AgentDetailPanel.
  @detail_sections ~w(current claims failures activity)

  @impl true
  def mount(_params, _session, socket) do
    # The heavy board-scoped reads run ONLY on the connected mount. The static
    # (disconnected) first render seeds the same zero-DB empty state an
    # agent-less workspace shows, so first paint is instant; the connected mount
    # then loads the real data and replaces it. This halves the per-load query
    # volume the old unconditional load incurred by running on BOTH the
    # disconnected and connected mount (D120). track_viewer/1 stays before
    # initial_assigns/1 so connected_count/1 still counts the current viewer.
    if connected?(socket) do
      # Presence stays on the shared "agents" topic (powers the connected count);
      # track_viewer/1 runs before initial_assigns/1 so connected_count/1 counts
      # the current viewer. Agent-event reloads are scoped to the viewer's
      # accessible boards (D125): subscribe per board AFTER initial_assigns/1
      # seeds socket.assigns.boards.
      Phoenix.PubSub.subscribe(Kanban.PubSub, @presence_topic)
      AgentsPresence.track_viewer(socket)
      socket = assign(socket, initial_assigns(socket))
      subscribe_to_board_agent_events(socket.assigns.boards)

      # Seed the empty placeholder baseline first so a DB failure on the very
      # first connected load has last-good data to fall back to (load_agents_data
      # degrades gracefully instead of leaving the data assigns unset).
      {:ok, socket |> DataLoader.assign_placeholder_data() |> DataLoader.load_agents_data()}
    else
      {:ok, socket |> assign(initial_assigns(socket)) |> DataLoader.assign_placeholder_data()}
    end
  end

  # Subscribe to the per-board agent-event topic for every board the viewer can
  # access. A task change broadcasts to "agents:#{board_id}", so this scopes
  # reloads to the viewer's boards — a change on a board the viewer is not a
  # member of never reaches them (D125). Before D125 every viewer subscribed to a
  # single global "agents" topic and reloaded on every task change across ALL
  # boards, producing the cross-board reload storm.
  defp subscribe_to_board_agent_events(boards) do
    Enum.each(boards, fn board ->
      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{board.id}")
    end)
  end

  # The socket assigns that do not depend on the heavy task fetch. Seeded on both
  # the disconnected and connected mount so the first render has every
  # selector/dialog assign it needs before (or without) the data load.
  defp initial_assigns(socket) do
    %{
      filter: @default_filter,
      selected_agent: nil,
      refresh_scheduled?: false,
      dormant_expanded?: false,
      expanded_detail_sections: MapSet.new(@detail_sections),
      timezone: KanbanWeb.Timezone.browser_timezone(socket),
      connected_count: connected_count(socket),
      board_id: nil,
      time_range: :all_time,
      reassign: nil,
      reprioritize: nil,
      undo: nil,
      boards: Boards.list_boards(socket.assigns.current_scope.user)
    }
  end

  @impl true
  def handle_event("filter_events", %{"filter" => raw_filter}, socket) do
    filter = Filters.parse_filter(raw_filter)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(
       :events,
       Filters.apply_filters(socket.assigns.all_events, filter, socket.assigns.selected_agent)
     )}
  end

  @impl true
  def handle_event("filter_change", params, socket) do
    {:noreply,
     socket
     |> assign(:board_id, Filters.parse_board_id(params["board_id"]))
     |> assign(:time_range, Filters.parse_time_range(params["time_range"]))
     |> DataLoader.load_agents_data()}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => name, "owner" => owner_key}, socket) do
    identity = {name, owner_key}

    # Validate the click payload against the currently-rendered roster before
    # using it — never trust a raw phx-value as an identity (security).
    if known_agent_identity?(socket, identity) do
      selected = Filters.toggle_agent(socket.assigns.selected_agent, identity)

      {:noreply,
       socket
       |> assign(:selected_agent, selected)
       |> assign(
         :agent_detail,
         DataLoader.selected_agent_detail(socket.assigns.current_scope, selected)
       )
       |> assign(
         :events,
         Filters.apply_filters(socket.assigns.all_events, socket.assigns.filter, selected)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_agent_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent, nil)
     |> assign(:agent_detail, nil)
     |> assign(
       :events,
       Filters.apply_filters(socket.assigns.all_events, socket.assigns.filter, nil)
     )}
  end

  @impl true
  def handle_event("toggle_dormant", _params, socket) do
    {:noreply, assign(socket, :dormant_expanded?, !socket.assigns.dormant_expanded?)}
  end

  @impl true
  def handle_event("toggle_detail_section", %{"section" => section}, socket)
      when section in @detail_sections do
    {:noreply,
     assign(
       socket,
       :expanded_detail_sections,
       Filters.toggle_member(socket.assigns.expanded_detail_sections, section)
     )}
  end

  # Ignore toggles for any key that is not a known detail-panel section: the
  # payload is client-supplied, so an unrecognized section must not mutate
  # state (security).
  @impl true
  def handle_event("toggle_detail_section", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_reassign", %{"goal-id" => goal_id}, socket) do
    scope = socket.assigns.current_scope

    # Resolve the id against the goals actually on screen (client-supplied
    # payload); reassign_preview/2 then re-authorizes via can_intervene?/2, so a
    # forged goal-id or a non-owner is refused server-side, never trusting the
    # hidden control.
    with %Kanban.Tasks.Task{} = goal <- Interventions.find_stalled_goal(socket, goal_id),
         {:ok, preview} <- Tasks.reassign_preview(scope, goal) do
      {:noreply, assign(socket, :reassign, Interventions.build_reassign_state(preview))}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not allowed to reassign this goal."))}
    end
  end

  @impl true
  def handle_event("cancel_reassign", _params, socket) do
    {:noreply, assign(socket, :reassign, nil)}
  end

  @impl true
  def handle_event(
        "confirm_reassign",
        %{"assigned_to_id" => raw_id},
        %{
          assigns: %{reassign: %{goal: goal}}
        } = socket
      ) do
    case Interventions.parse_assignee_id(raw_id) do
      :none ->
        {:noreply, put_flash(socket, :error, gettext("Choose a new owner first."))}

      assigned_to_id ->
        Interventions.commit_reassign(socket, goal, assigned_to_id)
    end
  end

  # No dialog is open (stale/forged submit) — ignore.
  @impl true
  def handle_event("confirm_reassign", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_reprioritize", %{"goal-id" => goal_id}, socket) do
    scope = socket.assigns.current_scope

    # Resolve the id against the goals actually on screen (client-supplied
    # payload); reprioritize_preview/2 then re-authorizes via can_intervene?/2, so
    # a forged goal-id or a non-owner is refused server-side, never trusting the
    # hidden control.
    with %Kanban.Tasks.Task{} = goal <- Interventions.find_stalled_goal(socket, goal_id),
         {:ok, preview} <- Tasks.reprioritize_preview(scope, goal) do
      {:noreply, assign(socket, :reprioritize, Interventions.build_reprioritize_state(preview))}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not allowed to reprioritize this goal."))}
    end
  end

  @impl true
  def handle_event("cancel_reprioritize", _params, socket) do
    {:noreply, assign(socket, :reprioritize, nil)}
  end

  @impl true
  def handle_event(
        "confirm_reprioritize",
        %{"priority" => raw_priority},
        %{
          assigns: %{reprioritize: %{goal: goal}}
        } = socket
      ) do
    case Interventions.parse_priority(raw_priority) do
      :none ->
        {:noreply, put_flash(socket, :error, gettext("Choose a new priority first."))}

      priority ->
        Interventions.commit_reprioritize(socket, goal, priority)
    end
  end

  # No dialog is open (stale/forged submit) — ignore.
  @impl true
  def handle_event("confirm_reprioritize", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "undo_intervention",
        _params,
        %{assigns: %{undo: %{} = undo}} = socket
      ) do
    {:noreply, Interventions.commit_undo(socket, undo)}
  end

  # The window elapsed (snapshot cleared) or a forged click with no snapshot — ignore.
  @impl true
  def handle_event("undo_intervention", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:agent_event, _payload}, socket) do
    {:noreply, maybe_schedule_refresh(socket)}
  end

  # Clear the Undo affordance when its bounded window elapses. The token guards
  # against a stale timer from an earlier intervention clearing a newer snapshot.
  @impl true
  def handle_info({:clear_undo, token}, %{assigns: %{undo: %{token: token}}} = socket) do
    {:noreply, assign(socket, :undo, nil)}
  end

  @impl true
  def handle_info({:clear_undo, _token}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh_agents_data, socket) do
    {:noreply,
     socket
     |> assign(:refresh_scheduled?, false)
     |> DataLoader.load_agents_data()}
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
        class="stride-screen stride-pin-when-tall"
        style="display: flex; flex-direction: column; min-height: 0;"
      >
        <AgentsHeader.header
          stats={@stats}
          fleet_health={@fleet_health}
          event_count_24h={@event_count_24h}
          boards={@boards}
          board_id={@board_id}
          time_range={@time_range}
        />

        <div data-agents-delivery-tier>
          <DeliveryHealthBand.delivery_health_band targets={@delivery_rollup.targets} />

          <TargetRiskExplainer.target_risk_explainer
            targets={@delivery_rollup.targets}
            reassignable_goal_ids={@reassignable_goal_ids}
            on_reassign="open_reassign"
            on_reprioritize="open_reprioritize"
          />
        </div>

        <InterventionDialogs.reassign_dialog reassign={@reassign} />
        <InterventionDialogs.reprioritize_dialog reprioritize={@reprioritize} />
        <InterventionDialogs.undo_affordance undo={@undo} />

        <div data-agents-second-tier class="flex-1 min-h-0 flex flex-col">
          <LiveIndicator.live_indicator connected_count={@connected_count} />

          <AgentsHeader.pm_trends
            throughput_and_success={@throughput_and_success}
            throughput_trends={@throughput_trends}
          />

          <div class="flex-1 min-h-0 flex flex-col md:flex-row">
            <Roster.roster
              agents={@agents}
              dormant_agents={@dormant_agents}
              dormant_expanded?={@dormant_expanded?}
              selected_agent={@selected_agent}
              agent_targets={@delivery_rollup.agent_targets}
            />

            <div class="flex-1 min-w-0 min-h-0 flex flex-col" style="padding: 16px;">
              <Roster.selected_agent_filter selected_agent={@selected_agent} />

              <div :if={@agent_detail} data-agent-detail style="margin-bottom: 16px;">
                <AgentDetailPanel.panel
                  detail={@agent_detail}
                  expanded_sections={@expanded_detail_sections}
                  on_toggle="toggle_detail_section"
                />
              </div>

              <AgentActivityFeed.feed
                events={@events}
                filter={@filter}
                timezone={@timezone}
                tethers={feed_tethers(@delivery_rollup.agent_targets)}
                on_filter_change="filter_events"
              />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The activity-feed tether map: each agent identity mapped to a goal-id-indexed
  # map of the annotations that agent advances. A feed row then resolves the goal
  # of ITS OWN task (via the event's parent_id) instead of a single agent-level
  # pick, so an agent working across several goals shows each row under the goal
  # that row's task actually belongs to. Agents advancing no target are dropped,
  # so their rows render untethered exactly as before. Keyed by {name, owner_key}
  # so the feed resolves a row's actor identically to the roster.
  defp feed_tethers(agent_targets) do
    agent_targets
    |> Enum.flat_map(fn
      {_identity, []} -> []
      {identity, entries} -> [{identity, Map.new(entries, &{&1.goal.id, &1})}]
    end)
    |> Map.new()
  end

  # Whether the {name, owner_key} identity is one of the agents currently in the
  # rendered roster (live or dormant). Guards select_agent against a forged or
  # stale phx-value before it becomes a selection/filter key.
  defp known_agent_identity?(socket, {name, owner_key}) do
    Enum.any?(
      socket.assigns.agents ++ socket.assigns.dormant_agents,
      &(&1.name == name and &1.owner_key == owner_key)
    )
  end

  defp maybe_schedule_refresh(%{assigns: %{refresh_scheduled?: true}} = socket), do: socket

  defp maybe_schedule_refresh(socket) do
    Process.send_after(self(), :refresh_agents_data, @refresh_debounce_ms)
    assign(socket, :refresh_scheduled?, true)
  end

  defp connected_count(socket) do
    if connected?(socket), do: AgentsPresence.count(), else: 0
  end
end
