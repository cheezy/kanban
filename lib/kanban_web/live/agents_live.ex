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
  alias Kanban.Boards
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Tasks
  alias KanbanWeb.AgentActivityFeed
  alias KanbanWeb.AgentDetailPanel
  alias KanbanWeb.AgentRosterCard
  alias KanbanWeb.AgentsHeader
  alias KanbanWeb.AgentsPresence
  alias KanbanWeb.DeliveryHealthBand
  alias KanbanWeb.TargetRiskExplainer

  @default_filter :all
  @recent_activity_limit 200
  @event_window_hours 24
  # Fixed trailing window (days) for the selector-independent throughput cards.
  # Must cover the widest card comparison: prev_30d counts the trailing 60 days
  # (2 x 30), so the window has to be at least 60.
  @throughput_window_days 60
  @refresh_debounce_ms 250
  @presence_topic "agents"

  # How long the Undo affordance for a reassign/reprioritize stays live before it
  # is cleared. Read at runtime (not a compile-time attr) so tests can shorten the
  # window; a bounded window keeps a stale prior-state snapshot from being
  # replayed indefinitely.
  @default_undo_window_ms 8_000

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
      Phoenix.PubSub.subscribe(Kanban.PubSub, @presence_topic)
      AgentsPresence.track_viewer(socket)

      {:ok, socket |> assign(initial_assigns(socket)) |> load_agents_data()}
    else
      {:ok, socket |> assign(initial_assigns(socket)) |> assign_placeholder_data()}
    end
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

  # Zero-DB stand-in for the heavy load path, used on the disconnected mount so
  # the static first render is instant. Runs the same derivation helpers as the
  # connected load on empty inputs, so every assign key the connected path
  # produces exists here too (no nil-crash in the template) and the shell renders
  # the workspace empty state, replaced on connect by the real load.
  defp assign_placeholder_data(socket) do
    assign_agents_data(socket, [], [], empty_delivery_rollup())
  end

  # The delivery rollup for a workspace with no accessible targets — the exact
  # shape DeliveryRollup.build/2 returns in that case (see its @type t()), used
  # by the disconnected placeholder without a DB round trip.
  defp empty_delivery_rollup, do: %{targets: [], unrolled_agents: [], agent_targets: %{}}

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
  def handle_event("filter_change", params, socket) do
    {:noreply,
     socket
     |> assign(:board_id, parse_board_id(params["board_id"]))
     |> assign(:time_range, parse_time_range(params["time_range"]))
     |> load_agents_data()}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => name, "owner" => owner_key}, socket) do
    identity = {name, owner_key}

    # Validate the click payload against the currently-rendered roster before
    # using it — never trust a raw phx-value as an identity (security).
    if known_agent_identity?(socket, identity) do
      selected = toggle_agent(socket.assigns.selected_agent, identity)

      {:noreply,
       socket
       |> assign(:selected_agent, selected)
       |> assign(:agent_detail, selected_agent_detail(socket.assigns.current_scope, selected))
       |> assign(
         :events,
         apply_filters(socket.assigns.all_events, socket.assigns.filter, selected)
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
     |> assign(:events, apply_filters(socket.assigns.all_events, socket.assigns.filter, nil))}
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
       toggle_member(socket.assigns.expanded_detail_sections, section)
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
    with %Kanban.Tasks.Task{} = goal <- find_stalled_goal(socket, goal_id),
         {:ok, preview} <- Tasks.reassign_preview(scope, goal) do
      {:noreply, assign(socket, :reassign, build_reassign_state(preview))}
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
    case parse_assignee_id(raw_id) do
      :none ->
        {:noreply, put_flash(socket, :error, gettext("Choose a new owner first."))}

      assigned_to_id ->
        commit_reassign(socket, goal, assigned_to_id)
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
    with %Kanban.Tasks.Task{} = goal <- find_stalled_goal(socket, goal_id),
         {:ok, preview} <- Tasks.reprioritize_preview(scope, goal) do
      {:noreply, assign(socket, :reprioritize, build_reprioritize_state(preview))}
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
    case parse_priority(raw_priority) do
      :none ->
        {:noreply, put_flash(socket, :error, gettext("Choose a new priority first."))}

      priority ->
        commit_reprioritize(socket, goal, priority)
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
    {:noreply, commit_undo(socket, undo)}
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
        class="stride-screen md:h-full"
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

        <.reassign_dialog reassign={@reassign} />
        <.reprioritize_dialog reprioritize={@reprioritize} />
        <.undo_affordance undo={@undo} />

        <div data-agents-second-tier class="flex-1 min-h-0 flex flex-col">
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
              class="w-full md:w-[380px] md:flex-shrink-0 md:overflow-y-auto"
              style={[
                "padding: 16px;",
                "border-right: 1px solid var(--line);",
                "background: var(--surface-2);",
                "display: flex; flex-direction: column; gap: 8px;"
              ]}
            >
              <p
                :if={@agents == [] and @dormant_agents == []}
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
                annotation={primary_annotation(@delivery_rollup.agent_targets, agent)}
                on_select="select_agent"
                selected?={{agent.name, agent.owner_key} == @selected_agent}
              />

              <div
                :if={@dormant_agents != []}
                data-agents-dormant-group
                style={[
                  "margin-top: 8px; padding-top: 8px;",
                  "border-top: 1px solid var(--line);",
                  "display: flex; flex-direction: column; gap: 8px;"
                ]}
              >
                <button
                  type="button"
                  phx-click="toggle_dormant"
                  data-agents-dormant-toggle
                  aria-expanded={to_string(@dormant_expanded?)}
                  class="min-h-11 md:min-h-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
                  style={[
                    "display: flex; align-items: center; gap: 6px;",
                    "width: 100%; padding: 4px 2px;",
                    "background: transparent; border: 0; cursor: pointer;",
                    "font-size: 11px; font-weight: 600;",
                    "text-transform: uppercase; letter-spacing: 0.06em;",
                    "color: var(--ink-3);"
                  ]}
                >
                  <.icon
                    name={if @dormant_expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
                    class="w-3 h-3"
                  />
                  <span>{gettext("Dormant (%{count})", count: length(@dormant_agents))}</span>
                </button>

                <div
                  :if={@dormant_expanded?}
                  style="display: flex; flex-direction: column; gap: 8px;"
                >
                  <div :for={agent <- @dormant_agents} data-agent-dormant-card>
                    <AgentRosterCard.card
                      agent={agent}
                      annotation={primary_annotation(@delivery_rollup.agent_targets, agent)}
                      on_select="select_agent"
                      selected?={{agent.name, agent.owner_key} == @selected_agent}
                    />
                    <p style={[
                      "margin: 2px 0 0; padding-left: 2px;",
                      "font-size: 10px; color: var(--ink-3);"
                    ]}>
                      {format_last_seen(agent.last_active_at)}
                    </p>
                  </div>
                </div>
              </div>
            </aside>

            <div class="flex-1 min-w-0 min-h-0 flex flex-col" style="padding: 16px;">
              <div
                :if={@selected_agent}
                data-agent-filter-indicator
                data-selected-agent={selected_agent_name(@selected_agent)}
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
                <span>{gettext("Filtering by %{agent}", agent: selected_agent_name(@selected_agent))}</span>
                <button
                  type="button"
                  phx-click="clear_agent_filter"
                  data-clear-agent-filter
                  class="min-h-11 md:min-h-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
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

  # The board select submits "" for "All Boards" and a numeric id otherwise; an
  # unparseable value falls back to nil (all boards) rather than crashing.
  defp parse_board_id(id) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {board_id, ""} -> board_id
      _ -> nil
    end
  end

  defp parse_board_id(_id), do: nil

  # Explicit allow-list mapping (no String.to_atom on user input); anything
  # unrecognized falls back to :all_time, the unfiltered default.
  defp parse_time_range("today"), do: :today
  defp parse_time_range("last_7_days"), do: :last_7_days
  defp parse_time_range("last_30_days"), do: :last_30_days
  defp parse_time_range("last_90_days"), do: :last_90_days
  defp parse_time_range(_range), do: :all_time

  defp load_agents_data(socket) do
    scope = socket.assigns.current_scope
    {tasks, throughput_tasks} = fetch_task_sets(socket, scope)
    # Build the delivery rollup once (board-scoped, no LiveView Ecto) and reuse
    # it for the delivery-health band, the at-risk explainer, and the roster's
    # target annotation + risk-first ordering (W1589).
    delivery_rollup = DeliveryRollup.build(scope, timezone: socket.assigns.timezone)

    assign_agents_data(socket, tasks, throughput_tasks, delivery_rollup)
  end

  # Derives every task-dependent assign from an already-fetched task set + rollup
  # and merges them onto the socket. Shared by the connected load
  # (load_agents_data/1, real data) and the disconnected placeholder
  # (assign_placeholder_data/1, empty data) so both paths emit an identical set
  # of assign keys.
  defp assign_agents_data(socket, tasks, throughput_tasks, delivery_rollup) do
    timezone = socket.assigns.timezone
    agents = Agents.list_agents_from(tasks, timezone)
    events = Agents.recent_activity_from(tasks, @recent_activity_limit)

    metrics =
      metric_assigns(tasks, throughput_tasks, agents, timezone, socket.assigns.time_range)

    assigns =
      socket
      |> base_assigns(tasks, agents, events, delivery_rollup)
      |> Map.merge(metrics)
      |> Map.put(:delivery_rollup, delivery_rollup)

    assign(socket, assigns)
  end

  # The two board-scoped task fetches every derivation shares. The first is the
  # selector-filtered set that drives the roster, events, and header stats
  # (fetched ONCE — before W1242 each derivation re-ran the unbounded fetch,
  # ~24-28 queries per render). The second is a fixed @throughput_window_days
  # set, independent of the page time-range selector, so a "30D" throughput card
  # always means 30 days; it stays bounded so it never reintroduces the old
  # unbounded per-render fetch.
  defp fetch_task_sets(socket, scope) do
    tasks =
      Agents.fetch_tasks(
        scope: scope,
        board_id: socket.assigns.board_id,
        time_range: socket.assigns.time_range,
        timezone: socket.assigns.timezone
      )

    throughput_tasks =
      Agents.fetch_tasks(
        scope: scope,
        board_id: socket.assigns.board_id,
        window_days: @throughput_window_days,
        timezone: socket.assigns.timezone
      )

    {tasks, throughput_tasks}
  end

  # The roster, event, and drill-down assigns derived from the shared task fetch.
  defp base_assigns(socket, tasks, agents, events, delivery_rollup) do
    # Dormant agents are split out of the main roster into a collapsible group;
    # the dormant flag is derived in the context (W1222), not recomputed here.
    {live_agents, dormant_agents} = Enum.split_with(agents, &(not &1.dormant))

    %{
      # Order the live roster risk-first: agents advancing a goal inside an
      # at-risk target float to the top, everything else keeps its recency order.
      agents: order_risk_first(live_agents, delivery_rollup.agent_targets),
      dormant_agents: dormant_agents,
      all_events: events,
      events: apply_filters(events, socket.assigns.filter, socket.assigns.selected_agent),
      # Recompute the open agent's drill-down so it refreshes on the same
      # PubSub debounce as the rest of the view; nil when nothing is selected.
      agent_detail: agent_detail_for(tasks, socket.assigns.selected_agent),
      event_count_24h: count_events_within_24h(events),
      # The subset of on-screen stalled goals the current user may reassign, so
      # the Reassign control renders only where can_intervene?/2 allows.
      reassignable_goal_ids: reassignable_goal_ids(socket.assigns.current_scope, delivery_rollup)
    }
  end

  # Ids of the stalled goals currently shown in the at-risk explainer that the
  # scoped user is authorized to reassign. Computed once per rebuild so the
  # template membership test is a cheap MapSet lookup, and the write path stays
  # the single source of truth (each id was cleared by can_intervene?/2).
  defp reassignable_goal_ids(scope, delivery_rollup) do
    for target <- delivery_rollup.targets,
        detail <- target.stalled_details,
        Tasks.can_intervene?(scope, detail.goal),
        into: MapSet.new(),
        do: detail.goal.id
  end

  defp commit_reassign(socket, goal, assigned_to_id) do
    scope = socket.assigns.current_scope

    case Tasks.reassign_goal_unstarted(scope, goal, assigned_to_id) do
      {:ok, result} -> {:noreply, reassign_succeeded(socket, goal, result)}
      {:error, reason} -> {:noreply, reassign_failed(socket, reason)}
    end
  end

  # The pre-write goal + preview children still carry each task's original owner,
  # so they seed the per-task undo snapshot (matched by id against the moved set).
  defp reassign_succeeded(socket, goal, %{moved: moved, skipped: skipped}) do
    restorations =
      intervention_restorations([goal | socket.assigns.reassign.children], moved, :assigned_to_id)

    socket
    |> assign(:reassign, nil)
    |> put_flash(:info, reassign_flash(moved, skipped))
    |> arm_undo(:reassign, goal, restorations)
    |> load_agents_data()
  end

  defp reassign_failed(socket, :unauthorized) do
    socket
    |> assign(:reassign, nil)
    |> put_flash(:error, gettext("You are not allowed to reassign this goal."))
  end

  defp reassign_failed(socket, :assignee_not_on_board) do
    put_flash(socket, :error, gettext("That user is not a member of this board."))
  end

  defp reassign_failed(socket, _changeset) do
    put_flash(socket, :error, gettext("Could not reassign the goal. Please try again."))
  end

  # Resolve a client-supplied goal id against the stalled goals actually on
  # screen, so a forged payload can only ever name a goal the page already
  # shows (authorization is still re-checked by can_intervene?/2 afterward).
  defp find_stalled_goal(socket, goal_id) do
    case Integer.parse(goal_id) do
      {id, ""} ->
        socket.assigns.delivery_rollup.targets
        |> Enum.flat_map(& &1.stalled_details)
        |> Enum.map(& &1.goal)
        |> Enum.find(&(&1.id == id))

      _ ->
        nil
    end
  end

  defp build_reassign_state(%{goal: goal, children: children, members: members}) do
    %{goal: goal, children: children, member_options: member_options(members)}
  end

  defp member_options(members) do
    Enum.map(members, fn %{user: user} -> {user_label(user), user.id} end)
  end

  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}), do: email

  defp parse_assignee_id(""), do: :none

  defp parse_assignee_id(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> id
      _ -> :none
    end
  end

  defp reassign_flash(moved, []) do
    ngettext("Reassigned %{count} task.", "Reassigned %{count} tasks.", length(moved))
  end

  defp reassign_flash(moved, skipped) do
    ids = Enum.map_join(skipped, ", ", & &1.identifier)

    moved_msg = ngettext("Reassigned %{count} task.", "Reassigned %{count} tasks.", length(moved))

    skipped_msg =
      ngettext(
        "Skipped %{count} task already claimed: %{ids}.",
        "Skipped %{count} tasks already claimed: %{ids}.",
        length(skipped),
        ids: ids
      )

    moved_msg <> " " <> skipped_msg
  end

  defp commit_reprioritize(socket, goal, priority) do
    scope = socket.assigns.current_scope

    case Tasks.reprioritize_goal_unstarted(scope, goal, priority) do
      {:ok, result} -> {:noreply, reprioritize_succeeded(socket, goal, result)}
      {:error, reason} -> {:noreply, reprioritize_failed(socket, reason)}
    end
  end

  # The pre-write goal + preview children still carry each task's original
  # priority, so they seed the per-task undo snapshot (matched by id to the moved
  # set).
  defp reprioritize_succeeded(socket, goal, %{moved: moved, skipped: skipped}) do
    restorations =
      intervention_restorations([goal | socket.assigns.reprioritize.children], moved, :priority)

    socket
    |> assign(:reprioritize, nil)
    |> put_flash(:info, reprioritize_flash(moved, skipped))
    |> arm_undo(:reprioritize, goal, restorations)
    |> load_agents_data()
  end

  defp reprioritize_failed(socket, :unauthorized) do
    socket
    |> assign(:reprioritize, nil)
    |> put_flash(:error, gettext("You are not allowed to reprioritize this goal."))
  end

  defp reprioritize_failed(socket, :invalid_priority) do
    put_flash(socket, :error, gettext("That is not a valid priority."))
  end

  defp reprioritize_failed(socket, _changeset) do
    put_flash(socket, :error, gettext("Could not reprioritize the goal. Please try again."))
  end

  defp build_reprioritize_state(%{goal: goal, children: children}) do
    %{goal: goal, children: children}
  end

  # The priority selector is constrained to these four values; the context op
  # re-validates the submitted string, so no atom is ever built from user input.
  defp parse_priority(""), do: :none
  defp parse_priority(priority), do: priority

  defp priority_options do
    [
      {gettext("Low"), "low"},
      {gettext("Medium"), "medium"},
      {gettext("High"), "high"},
      {gettext("Critical"), "critical"}
    ]
  end

  defp reprioritize_flash(moved, []) do
    ngettext("Reprioritized %{count} task.", "Reprioritized %{count} tasks.", length(moved))
  end

  defp reprioritize_flash(moved, skipped) do
    ids = Enum.map_join(skipped, ", ", & &1.identifier)

    moved_msg =
      ngettext("Reprioritized %{count} task.", "Reprioritized %{count} tasks.", length(moved))

    skipped_msg =
      ngettext(
        "Skipped %{count} task already claimed: %{ids}.",
        "Skipped %{count} tasks already claimed: %{ids}.",
        length(skipped),
        ids: ids
      )

    moved_msg <> " " <> skipped_msg
  end

  # Builds the per-task undo snapshot from the pre-write goal + preview children
  # (which still carry each task's ORIGINAL value) matched by id against the set
  # the op actually moved, so the undo restores each task to *its own* prior
  # `field` value — not one flattened goal-level value.
  defp intervention_restorations(prior_tasks, moved, field) do
    prior_by_id = Map.new(prior_tasks, &{&1.id, Map.fetch!(&1, field)})

    Enum.map(moved, fn task ->
      %{id: task.id, identifier: task.identifier, prior: Map.get(prior_by_id, task.id)}
    end)
  end

  # Snapshots the per-task restorations (id + identifier + that task's own prior
  # value) and schedules the bounded-window clear. A fresh token per arming lets
  # the timed clear ignore snapshots superseded by a later intervention.
  defp arm_undo(socket, op, goal, restorations) do
    token = make_ref()
    Process.send_after(self(), {:clear_undo, token}, undo_window_ms())

    assign(socket, :undo, %{op: op, goal_id: goal.id, restorations: restorations, token: token})
  end

  # Reverts exactly the snapshotted moved set to each task's own prior value via
  # the set-scoped undo context op (never the goal's broader current not-started
  # set, so a task that did not move is untouched). The op re-checks
  # can_intervene?/2 and board scope and re-reads under a row lock, so a
  # now-unauthorized user or a since-claimed task is refused/skipped rather than
  # force-reverted. Anything from the moved set the op could not restore (claimed
  # since — moved out of the not-started columns, so the op never sees it) is
  # surfaced, not silently dropped.
  defp commit_undo(socket, %{op: op, goal_id: goal_id, restorations: restorations}) do
    scope = socket.assigns.current_scope
    # Re-read the goal fresh: the snapshot's struct holds the pre-intervention
    # field value, so building the revert changeset from it would be an empty
    # (no-op) change. The fresh row carries the intervention's new value, so
    # setting it back to its prior is a real update.
    goal = Tasks.get_task!(goal_id)

    case undo_op(op, scope, goal, restorations) do
      {:ok, result} -> undo_succeeded(socket, result, restorations)
      {:error, reason} -> undo_failed(socket, reason)
    end
  end

  # `restored` is what the undo op actually re-read and reverted; any task from
  # the moved snapshot missing from it was claimed since and is surfaced.
  defp undo_succeeded(socket, %{moved: restored}, restorations) do
    restored_ids = MapSet.new(restored, & &1.id)
    unrestorable = Enum.reject(restorations, &MapSet.member?(restored_ids, &1.id))

    socket
    |> assign(:undo, nil)
    |> put_flash(:info, undo_flash(restored, unrestorable))
    |> load_agents_data()
  end

  defp undo_failed(socket, reason) do
    socket
    |> assign(:undo, nil)
    |> put_flash(:error, undo_error_flash(reason))
  end

  defp undo_op(:reassign, scope, goal, restorations),
    do: Tasks.undo_reassignment(scope, goal, restorations)

  defp undo_op(:reprioritize, scope, goal, restorations),
    do: Tasks.undo_reprioritization(scope, goal, restorations)

  defp undo_flash(restored, []) do
    ngettext(
      "Undone: restored %{count} task.",
      "Undone: restored %{count} tasks.",
      length(restored)
    )
  end

  defp undo_flash(restored, unrestorable) do
    ids = Enum.map_join(unrestorable, ", ", & &1.identifier)

    restored_msg =
      ngettext(
        "Undone: restored %{count} task.",
        "Undone: restored %{count} tasks.",
        length(restored)
      )

    unrestorable_msg =
      ngettext(
        "Could not restore %{count} task claimed since: %{ids}.",
        "Could not restore %{count} tasks claimed since: %{ids}.",
        length(unrestorable),
        ids: ids
      )

    restored_msg <> " " <> unrestorable_msg
  end

  defp undo_error_flash(:unauthorized),
    do: gettext("You are no longer allowed to undo this change.")

  defp undo_error_flash(_reason), do: gettext("Could not undo the change. Please try again.")

  defp undo_window_ms, do: Application.get_env(:kanban, :undo_window_ms, @default_undo_window_ms)

  attr :undo, :map, default: nil

  # The time-boxed Undo affordance shown after a successful reassign/reprioritize.
  # Rendered only while the snapshot is live (cleared on undo or when the window
  # elapses); clicking it reverts the moved set via commit_undo/2.
  defp undo_affordance(assigns) do
    ~H"""
    <div
      :if={@undo}
      data-undo-affordance
      class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 px-4 py-2 shadow-lg"
    >
      <span class="text-sm text-base-content">{undo_prompt(@undo.op)}</span>
      <.button type="button" phx-click="undo_intervention" data-undo-trigger variant="primary">
        {gettext("Undo")}
      </.button>
    </div>
    """
  end

  defp undo_prompt(:reassign), do: gettext("Goal reassigned.")
  defp undo_prompt(:reprioritize), do: gettext("Goal reprioritized.")

  attr :reassign, :map, default: nil

  # The confirmation dialog for the goal-level Reassign action: a board-member
  # owner selector in the shared intervention_dialog/1 scaffold; confirming routes
  # through the reassign_goal_unstarted context op.
  defp reassign_dialog(assigns) do
    ~H"""
    <.intervention_dialog
      :if={@reassign}
      id="reassign-goal-modal"
      form_id="reassign-form"
      goal={@reassign.goal}
      children={@reassign.children}
      title={gettext("Reassign %{goal}", goal: @reassign.goal.identifier)}
      summary={
        ngettext(
          "This will move 1 task to the new owner:",
          "This will move %{count} tasks to the new owner:",
          length(@reassign.children) + 1
        )
      }
      cancel_event="cancel_reassign"
      submit_event="confirm_reassign"
      submit_label={gettext("Reassign")}
    >
      <.input
        type="select"
        id="reassign-assigned-to"
        name="assigned_to_id"
        value=""
        label={gettext("New owner")}
        options={@reassign.member_options}
        prompt={gettext("Choose a new owner")}
      />
    </.intervention_dialog>
    """
  end

  attr :reprioritize, :map, default: nil

  # The confirmation dialog for the goal-level Reprioritize action: a selector
  # constrained to the four allowed priorities in the shared intervention_dialog/1
  # scaffold; confirming routes through the reprioritize_goal_unstarted context op.
  defp reprioritize_dialog(assigns) do
    ~H"""
    <.intervention_dialog
      :if={@reprioritize}
      id="reprioritize-goal-modal"
      form_id="reprioritize-form"
      goal={@reprioritize.goal}
      children={@reprioritize.children}
      title={gettext("Reprioritize %{goal}", goal: @reprioritize.goal.identifier)}
      summary={
        ngettext(
          "This will change the priority of 1 task:",
          "This will change the priority of %{count} tasks:",
          length(@reprioritize.children) + 1
        )
      }
      cancel_event="cancel_reprioritize"
      submit_event="confirm_reprioritize"
      submit_label={gettext("Reprioritize")}
    >
      <.input
        type="select"
        id="reprioritize-priority"
        name="priority"
        value=""
        label={gettext("New priority")}
        options={priority_options()}
        prompt={gettext("Choose a new priority")}
      />
    </.intervention_dialog>
    """
  end

  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :goal, :map, required: true
  attr :children, :list, required: true
  attr :title, :string, required: true
  attr :summary, :string, required: true
  attr :cancel_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true
  slot :inner_block, required: true

  # Shared confirmation-dialog scaffold for the goal-level interventions
  # (Reassign, Reprioritize). Renders the DelayedModal shell, the title, the
  # affected goal + not-started children list, and a form whose selector is the
  # caller-supplied inner block; the caller wires the submit/cancel events to its
  # own context op. Keeps the two interventions' shared markup in one place per
  # the "reuse the scaffold" contract, so only the selector and copy differ.
  defp intervention_dialog(assigns) do
    ~H"""
    <KanbanWeb.DelayedModal.delayed_modal
      id={@id}
      show
      on_cancel={JS.push(@cancel_event)}
      max_width="max-w-lg"
    >
      <div class="flex flex-col gap-4">
        <h2 class="text-lg font-semibold text-base-content">{@title}</h2>

        <p class="text-sm text-base-content opacity-70">{@summary}</p>

        <ul class="flex flex-col gap-1 text-sm text-base-content" data-intervention-affected>
          <li data-intervention-goal={@goal.id}>
            <span class="font-mono">{@goal.identifier}</span>
            <span class="opacity-70">— {@goal.title}</span>
          </li>
          <li :for={child <- @children} data-intervention-child={child.id}>
            <span class="font-mono">{child.identifier}</span>
            <span class="opacity-70">— {child.title}</span>
          </li>
        </ul>

        <form id={@form_id} phx-submit={@submit_event} class="flex flex-col gap-4">
          {render_slot(@inner_block)}

          <div class="flex justify-end gap-2">
            <.button type="button" phx-click={@cancel_event}>
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">
              {@submit_label}
            </.button>
          </div>
        </form>
      </div>
    </KanbanWeb.DelayedModal.delayed_modal>
    """
  end

  # The fleet-level aggregate rollups, derived from the single shared task fetch
  # (and the roster built from it), grouped so load_agents_data/1 stays under the
  # complexity budget.
  # `throughput_tasks` is the fixed-window, selector-independent set; the
  # throughput/success cards derive from it so a "30D" card always means 30 days.
  # Everything else (today header stats, trends-chart span) stays on the
  # selector-scoped `tasks`. `success_rate` rides the throughput block, so it is
  # now the fixed-window rate too — intentionally consistent with the cards.
  defp metric_assigns(tasks, throughput_tasks, agents, timezone, time_range) do
    %{
      stats: Agents.header_stats_from(tasks, timezone),
      fleet_health: Agents.fleet_health_from(agents),
      throughput_and_success: Agents.throughput_and_success_from(throughput_tasks, timezone),
      throughput_trends:
        Agents.throughput_trends_from(tasks, trend_days_for(time_range), timezone)
    }
  end

  # Stable risk-first ordering: agents advancing a goal inside an at-risk target
  # sort ahead of the rest, and (because Enum.sort_by/3 is stable) each group
  # keeps the roster's recency order. Agents with no target stay in the second
  # group and still render — none are dropped.
  defp order_risk_first(agents, agent_targets) do
    Enum.sort_by(agents, &if(on_at_risk?(&1, agent_targets), do: 0, else: 1))
  end

  defp on_at_risk?(agent, agent_targets) do
    agent_targets
    |> Map.get({agent.name, agent.owner_key}, [])
    |> Enum.any?(&(&1.status == :at_risk))
  end

  # The single target+goal annotation a roster card renders for an agent, or nil
  # when the agent advances no target. When the agent works several targets the
  # most-endangered one wins (at-risk, then missed, then the first) so the card
  # surfaces the reason it was floated to the top.
  defp primary_annotation(agent_targets, agent) do
    agent_targets
    |> Map.get({agent.name, agent.owner_key}, [])
    |> pick_annotation()
  end

  defp pick_annotation([]), do: nil

  defp pick_annotation(entries) do
    Enum.find(entries, &(&1.status == :at_risk)) ||
      Enum.find(entries, &(&1.status == :missed)) ||
      hd(entries)
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

  # Map the selected window to the throughput-trends day span so the chart's
  # width tracks the days selector instead of a fixed window (which would leave
  # empty tail buckets for windows narrower than the default). :all_time keeps
  # the historic default span.
  defp trend_days_for(:today), do: 1
  defp trend_days_for(:last_7_days), do: 7
  defp trend_days_for(:last_30_days), do: 30
  defp trend_days_for(:last_90_days), do: 90
  defp trend_days_for(_all_time), do: Agents.default_trend_days()

  # The drill-down for the selected agent, or nil when no agent is selected.
  # Reads from the shared task list already fetched in load_agents_data/1 (no
  # query in the LiveView).
  defp agent_detail_for(_tasks, nil), do: nil

  defp agent_detail_for(tasks, {_name, _owner_key} = identity),
    do: Agents.agent_detail_from(tasks, identity)

  # On a discrete select-agent click we don't have the shared task list in hand,
  # so fall back to the keyword API (a single fetch on the click path — not the
  # per-render hot path that load_agents_data/1 optimizes).
  defp selected_agent_detail(_scope, nil), do: nil

  defp selected_agent_detail(scope, {_name, _owner_key} = identity),
    do: Agents.agent_detail(identity, scope: scope)

  # The human-readable agent name from a selected identity, for display.
  defp selected_agent_name({name, _owner_key}), do: name

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
  # always runs first; when an agent identity {name, owner_key} is selected,
  # only events whose actor name AND owner key match survive — so selecting one
  # of two same-named agents shows only that human's events (W1244). A nil
  # selection leaves the kind-filtered list untouched.
  defp apply_filters(events, kind_filter, nil), do: filter_events(events, kind_filter)

  defp apply_filters(events, kind_filter, {name, owner_key}) do
    events
    |> filter_events(kind_filter)
    |> Enum.filter(&(&1.actor == name and Agents.owner_key_for_owner(&1.owner) == owner_key))
  end

  # Toggling the currently-selected agent identity clears the selection; any
  # other identity replaces it. Identities are {name, owner_key} tuples, so
  # equality is by value.
  defp toggle_agent(selected_identity, selected_identity), do: nil
  defp toggle_agent(_current, identity), do: identity

  # Flip a member's presence in a MapSet: drop it when present, add it when
  # absent. Backs the per-section collapse state for the detail panel.
  defp toggle_member(set, member) do
    if MapSet.member?(set, member),
      do: MapSet.delete(set, member),
      else: MapSet.put(set, member)
  end

  defp count_events_within_24h(events) do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_window_hours, :hour)

    Enum.count(events, fn
      %{at: %DateTime{} = at} -> DateTime.compare(at, cutoff) != :lt
      _ -> false
    end)
  end

  # Compact "last seen Nd ago" label for a dormant agent's last activity.
  # Uses whole-days elapsed (the dormancy granularity) to avoid a relative-time
  # dependency; the count-only string sidesteps per-locale plural forms.
  defp format_last_seen(%NaiveDateTime{} = last_active_at) do
    days = NaiveDateTime.diff(NaiveDateTime.utc_now(), last_active_at, :day)
    gettext("Last seen %{days}d ago", days: days)
  end

  defp format_last_seen(_), do: "—"
end
