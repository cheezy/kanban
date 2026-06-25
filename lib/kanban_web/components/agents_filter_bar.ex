defmodule KanbanWeb.AgentsFilterBar do
  @moduledoc """
  Presentational filter row for the Agents view: a board selector and a
  time-range ("days") selector that mirror the metrics board's filters.

  Both controls live inside one `<form phx-change="filter_change">`; the parent
  LiveView (`KanbanWeb.AgentsLive`) handles `"filter_change"`, reloads its
  scoped data, and re-renders. The component is purely presentational — it holds
  no state and runs no queries.

  Styling mirrors `KanbanWeb.MetricsLive.Components.metric_filters/1`: inline CSS
  custom properties (`var(--surface)`, `var(--line)`, `var(--ink)`,
  `var(--ink-3)`) so the row is theme-aware in both light and dark mode.
  """
  use KanbanWeb, :html

  @doc """
  Renders the board + time-range filter row.

  ## Attrs

    * `boards` — list of board structs (each exposing `:id` and `:name`) for the
      board `<select>` options. Required.
    * `board_id` — the selected board id, or `nil` for "All Boards". Defaults to nil.
    * `time_range` — the selected window atom (`:today`, `:last_7_days`,
      `:last_30_days`, `:last_90_days`, `:all_time`). Required.
  """
  attr :boards, :list, required: true
  attr :board_id, :integer, default: nil
  attr :time_range, :atom, required: true

  def filter_bar(assigns) do
    ~H"""
    <form
      id="agents-filter-form"
      phx-change="filter_change"
      style={[
        "display: flex; flex-wrap: wrap; align-items: flex-end; gap: 14px;",
        "padding: 12px 24px;",
        "background: var(--surface);",
        "border-bottom: 1px solid var(--line);"
      ]}
    >
      <div style="display: flex; flex-direction: column; gap: 4px; min-width: 200px;">
        <label for="agents-filter-board" style={label_style()}>{gettext("Board")}</label>
        <select id="agents-filter-board" name="board_id" style={select_style()}>
          <option value="" selected={is_nil(@board_id)}>{gettext("All Boards")}</option>
          <option :for={board <- @boards} value={board.id} selected={@board_id == board.id}>
            {board.name}
          </option>
        </select>
      </div>

      <div style="display: flex; flex-direction: column; gap: 4px; min-width: 200px;">
        <label for="agents-filter-days" style={label_style()}>{gettext("Time Range")}</label>
        <select id="agents-filter-days" name="time_range" style={select_style()}>
          <option value="today" selected={@time_range == :today}>{gettext("Today")}</option>
          <option value="last_7_days" selected={@time_range == :last_7_days}>
            {gettext("Last 7 Days")}
          </option>
          <option value="last_30_days" selected={@time_range == :last_30_days}>
            {gettext("Last 30 Days")}
          </option>
          <option value="last_90_days" selected={@time_range == :last_90_days}>
            {gettext("Last 90 Days")}
          </option>
          <option value="all_time" selected={@time_range == :all_time}>
            {gettext("All Time")}
          </option>
        </select>
      </div>
    </form>
    """
  end

  defp label_style do
    [
      "font-size: 9.5px; font-weight: 600;",
      "text-transform: uppercase; letter-spacing: 0.08em;",
      "color: var(--ink-3);"
    ]
  end

  defp select_style do
    [
      "padding: 6px 10px; border-radius: 6px;",
      "border: 1px solid var(--line);",
      "background: var(--surface); color: var(--ink);",
      "font-size: 12.5px;"
    ]
  end
end
