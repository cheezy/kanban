defmodule KanbanWeb.AgentsLive.DataLoader do
  @moduledoc """
  The data-load path for `KanbanWeb.AgentsLive`, extracted from the LiveView to
  keep it under the module-size guideline.

  Fetches the board-scoped task sets and the delivery rollup through
  `Kanban.Agents` / `Kanban.Targets.DeliveryRollup` (no Ecto in the LiveView),
  derives every task-dependent assign (roster, events, header stats, throughput
  cards, drill-down, reassignable goal ids) and merges them onto the socket. The
  zero-DB placeholder used on the disconnected mount runs the same derivation on
  empty inputs, so both paths emit an identical set of assign keys. Moved
  unchanged, including the narrow DB-error rescue that keeps last-good data
  (D125) and the single-fetch wider-window reasoning (W1734).

  The LiveView keeps the mount/event/info callbacks that call into this module;
  `KanbanWeb.AgentsLive.Interventions` also calls `load_agents_data/1` to
  refresh the page after a reassign, reprioritize or undo.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kanban.Agents
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Tasks
  alias KanbanWeb.AgentsLive.Filters

  require Logger

  @recent_activity_limit 200
  @event_window_hours 24
  # Fixed trailing window (days) for the selector-independent throughput cards.
  # Must cover the widest card comparison: prev_30d counts the trailing 60 days
  # (2 x 30), so the window has to be at least 60.
  @throughput_window_days 60

  # Zero-DB stand-in for the heavy load path, used on the disconnected mount so
  # the static first render is instant. Runs the same derivation helpers as the
  # connected load on empty inputs, so every assign key the connected path
  # produces exists here too (no nil-crash in the template) and the shell renders
  # the workspace empty state, replaced on connect by the real load.
  @doc false
  def assign_placeholder_data(socket) do
    assign_agents_data(socket, [], [], empty_delivery_rollup())
  end

  # The delivery rollup for a workspace with no accessible targets — the exact
  # shape DeliveryRollup.build/2 returns in that case (see its @type t()), used
  # by the disconnected placeholder without a DB round trip.
  defp empty_delivery_rollup, do: %{targets: [], unrolled_agents: [], agent_targets: %{}}

  @doc false
  def load_agents_data(socket) do
    scope = socket.assigns.current_scope

    try do
      {tasks, throughput_tasks} = fetch_task_sets(socket, scope)
      # Build the delivery rollup once (board-scoped, no LiveView Ecto) and reuse
      # it for the delivery-health band, the at-risk explainer, and the roster's
      # target annotation + risk-first ordering (W1589).
      delivery_rollup = DeliveryRollup.build(scope, timezone: socket.assigns.timezone)

      assign_agents_data(socket, tasks, throughput_tasks, delivery_rollup)
    rescue
      # Degrade gracefully on a transient DB failure (e.g. a statement timeout on
      # a large history) instead of letting the LiveView crash → "Something went
      # wrong" → reconnect → remount → reload loop (D125). Keep the last-good /
      # placeholder assigns already on the socket and log. The rescue is narrow —
      # only DB connection/timeout errors are caught; any other exception
      # re-raises so genuine logic bugs are never masked.
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        Logger.error(
          "[AgentsLive] load_agents_data failed, keeping last-good data: " <>
            Exception.message(error)
        )

        put_flash(
          socket,
          :error,
          gettext("Agent data could not be refreshed just now. Showing the last available data.")
        )
    end
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

  # The two board-scoped task sets every derivation shares: the selector-filtered
  # set that drives the roster, events, and header stats, and a fixed
  # @throughput_window_days set that feeds the selector-independent throughput
  # cards (so a "30D" card always means 30 trailing days regardless of the
  # selector). W1242 already fetched each set ONCE per render; W1734 fetches the
  # two sets from a SINGLE query: since both windows share the same updated_at
  # ordering and row cap and the narrower window is the recent sub-range of the
  # wider, one fetch over the WIDER window plus an in-memory boundary filter for
  # the narrower yields exactly what two separate fetches did (the max_tasks cap
  # test in agents_test.exs pins the cap-boundary reasoning). This halves the
  # query volume on the hottest path — every load and every 250ms-debounced agent
  # event — on top of the W1733 projection. The boundary math lives in
  # Kanban.Agents (within_time_range/within_fixed_window) so the memory-side and
  # query-side filters can never drift.
  defp fetch_task_sets(socket, scope) do
    timezone = socket.assigns.timezone
    time_range = socket.assigns.time_range

    base_opts = [scope: scope, board_id: socket.assigns.board_id, timezone: timezone]
    fetched = base_opts |> wider_window_opts(time_range) |> Agents.fetch_tasks()

    tasks = Agents.within_time_range(fetched, time_range, timezone)
    throughput_tasks = Agents.within_fixed_window(fetched, @throughput_window_days, timezone)

    {tasks, throughput_tasks}
  end

  # Fetch opts for the WIDER of the selector window and the fixed throughput
  # window. When the selector is unbounded (:all_time) or reaches at least as far
  # back as the throughput window, the selector window is wider — fetch it;
  # otherwise the @throughput_window_days window is wider, so fetch that. Either
  # way the narrower set is derived from the result in memory.
  defp wider_window_opts(base_opts, time_range) do
    selector_days = Agents.time_range_days_back(time_range)

    if is_nil(selector_days) or selector_days >= @throughput_window_days do
      Keyword.put(base_opts, :time_range, time_range)
    else
      Keyword.put(base_opts, :window_days, @throughput_window_days)
    end
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
      events: Filters.apply_filters(events, socket.assigns.filter, socket.assigns.selected_agent),
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
  @doc false
  def selected_agent_detail(_scope, nil), do: nil

  def selected_agent_detail(scope, {_name, _owner_key} = identity),
    do: Agents.agent_detail(identity, scope: scope)

  defp count_events_within_24h(events) do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_window_hours, :hour)

    Enum.count(events, fn
      %{at: %DateTime{} = at} -> DateTime.compare(at, cutoff) != :lt
      _ -> false
    end)
  end
end
