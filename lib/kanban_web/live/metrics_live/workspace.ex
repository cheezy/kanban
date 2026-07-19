defmodule KanbanWeb.MetricsLive.Workspace do
  @moduledoc """
  Workspace-level Metrics page at `/metrics`.

  Composes the W580-W584 component chain — `MetricsKpiStrip`,
  `MetricsCycleTimeChart`, `MetricsThroughputChart`,
  `MetricsAgentLeaderboard`, and `MetricsCumulativeFlow` — against the
  workspace-scoped read functions added in W579
  (`Kanban.Metrics.workspace_kpis/1` and the four daily/per-bucket
  helpers).

  `MetricsCycleTimeChart` is rendered twice (W1723): once with its cycle
  defaults, and once parameterized for the daily p50 lead-time series in the
  violet brand accent directly below it. Both series come out of the same
  `Workspace.overview/1` bundle, so the board and window selectors drive them
  together and the pair still costs a single completed-task read.

  All data flows through `Kanban.Metrics`; no Ecto in this module
  per project rules. Distinct from `KanbanWeb.MetricsLive.Dashboard`
  (board-scoped) — the existing dashboard LiveView is unchanged.

  The "All boards" toolbar control is a working, session-only board
  selector (W1256): it lists the viewer's boards, defaults to all
  selected, and re-renders every series through the `:board_ids` filter
  on the `Kanban.Metrics` reads. The selection lives in LiveView assigns
  only — a page reload resets to all boards.

  The time-range control is a working, session-only window selector
  (W1260): it offers 7/14/30/90-day windows (default 14) and re-renders
  every series and KPI through the `:window_days` option on the
  `Kanban.Metrics` reads. Like the board selection it lives in assigns
  only — a page reload resets to 14 days.

  The "Exclude Weekends" checkbox (W1743) mirrors the board metrics pages'
  control: when checked, Saturdays and Sundays drop out of every series, tasks
  completed on a weekend stop counting, and the remaining durations are measured
  in business time. Note that the window keeps meaning *calendar* days, so a
  14-day window renders 10 bars under a "last 14 days" subtitle — the subtitle
  describes the span, not the bar count. Like the other two controls the state
  lives in assigns only, so a reload resets it to unchecked. The toolbar carries
  only these three working controls — there are no decorative placeholder buttons.
  """
  use KanbanWeb, :live_view

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Metrics.Workspace
  alias KanbanWeb.MetricsAgentLeaderboard
  alias KanbanWeb.MetricsCumulativeFlow
  alias KanbanWeb.MetricsCycleTimeChart
  alias KanbanWeb.MetricsKpiStrip
  alias KanbanWeb.MetricsLive.Helpers
  alias KanbanWeb.MetricsThroughputChart

  # The window allow-list, its default, and the param parser live in
  # `Helpers` so the export controller (which has no socket) resolves a window
  # exactly the way this page does. Mirrors Kanban.Metrics' @allowed_window_days;
  # an unsupported value falls back to the 14-day default.

  @impl true
  def mount(_params, _session, socket) do
    # The heavy metric reads run ONLY on the connected mount. The static
    # (disconnected) first render seeds zero placeholders — every data assign the
    # template reads is present — so first paint is instant; the connected mount
    # then loads the real data and replaces it. This halves the per-load query
    # volume the old unconditional load incurred by running on BOTH the
    # disconnected and connected mount (D120). Boards are still listed on both
    # paths because the header renders their names before connect.
    socket = assign(socket, initial_assigns(socket))
    selected_ids = Enum.map(socket.assigns.boards, & &1.id)

    socket =
      if connected?(socket) do
        assign_workspace_metrics(socket, selected_ids)
      else
        assign_placeholder_metrics(socket, selected_ids)
      end

    {:ok, socket}
  end

  # Assigns that do not depend on the heavy metric fetch — seeded on both the
  # disconnected and connected mount so the first render has every selector
  # assign it needs. Boards are listed here (not gated) because the header
  # renders their names before connect; only the metric reads are deferred.
  defp initial_assigns(socket) do
    %{
      page_title: "Stride · Metrics",
      boards: scoped_boards(socket.assigns.current_scope),
      selected_window_days: Helpers.default_window_days(),
      exclude_weekends: false,
      timezone: KanbanWeb.Timezone.browser_timezone(socket)
    }
  end

  @impl true
  def handle_event("board_filter_change", params, socket) do
    selected_ids = parse_selected_ids(params, socket.assigns.boards)
    {:noreply, assign_workspace_metrics(socket, selected_ids)}
  end

  @impl true
  def handle_event("window_change", %{"window_days" => raw}, socket) do
    socket = assign(socket, :selected_window_days, Helpers.parse_window_days(raw))
    {:noreply, assign_workspace_metrics(socket, socket.assigns.selected_board_ids)}
  end

  # An unchecked box omits the key entirely, so the absent param parses to false
  # — which is why no hidden "false" companion input is needed (or wanted) on the
  # checkbox itself.
  @impl true
  def handle_event("weekend_filter_change", params, socket) do
    socket =
      assign(
        socket,
        :exclude_weekends,
        Helpers.parse_exclude_weekends(params["exclude_weekends"])
      )

    {:noreply, assign_workspace_metrics(socket, socket.assigns.selected_board_ids)}
  end

  # Re-reads every workspace series for the current selection and refreshes the
  # selection-dependent assigns via the single consolidated overview/1 call. The
  # selected ids are intersected with the visible boards (see board_ids_filter/2)
  # before reaching Kanban.Metrics, so an "all selected" or "none selected" state
  # shows all visible boards. Runs on the connected mount and both selector
  # events — never on the disconnected render (see mount/3, D120).
  defp assign_workspace_metrics(socket, selected_ids) do
    boards = socket.assigns.boards
    window_days = socket.assigns.selected_window_days

    opts = [
      scope: socket.assigns.current_scope,
      board_ids: board_ids_filter(boards, selected_ids),
      window_days: window_days,
      exclude_weekends: socket.assigns.exclude_weekends,
      timezone: Map.get(socket.assigns, :timezone, "Etc/UTC")
    ]

    put_overview(socket, Workspace.overview(opts), selected_ids)
  end

  # Disconnected-mount stand-in: the zero overview shape with NO query, so the
  # static first render has every data assign the template reads and never
  # crashes. Replaced by the real load on the connected mount (D120).
  defp assign_placeholder_metrics(socket, selected_ids) do
    overview =
      Workspace.placeholder_overview(
        window_days: socket.assigns.selected_window_days,
        exclude_weekends: socket.assigns.exclude_weekends,
        timezone: socket.assigns.timezone
      )

    put_overview(socket, overview, selected_ids)
  end

  # Assigns the six series payloads plus the selection-derived assigns. Shared
  # by the real load and the disconnected placeholder so both paths emit an
  # identical set of assign keys. `:lead_series` is read with `Map.fetch!/2`
  # rather than dot access so a caller that forgets to supply it fails loudly
  # here instead of rendering a page missing an assign the template reads.
  defp put_overview(socket, overview, selected_ids) do
    boards = socket.assigns.boards
    window_days = socket.assigns.selected_window_days

    socket
    |> assign(:selected_board_ids, selected_ids)
    |> assign(:kpis, overview.kpis)
    |> assign(:cycle_series, overview.cycle_series)
    |> assign(:lead_series, Map.fetch!(overview, :lead_series))
    |> assign(:throughput_series, overview.throughput_series)
    |> assign(:leaderboard, overview.leaderboard)
    |> assign(:flow_snapshots, overview.flow_snapshots)
    |> assign(:window_label, window_label(window_days, boards, selected_ids))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:metrics}>
      <:breadcrumbs>
        <span>{gettext("Workspace")}</span>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("Metrics")}</span>
      </:breadcrumbs>

      <div
        data-metrics-workspace
        class="stride-screen"
        style="display: flex; flex-direction: column; min-height: 0;"
      >
        <header
          data-metrics-header
          class="flex flex-wrap items-baseline gap-3 px-3 md:px-7 pt-5 pb-2"
        >
          <h1 style={[
            "margin: 0;",
            "font-size: 22px; font-weight: 600;",
            "letter-spacing: -0.02em;",
            "color: var(--ink);"
          ]}>
            {gettext("Metrics")}
          </h1>
          <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
            {@window_label}
          </span>
          <span style="flex: 1;" />
          <.window_selector selected_window_days={@selected_window_days} />
          <.board_selector boards={@boards} selected_board_ids={@selected_board_ids} />
          <.weekend_selector exclude_weekends={@exclude_weekends} />
        </header>

        <div class="flex-1 overflow-y-auto px-3 md:px-7 pt-2 pb-7 flex flex-col gap-3.5">
          <MetricsKpiStrip.kpi_strip kpis={@kpis} window_days={@selected_window_days} />

          <MetricsCycleTimeChart.cycle_time_chart
            data={@cycle_series}
            window_days={@selected_window_days}
          />

          <%!-- The same component as the cycle chart above, parameterized for
          the lead series (W1722): violet rather than orange so the two are
          distinguishable, and its own marker prefix so both charts stay
          unambiguous to tests and tooling. Every value is a literal set here
          in code — never user input — because the colour and prefix reach
          markup attributes. --%>
          <MetricsCycleTimeChart.cycle_time_chart
            data={@lead_series}
            window_days={@selected_window_days}
            color="var(--stride-violet)"
            title={gettext("Lead time · daily median (min)")}
            marker_prefix="lead-time"
            series_name="lead"
          />

          <div class="flex flex-col md:grid md:grid-cols-[1.4fr_1fr] gap-3.5">
            <%!-- The throughput series is bare counts, so its x-axis dates come
            from the cycle series. Both are bucketed over the same day range
            (same window, timezone, and weekend flag), so they are always the
            same length and order. Passing them explicitly matters once weekends
            are excluded: the chart's fallback infers consecutive calendar days
            back from today, which would mislabel every weekday point. --%>
            <MetricsThroughputChart.throughput_chart
              series={@throughput_series}
              dates={Enum.map(@cycle_series, & &1.date)}
              window_days={@selected_window_days}
            />
            <MetricsAgentLeaderboard.leaderboard
              rows={@leaderboard}
              window_days={@selected_window_days}
            />
          </div>

          <MetricsCumulativeFlow.cumulative_flow snapshots={@flow_snapshots} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Board selector -----------------------------------------------------

  attr :boards, :list, required: true
  attr :selected_board_ids, :list, required: true

  defp board_selector(assigns) do
    ~H"""
    <details data-metrics-board-selector style="position: relative;">
      <summary
        data-metrics-board-selector-summary
        style={[
          "list-style: none; display: inline-flex; align-items: center; gap: 5px;",
          "padding: 4px 10px; border-radius: 5px;",
          "font-size: 12px; font-weight: 500;",
          "color: var(--ink-2);",
          "background: var(--surface); border: 1px solid var(--line);",
          "cursor: pointer; user-select: none;"
        ]}
      >
        {selector_summary_label(@boards, @selected_board_ids)}
        <.icon name="hero-chevron-down" class="size-3" />
      </summary>
      <form
        id="board-filter-form"
        phx-change="board_filter_change"
        style={[
          "position: absolute; right: 0; top: calc(100% + 4px); z-index: 20;",
          "min-width: 200px; max-height: 280px; overflow-y: auto;",
          "display: flex; flex-direction: column; gap: 2px;",
          "padding: 6px; border-radius: 8px;",
          "background: var(--surface); border: 1px solid var(--line);",
          "box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18);"
        ]}
      >
        <p
          :if={@boards == []}
          style="margin: 0; padding: 6px 8px; font-size: 12px; color: var(--ink-3);"
        >
          {gettext("No boards yet")}
        </p>
        <label
          :for={board <- @boards}
          style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 5px 8px; border-radius: 5px;",
            "font-size: 12.5px; color: var(--ink); cursor: pointer;"
          ]}
        >
          <%!--
            A raw checkbox (not core_components' <.input type="checkbox">) is
            deliberate here: <.input> emits a hidden value="false" companion for
            a single boolean field, which would inject "false" into this shared
            name="board_ids[]" array and corrupt the multi-select group. The
            checkbox group has no Ecto-backed form field — selection is held in
            assigns only — so the <.input>/field plumbing does not apply.
          --%>
          <input
            type="checkbox"
            name="board_ids[]"
            value={board.id}
            checked={board.id in @selected_board_ids}
            class="checkbox checkbox-sm"
          />
          <span>{board.name}</span>
        </label>
      </form>
    </details>
    """
  end

  # --- Exclude-weekends selector ------------------------------------------

  attr :exclude_weekends, :boolean, required: true

  # Mirrors the board metrics pages' checkbox (MetricsLive.Components.metric_filters/1)
  # so the two pages read as one control. A raw checkbox rather than
  # core_components' <.input type="checkbox"> for the same reason the board
  # selector above documents: <.input> emits a hidden value="false" companion,
  # and here the absent-key-means-false semantics are what the handler relies on.
  # Every colour is a theme token, so the pill tracks light and dark mode.
  defp weekend_selector(assigns) do
    ~H"""
    <form id="weekend-filter-form" phx-change="weekend_filter_change" style="margin: 0;">
      <label style={[
        "display: inline-flex; align-items: center; gap: 8px;",
        "padding: 4px 10px; border-radius: 5px;",
        "background: var(--surface); border: 1px solid var(--line);",
        "cursor: pointer; user-select: none;"
      ]}>
        <input
          type="checkbox"
          id="exclude_weekends"
          name="exclude_weekends"
          value="true"
          checked={@exclude_weekends}
          data-metrics-weekend-selector
          style="width: 14px; height: 14px; accent-color: var(--stride-orange);"
        />
        <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
          {gettext("Exclude Weekends")}
        </span>
      </label>
    </form>
    """
  end

  # --- Window selector ----------------------------------------------------

  attr :selected_window_days, :integer, required: true

  defp window_selector(assigns) do
    assigns = assign(assigns, :window_options, Helpers.window_options())

    ~H"""
    <form id="window-days-form" phx-change="window_change" style="margin: 0;">
      <select
        name="window_days"
        data-metrics-window-selector
        aria-label={gettext("Time range")}
        style={[
          "appearance: none; -webkit-appearance: none;",
          "padding: 4px 26px 4px 10px; border-radius: 5px;",
          "font: inherit; font-size: 12px; font-weight: 500;",
          "color: var(--ink-2);",
          "background: var(--surface); border: 1px solid var(--line);",
          "background-image: linear-gradient(45deg, transparent 50%, var(--ink-3) 50%), linear-gradient(135deg, var(--ink-3) 50%, transparent 50%);",
          "background-position: calc(100% - 14px) center, calc(100% - 9px) center;",
          "background-size: 5px 5px, 5px 5px; background-repeat: no-repeat;",
          "cursor: pointer;"
        ]}
      >
        <option
          :for={days <- @window_options}
          value={days}
          selected={days == @selected_window_days}
        >
          {gettext("Last %{count} days", count: days)}
        </option>
      </select>
    </form>
    """
  end

  # --- Helpers ------------------------------------------------------------

  defp scoped_boards(%Scope{user: %{} = user}), do: Boards.list_boards(user)
  defp scoped_boards(_scope), do: []

  # Parses the checkbox params into a list of integer board ids, keeping only
  # ids the viewer can actually see. Unchecking every box drops the "board_ids"
  # key entirely, which parses to [] — the "all boards" state.
  defp parse_selected_ids(%{"board_ids" => ids}, boards) when is_list(ids) do
    visible = MapSet.new(boards, & &1.id)

    ids
    |> Enum.map(&parse_board_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(visible, &1))
  end

  defp parse_selected_ids(_params, _boards), do: []

  defp parse_board_id(value) when is_integer(value), do: value

  defp parse_board_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_board_id(_value), do: nil

  # Returns nil (no filter — all visible boards) when the selection is empty or
  # covers every visible board; otherwise the strict subset. Passing nil is a
  # no-op in Kanban.Metrics, so the page falls back to all visible boards.
  defp board_ids_filter(boards, selected_ids) do
    selected_set = MapSet.new(selected_ids)
    all_set = MapSet.new(boards, & &1.id)

    cond do
      selected_ids == [] -> nil
      MapSet.equal?(selected_set, all_set) -> nil
      true -> selected_ids
    end
  end

  defp window_label(window_days, boards, selected_ids) do
    today = Date.utc_today()
    start = Date.add(today, -(window_days - 1))
    range = "#{Calendar.strftime(start, "%b %-d")} – #{Calendar.strftime(today, "%b %-d")}"

    "#{range} · #{board_scope_label(boards, selected_ids)}"
  end

  # Human label for how many boards currently feed the page. An all/none
  # selection reads as "all boards" (the default); a strict subset reads as the
  # selected-board count.
  defp board_scope_label(boards, selected_ids) do
    case selected_board_count(boards, selected_ids) do
      :all -> gettext("all boards")
      1 -> gettext("1 board")
      n -> gettext("%{count} boards", count: n)
    end
  end

  defp selector_summary_label(boards, selected_ids) do
    case selected_board_count(boards, selected_ids) do
      :all -> gettext("All boards")
      n -> gettext("%{count} of %{total} boards", count: n, total: length(boards))
    end
  end

  # :all when the selection is empty or spans every visible board; otherwise the
  # count of selected visible boards.
  defp selected_board_count(boards, selected_ids) do
    if board_ids_filter(boards, selected_ids) == nil do
      :all
    else
      length(selected_ids)
    end
  end
end
