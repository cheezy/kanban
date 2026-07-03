defmodule KanbanWeb.MetricsAgentLeaderboard do
  @moduledoc """
  Top-contributors panel for the workspace `/metrics` page.

  Consumes the list shape returned by
  `Kanban.Metrics.Workspace.agent_leaderboard/1`:

      [%{name: String.t(), kind: :agent | :human,
         completed: non_neg_integer(), success_pct: float()}, ...]

  Each row renders an avatar (via `KanbanWeb.Avatar` at size 18), the
  contributor name, a horizontal completion bar proportional to the
  panel's peak completion count, the integer completion total, and the
  success percentage in the done-tone (right-aligned, monospace).

  Renders the localized empty state when `:rows` is `[]`. Mirrors
  `design_handoff_stride/design_source/screens/extras.jsx` lines
  867-902.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette

  @doc """
  Renders the leaderboard panel.

  ## Attrs

    * `rows` — required. List of contributor maps; capped upstream at
      six entries by `Kanban.Metrics.Workspace.agent_leaderboard/1`. An empty
      list renders the empty state.
  """
  attr :rows, :list, required: true
  attr :window_days, :integer, default: 14

  def leaderboard(assigns) do
    assigns = assign(assigns, :peak, peak_completed(assigns.rows))

    ~H"""
    <section
      data-metrics-agent-leaderboard
      class="min-w-[220px]"
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;",
        "overflow: hidden;"
      ]}
    >
      <header style={[
        "padding: 14px 18px 6px;",
        "display: flex; align-items: baseline; gap: 8px;"
      ]}>
        <span style="font-size: 13.5px; font-weight: 600; color: var(--ink);">
          {gettext("Agents · last %{count} days", count: @window_days)}
        </span>
        <span style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);">
          {gettext("by completed")}
        </span>
      </header>

      <p
        :if={@rows == []}
        data-metrics-agent-leaderboard-empty
        style={[
          "margin: 0; padding: 16px 18px 20px;",
          "font-size: 12.5px; color: var(--ink-3); font-style: italic;"
        ]}
      >
        {gettext("No completions in the last %{count} days.", count: @window_days)}
      </p>

      <.row :for={row <- @rows} row={row} peak={@peak} />
    </section>
    """
  end

  attr :row, :map, required: true
  attr :peak, :integer, required: true

  defp row(assigns) do
    assigns =
      assigns
      |> assign(:palette, palette_for(assigns.row))
      |> assign(:bar_pct, bar_pct(assigns.row.completed, assigns.peak))

    ~H"""
    <div
      data-metrics-agent-leaderboard-row
      data-metrics-agent-leaderboard-kind={Atom.to_string(@row.kind)}
      style={[
        "display: grid;",
        "grid-template-columns: 24px 1fr 36px 48px;",
        "align-items: center; gap: 10px;",
        "padding: 6px 18px;",
        "border-top: 1px solid var(--line);"
      ]}
    >
      <Avatar.avatar kind={@row.kind} name={@row.name} palette={@palette} size={18} />

      <div style="min-width: 0;">
        <div
          data-metrics-agent-leaderboard-name
          style={[
            "font-size: 12px; font-weight: 500; color: var(--ink);",
            "margin-bottom: 3px;",
            "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
          ]}
        >
          {@row.name}
        </div>
        <div
          aria-hidden="true"
          style={[
            "height: 4px; border-radius: 2px;",
            "background: var(--surface-sunken); overflow: hidden;"
          ]}
        >
          <div
            data-metrics-agent-leaderboard-bar
            style={[
              "width: #{@bar_pct}%; height: 100%;",
              "background: #{bar_color(@row.kind)};"
            ]}
          />
        </div>
      </div>

      <span
        data-metrics-agent-leaderboard-completed
        style={[
          "text-align: right;",
          "font-family: var(--font-mono); font-size: 12px; font-weight: 600;",
          "color: var(--ink);",
          "font-variant-numeric: tabular-nums;"
        ]}
      >
        {@row.completed}
      </span>

      <span
        data-metrics-agent-leaderboard-success
        style={[
          "text-align: right;",
          "font-family: var(--font-mono); font-size: 11px;",
          "color: var(--st-done);",
          "font-variant-numeric: tabular-nums;"
        ]}
      >
        {format_success(@row.success_pct)}
      </span>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp peak_completed(rows) do
    rows
    |> Enum.map(&Map.get(&1, :completed, 0))
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp bar_pct(_completed, 0), do: 0
  defp bar_pct(completed, peak), do: round(completed / peak * 100)

  defp palette_for(%{kind: :agent, name: name}), do: AvatarPalette.for_agent(name)

  defp palette_for(%{kind: :human} = row) do
    case Map.get(row, :user_id) do
      id when is_integer(id) -> AvatarPalette.for_human(id)
      _ -> AvatarPalette.for_human(0)
    end
  end

  defp bar_color(:agent), do: "var(--stride-orange)"
  defp bar_color(:human), do: "var(--stride-violet)"
  defp bar_color(_), do: "var(--ink-3)"

  defp format_success(pct) when is_float(pct), do: "#{round(pct)}%"
  defp format_success(pct) when is_integer(pct), do: "#{pct}%"
  defp format_success(_), do: "—"
end
