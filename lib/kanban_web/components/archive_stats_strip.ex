defmodule KanbanWeb.ArchiveStatsStrip do
  @moduledoc """
  5-cell stats strip rendered above the filter chips on the Archive
  view at `/boards/:id/archive`.

  Reads from a `Kanban.Archives.archive_stats/1` map and surfaces five
  per-bucket counters: Total / Completed / Cancelled / Won't do +
  duplicate / Avg cycle. Mirrors the design's `ArchiveStat` cells in
  `design_handoff_stride/design_source/screens/archive.jsx` lines
  264-275 — same uppercase label, large tabular-numerics value, soft
  caption — translated to gettext + theme tokens.

  Purely presentational. The LiveView owns the stats query.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Duration
  alias KanbanWeb.TaskTokens

  @doc """
  Renders the stats strip.

  ## Attrs

    * `stats` — required map matching the `Kanban.Archives.archive_stats/1`
      return shape: `%{total, completed, cancelled, wontdo_duplicate,
      deferred, avg_cycle_minutes}`. `avg_cycle_minutes` may be `nil`.
  """
  attr :stats, :map, required: true

  def archive_stats_strip(assigns) do
    ~H"""
    <dl
      data-archive-stats-strip
      style={[
        "display: grid; grid-template-columns: repeat(5, minmax(0, 1fr));",
        "margin: 0; padding: 0;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px; overflow: hidden;"
      ]}
    >
      <.cell
        marker="total"
        label={gettext("Total archived")}
        value={Integer.to_string(@stats.total)}
        caption={gettext("across the workspace")}
        tone="var(--ink)"
        border_left={false}
      />
      <.cell
        marker="completed"
        label={gettext("Completed")}
        value={Integer.to_string(@stats.completed)}
        caption={gettext("reached Done before archive")}
        tone={TaskTokens.archive_reason_ink(:completed)}
        border_left={true}
      />
      <.cell
        marker="cancelled"
        label={gettext("Cancelled")}
        value={Integer.to_string(@stats.cancelled)}
        caption={gettext("killed in flight or before")}
        tone={TaskTokens.archive_reason_ink(:cancelled)}
        border_left={true}
      />
      <.cell
        marker="wontdo-duplicate"
        label={gettext("Won't do · duplicate")}
        value={Integer.to_string(@stats.wontdo_duplicate)}
        caption={gettext("scope / priority decisions")}
        tone="var(--ink)"
        border_left={true}
      />
      <.cell
        marker="avg-cycle"
        label={gettext("Avg cycle · completed")}
        value={Duration.format_minutes(@stats.avg_cycle_minutes)}
        caption={gettext("time spent before archive")}
        tone="var(--ink)"
        border_left={true}
      />
    </dl>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :caption, :string, required: true
  attr :tone, :string, required: true
  attr :border_left, :boolean, required: true

  defp cell(assigns) do
    ~H"""
    <div
      data-archive-stats-cell={@marker}
      style={[
        "padding: 14px 18px;",
        if(@border_left, do: "border-left: 1px solid var(--line);", else: "")
      ]}
    >
      <dt style={[
        "margin: 0;",
        "font-size: 9.5px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 4px 0 2px;",
        "font-size: 24px; font-weight: 600; letter-spacing: -0.025em;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
      <p style={[
        "margin: 0;",
        "font-size: 11.5px; color: var(--ink-3);",
        "text-wrap: pretty;"
      ]}>
        {@caption}
      </p>
    </div>
    """
  end
end
