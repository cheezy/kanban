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
  only — a page reload resets to all boards.

  The time-range control is a working, session-only window selector
  (W1260): it offers 7/14/30/90-day windows (default 14) and re-renders
  every series and KPI through the `:window_days` option on the
  `Kanban.Metrics` reads. Like the board selection it lives in assigns
  only — a page reload resets to 14 days. The toolbar carries only these
  two working controls — there are no decorative placeholder buttons.
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

  # Allow-list of supported window sizes — single source of truth for both the
  # selector options and the param parser. Mirrors Kanban.Metrics'
  # @allowed_window_days; an unsupported value falls back to the 14-day default.
  @window_options [7, 14, 30, 90]
  @default_window_days 14

  @impl true
  def mount(_params, _session, socket) do
    boards = scoped_boards(socket.assigns.current_scope)
    selected_ids = Enum.map(boards, & &1.id)

    {:ok,
     socket
     |> assign(:page_title, "Stride · Metrics")
     |> assign(:boards, boards)
     |> assign(:selected_window_days, @default_window_days)
     |> assign_workspace_metrics(selected_ids)}
  end

  @impl true
  def handle_event("board_filter_change", params, socket) do
    selected_ids = parse_selected_ids(params, socket.assigns.boards)
    {:noreply, assign_workspace_metrics(socket, selected_ids)}
  end

  def handle_event("window_change", %{"window_days" => raw}, socket) do
    socket = assign(socket, :selected_window_days, parse_window_days(raw))
    {:noreply, assign_workspace_metrics(socket, socket.assigns.selected_board_ids)}
  end

  # Re-reads every workspace series for the current selection and refreshes the
  # selection-dependent assigns. The selected ids are intersected with the
  # visible boards (see board_ids_filter/2) before reaching Kanban.Metrics, so
  # an "all selected" or "none selected" state shows all visible boards.
  defp assign_workspace_metrics(socket, selected_ids) do
    boards = socket.assigns.boards
    window_days = socket.assigns.selected_window_days

    opts = [
      scope: socket.assigns.current_scope,
      board_ids: board_ids_filter(boards, selected_ids),
      window_days: window_days
    ]

    socket
    |> assign(:selected_board_ids, selected_ids)
    |> assign(:kpis, Metrics.workspace_kpis(opts))
    |> assign(:cycle_series, Metrics.cycle_time_daily(opts))
    |> assign(:throughput_series, Metrics.throughput_daily(opts))
    |> assign(:leaderboard, Metrics.agent_leaderboard(opts))
    |> assign(:flow_snapshots, Metrics.cumulative_flow(opts))
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
          <.board_selector boards={@boards} selected_board_ids={@selected_board_ids} />
          <.window_selector selected_window_days={@selected_window_days} />
        </header>

        <div class="flex-1 overflow-y-auto px-3 md:px-7 pt-2 pb-7 flex flex-col gap-3.5">
          <MetricsKpiStrip.kpi_strip kpis={@kpis} window_days={@selected_window_days} />

          <MetricsCycleTimeChart.cycle_time_chart
            data={@cycle_series}
            window_days={@selected_window_days}
          />

          <div class="flex flex-col md:grid md:grid-cols-[1.4fr_1fr] gap-3.5">
            <MetricsThroughputChart.throughput_chart
              series={@throughput_series}
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

  # --- Window selector ----------------------------------------------------

  attr :selected_window_days, :integer, required: true

  defp window_selector(assigns) do
    assigns = assign(assigns, :window_options, @window_options)

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

  # Parses the selector param into a supported window size, falling back to the
  # 14-day default for anything outside the allow-list. Keeping the stored value
  # valid drives both the <select> selected state and the rendered labels;
  # Kanban.Metrics independently clamps the value before any query runs.
  defp parse_window_days(value) when is_integer(value) and value in @window_options, do: value

  defp parse_window_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days in @window_options -> days
      _ -> @default_window_days
    end
  end

  defp parse_window_days(_value), do: @default_window_days

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
