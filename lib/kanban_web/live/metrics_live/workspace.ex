defmodule KanbanWeb.MetricsLive.Workspace do
  @moduledoc """
  Workspace-level Metrics page at `/metrics`.

  Composes the W580-W584 component chain — `MetricsKpiStrip`,
  `MetricsCycleTimeChart`, `MetricsThroughputChart`,
  `MetricsAgentLeaderboard`, and `MetricsCumulativeFlow` — against the
  workspace-scoped read functions added in W579
  (`Kanban.Metrics.workspace_kpis/1` and the four daily/per-bucket
  helpers).

  All data flows through `Kanban.Metrics`; no Ecto in this module
  per project rules. Distinct from `KanbanWeb.MetricsLive.Dashboard`
  (board-scoped) — the existing dashboard LiveView is unchanged.

  The "All boards" toolbar control is a working, session-only board
  selector (W1256): it lists the viewer's boards, defaults to all
  selected, and re-renders every series through the `:board_ids` filter
  on the `Kanban.Metrics` reads. The selection lives in LiveView assigns
  only — a page reload resets to all boards. The remaining toolbar
  buttons ("Last 14 days", "Filter") are still decorative placeholders.
  """
  use KanbanWeb, :live_view

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Metrics
  alias KanbanWeb.MetricsAgentLeaderboard
  alias KanbanWeb.MetricsCumulativeFlow
  alias KanbanWeb.MetricsCycleTimeChart
  alias KanbanWeb.MetricsKpiStrip
  alias KanbanWeb.MetricsThroughputChart

  @impl true
  def mount(_params, _session, socket) do
    boards = scoped_boards(socket.assigns.current_scope)
    selected_ids = Enum.map(boards, & &1.id)

    {:ok,
     socket
     |> assign(:page_title, "Stride · Metrics")
     |> assign(:boards, boards)
     |> assign_workspace_metrics(selected_ids)}
  end

  @impl true
  def handle_event("board_filter_change", params, socket) do
    selected_ids = parse_selected_ids(params, socket.assigns.boards)
    {:noreply, assign_workspace_metrics(socket, selected_ids)}
  end

  # Re-reads every workspace series for the current selection and refreshes the
  # selection-dependent assigns. The selected ids are intersected with the
  # visible boards (see board_ids_filter/2) before reaching Kanban.Metrics, so
  # an "all selected" or "none selected" state shows all visible boards.
  defp assign_workspace_metrics(socket, selected_ids) do
    boards = socket.assigns.boards

    opts = [
      scope: socket.assigns.current_scope,
      board_ids: board_ids_filter(boards, selected_ids)
    ]

    socket
    |> assign(:selected_board_ids, selected_ids)
    |> assign(:kpis, Metrics.workspace_kpis(opts))
    |> assign(:cycle_series, Metrics.cycle_time_daily(opts))
    |> assign(:throughput_series, Metrics.throughput_daily(opts))
    |> assign(:leaderboard, Metrics.agent_leaderboard(opts))
    |> assign(:flow_snapshots, Metrics.cumulative_flow(opts))
    |> assign(:after_goal_adoption_7d, Metrics.after_goal_adoption_7d(opts))
    |> assign(:goal_done_latency, Metrics.goal_to_done_latency_percentiles(opts))
    |> assign(:window_label, window_label(boards, selected_ids))
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
          <.board_selector boards={@boards} selected_board_ids={@selected_board_ids} />
          <.toolbar_button label={gettext("Last 14 days")} />
          <.toolbar_button label={gettext("Filter")} />
        </header>

        <div class="flex-1 overflow-y-auto px-3 md:px-7 pt-2 pb-7 flex flex-col gap-3.5">
          <MetricsKpiStrip.kpi_strip kpis={@kpis} />

          <.after_goal_adoption_tile count={@after_goal_adoption_7d} />

          <.goal_to_done_latency_tile latency={@goal_done_latency} />

          <MetricsCycleTimeChart.cycle_time_chart data={@cycle_series} />

          <div class="flex flex-col md:grid md:grid-cols-[1.4fr_1fr] gap-3.5">
            <MetricsThroughputChart.throughput_chart series={@throughput_series} />
            <MetricsAgentLeaderboard.leaderboard rows={@leaderboard} />
          </div>

          <MetricsCumulativeFlow.cumulative_flow snapshots={@flow_snapshots} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- after_goal adoption tile -------------------------------------------

  attr :count, :integer, required: true

  defp after_goal_adoption_tile(assigns) do
    ~H"""
    <div
      data-metrics-after-goal-adoption
      style={[
        "padding: 14px 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <p style={[
        "margin: 0;",
        "font-size: 9.5px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {gettext("after_goal adoption · 7d")}
      </p>
      <div style="margin: 4px 0 0; display: flex; align-items: baseline; gap: 8px;">
        <span
          data-metrics-after-goal-value
          style={[
            "font-size: 24px; font-weight: 600;",
            "letter-spacing: -0.025em;",
            "color: var(--ink);",
            "font-variant-numeric: tabular-nums;"
          ]}
        >
          {@count}
        </span>
        <span style={[
          "font-size: 11px;",
          "font-family: var(--font-mono);",
          "color: var(--ink-3);"
        ]}>
          {gettext("projects reporting")}
        </span>
      </div>
    </div>
    """
  end

  # --- goal-to-Done latency tile ------------------------------------------

  attr :latency, :map, required: true

  defp goal_to_done_latency_tile(assigns) do
    ~H"""
    <div
      data-metrics-goal-done-latency
      style={[
        "padding: 14px 18px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "display: grid; grid-template-columns: 1fr 1fr; gap: 18px;"
      ]}
    >
      <.latency_cell
        marker="p50"
        label={gettext("Goal → Done · p50")}
        seconds={@latency.p50_seconds}
        sample_size={@latency.sample_size}
      />
      <.latency_cell
        marker="p95"
        label={gettext("Goal → Done · p95")}
        seconds={@latency.p95_seconds}
        sample_size={@latency.sample_size}
      />
    </div>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :seconds, :integer, required: true
  attr :sample_size, :integer, required: true

  defp latency_cell(assigns) do
    ~H"""
    <div data-metrics-goal-done-latency-cell={@marker}>
      <p style={[
        "margin: 0;",
        "font-size: 9.5px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </p>
      <div style="margin: 4px 0 0; display: flex; align-items: baseline; gap: 8px;">
        <span
          data-metrics-goal-done-latency-value
          style={[
            "font-size: 24px; font-weight: 600;",
            "letter-spacing: -0.025em;",
            "color: var(--ink);",
            "font-variant-numeric: tabular-nums;"
          ]}
        >
          {format_latency_seconds(@seconds)}
        </span>
        <span style={[
          "font-size: 11px;",
          "font-family: var(--font-mono);",
          "color: var(--ink-3);"
        ]}>
          {gettext("n=%{n}", n: @sample_size)}
        </span>
      </div>
    </div>
    """
  end

  defp format_latency_seconds(0), do: "0s"

  defp format_latency_seconds(seconds) when is_integer(seconds) and seconds < 60 do
    "#{seconds}s"
  end

  defp format_latency_seconds(seconds) when is_integer(seconds) and seconds < 3600 do
    minutes = div(seconds, 60)
    rem_seconds = rem(seconds, 60)
    if rem_seconds == 0, do: "#{minutes}m", else: "#{minutes}m #{rem_seconds}s"
  end

  defp format_latency_seconds(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    rem_minutes = div(rem(seconds, 3600), 60)
    if rem_minutes == 0, do: "#{hours}h", else: "#{hours}h #{rem_minutes}m"
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

  # --- Decorative toolbar -------------------------------------------------

  attr :label, :string, required: true

  defp toolbar_button(assigns) do
    ~H"""
    <button
      type="button"
      data-metrics-toolbar-placeholder
      aria-disabled="true"
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 4px 10px; border-radius: 5px;",
        "font: inherit; font-size: 12px; font-weight: 500;",
        "color: var(--ink-2);",
        "background: var(--surface); border: 1px solid var(--line);",
        "cursor: not-allowed; opacity: 0.75;"
      ]}
    >
      {@label}
    </button>
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

  defp window_label(boards, selected_ids) do
    today = Date.utc_today()
    start = Date.add(today, -13)
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
